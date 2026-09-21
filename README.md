# otel-pipeline-lab

A Kubernetes log pipeline reconciled by Argo CD: OpenTelemetry collectors on both
sides of a Kafka buffer, VictoriaLogs as the backend. Two commands are typed on a
bare machine, everything after them comes from this repository.

```
  in-cluster workloads                                    (M1)
          |  stdout
          v
  agent  (daemonset: filelog, kubeletstats, k8sattributes) (M1)
          |  OTLP/gRPC
          v
  gateway (deployment: otlp in, kafka out)                 (M2)
          |
          v
  Kafka   topic otel-logs, 3 partitions, RF 3, min.insync 2
          Strimzi 1.2.0, three KRaft nodes (controller + broker)
          |
          v
  consumer (deployment: kafka in, otlp_http out)
          |
          v
  VictoriaLogs
```

Argo CD is the only way in. One `Application` is applied by hand
(`gitops/bootstrap/root.yaml`); it reconciles the ones under `gitops/apps/`, which
reconcile everything else.

## Why Kafka is in the chain

VictoriaLogs ingests OTLP directly, so the pipeline runs without a broker. Kafka is
here for two operations that require one:

1. **Buffering across a backend outage.** VictoriaLogs scaled to zero, logs still
   written, then scaled back up without touching the consumer. Measured: 500 injected,
   500 returned by LogsQL, consumer lag back to 0.
2. **Consumer lag as an alerting signal.** The lag covers the whole chain: it rises
   when the consumer, the backend or the network between them fails, which makes it
   one alert with a runbook entry that spans several components.

The traffic in this lab is a few hundred logs per run, well below what a three-node
Kafka cluster is for. The size is here to make the replication behaviour observable,
and the cost of that choice is three extra pods.

## Kafka node layout

The three KRaft nodes carry both roles, `controller` and `broker`, in a single
`KafkaNodePool`. Strimzi documents combined nodes as a development and testing
configuration and expects production clusters to separate the two roles.

They stay combined here because the behaviour under test is replication: an in-sync
replica set that shrinks when a broker dies and rebuilds when it comes back.
Separating the roles costs six pods for the same observation.

## The two consumer settings

Both live in `gitops/manifests/otel/consumer.yaml`, and the pipeline needs both.

- `message_marking: {after: true, on_error: false}`. By default the Kafka receiver
  commits the offset before the pipeline has succeeded. During a backend outage the
  data is then lost while the consumer lag stays at zero.
- `error_backoff: {enabled: true, ...}`. With `message_marking` alone, the receiver
  pauses the partition on the first error and resumes only after a rebalance: the data
  is kept, and the pipeline stays stuck until someone restarts the consumer. The
  backoff turns the pause into a retry.

No encoding is set anywhere. The Kafka exporter and the Kafka receiver both default to
`otlp_proto`, which carries the OTLP structure and the Kubernetes resource attributes
through the broker. Setting `raw` on the exporter, or `json` on the receiver, flattens
them without an error.

## Versions

| Component | Version |
|---|---|
| Kubernetes (k3s, via k3d) | v1.37.0+k3s1 |
| Argo CD | v3.5.3 |
| Strimzi operator | 1.2.0 |
| Apache Kafka | 4.3.1 |
| OpenTelemetry Collector Contrib | 0.161.0 |
| VictoriaLogs (chart `victoria-logs-single` 0.13.9) | v1.52.0 |

Strimzi 1.2.0 serves `kafka.strimzi.io/v1` only. Examples written for `v1beta2` fail
with `no matches for kind "Kafka" ... ensure CRDs are installed first`, which reports
a missing CRD for what is a version mismatch.

## Run it

Argo CD cannot install itself, so two commands are typed on a bare machine. Everything
after them is reconciled from this repository.

```sh
make cluster     # k3d from k3d/otel-lab.yaml: pinned k3s image, fixed API port
make argocd      # Argo CD v3.5.3, server-side apply
make bootstrap   # apply the root Application; Argo CD does the rest
make smoke       # inject N logs at the OTLP endpoint, count them in VictoriaLogs
make reset       # clean slate, CRDs included
```

Both hand-typed targets are idempotent: a second `make argocd` prints
`namespace/argocd unchanged` and exits 0. The k3s image and the API port are pinned in
`k3d/otel-lab.yaml`, so a clone gets the cluster these measurements were taken on.

`make smoke` fails when the chain is broken. With the Argo CD application controller
stopped so that nothing heals the damage, scaling the consumer to zero gives
`injected=100 found=0` and a non-zero exit.

`make dev` serves a mirror of this repository to the cluster over a git daemon bound
to the cluster bridge, for changes that have not been pushed yet.

## Milestones

| | | |
|---|---|---|
| M0 | Cluster config and bootstrap targets in git | done |
| M1 | Collector agent and gateway, `make smoke` | in progress |
| M2 | Kafka buffer, consumer, VictoriaLogs | done |
| M3 | kube-prometheus-stack, two alerts | |
| M4 | `mep/` and `runbook/`, fluentd to otel migration on a non-cluster host | |
| M5 | Scheduled jobs | |
