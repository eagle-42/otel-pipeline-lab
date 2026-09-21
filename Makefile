# otel-pipeline-lab
# M2: the Kafka buffer and the log backend, reconciled by Argo CD.

CLUSTER     ?= otel-lab
REPO_URL    ?= https://github.com/eagle-42/otel-pipeline-lab.git
MIRROR_DIR  ?= /tmp/otel-lab-mirror
MIRROR_URL  ?= git://host.k3d.internal/otel-pipeline-lab
DAEMON_PID  ?= /tmp/otel-lab-git-daemon.pid
ARGOCD_VER  ?= v3.5.3
TELEMETRYGEN ?= ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.161.0
LOGS        ?= 500

SHELL := /bin/bash
.ONESHELL:
.PHONY: cluster argocd dev bootstrap smoke reset

## The cluster itself. First of the two commands typed on a bare machine.
cluster:
	k3d cluster create --config k3d/otel-lab.yaml

## Argo CD cannot be reconciled by Argo CD. Second and last command typed by hand.
argocd:
	set -euo pipefail
	# install.yaml carries no Namespace object, and a plain `create` fails the second time.
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd --server-side --force-conflicts \
	  -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VER)/manifests/install.yaml
	# Without this, `bootstrap` right after would apply against an API that is not serving yet.
	kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

## Serve this repository to the cluster and point Argo CD at it.
## Only needed while the repository has not been pushed yet; after that, `bootstrap`.
dev:
	set -euo pipefail
	rm -rf $(MIRROR_DIR) && mkdir -p $(MIRROR_DIR)
	git clone -q . $(MIRROR_DIR)/otel-pipeline-lab
	grep -rl -- '$(REPO_URL)' $(MIRROR_DIR)/otel-pipeline-lab/gitops \
	  | xargs sed -i 's|$(REPO_URL)|$(MIRROR_URL)|g'
	git -C $(MIRROR_DIR)/otel-pipeline-lab commit -aqm 'local mirror'
	# By pid file, not by pattern: the recipe's own command line contains the
	# daemon's arguments, so a `pkill -f` on them kills this shell.
	[ -f $(DAEMON_PID) ] && kill "$$(cat $(DAEMON_PID))" 2>/dev/null || true
	# Listening on the cluster bridge only: reachable from the pods, from nowhere else.
	git daemon --listen=$$(docker network inspect k3d-$(CLUSTER) \
	  --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}') \
	  --port=9418 --base-path=$(MIRROR_DIR) --export-all \
	  --pid-file=$(DAEMON_PID) --detach
	kubectl apply -f $(MIRROR_DIR)/otel-pipeline-lab/gitops/bootstrap/root.yaml

## The one object applied by hand once the repository is public.
bootstrap:
	kubectl apply -f gitops/bootstrap/root.yaml

## A log written at the OTLP endpoint must come out of VictoriaLogs. Nothing else proves the chain.
smoke:
	set -euo pipefail
	stamp=smoke-$$(date +%s)
	kubectl -n otel delete job telemetrygen --ignore-not-found >/dev/null
	# --rate 0 or telemetrygen emits one log per second and looks like a stuck pipeline.
	kubectl -n otel create job telemetrygen --image=$(TELEMETRYGEN) -- \
	  /telemetrygen logs --otlp-endpoint gateway.otel.svc:4317 --otlp-insecure \
	  --logs $(LOGS) --rate 0 --body "$$stamp"
	kubectl -n otel wait --for=condition=complete job/telemetrygen --timeout=180s
	kubectl -n logs port-forward svc/vlogs-victoria-logs-single-server 9428:9428 >/dev/null 2>&1 &
	pf=$$!; trap "kill $$pf" EXIT; sleep 2
	for i in $$(seq 1 30); do
	  found=$$(curl -s --data-urlencode "query=$$stamp" http://127.0.0.1:9428/select/logsql/query | grep -c . || true)
	  [[ "$$found" == "$(LOGS)" ]] && break
	  sleep 2
	done
	echo "injected=$(LOGS) found=$$found"
	[[ "$$found" == "$(LOGS)" ]]

## Clean slate, CRDs included: syncing on top of existing CRDs does not test the CRD-then-CR order.
reset:
	set -euo pipefail
	kubectl -n argocd delete application --all --ignore-not-found
	# The topic operator dies with its namespace and nothing is left to remove the
	# finalizer it set on the KafkaTopic: the namespace hangs in Terminating forever.
	kubectl -n kafka get kafkatopics,kafkas,kafkanodepools -o name 2>/dev/null \
	  | xargs -r -I{} kubectl -n kafka patch {} --type merge -p '{"metadata":{"finalizers":[]}}'
	kubectl delete ns kafka otel logs --ignore-not-found
	kubectl delete crd -l app=strimzi --ignore-not-found
	kubectl get crd | grep -c strimzi || echo "0 strimzi CRD left"
