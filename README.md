# otel-pipeline-lab

A log pipeline for Kubernetes, reconciled entirely by Argo CD, built to be operated
rather than demoed: every design choice below is one someone can be questioned about.

```
  in-cluster workloads                                    (M1)
          |  stdout
          v
  agent  (daemonset: filelog, kubeletstats, k8sattributes) (M1)
          |  OTLP/gRPC
          v
  gateway (deployment: otlp in, kafka out)                 <-- M2
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

## Why Kafka is here

Functionally it is not needed. VictoriaLogs ingests OTLP directly, and the pipeline
works without a broker. Kafka is in the chain for two operational gestures that
cannot be shown without it:

1. **A buffer that survives a backend outage.** Scale VictoriaLogs to zero, keep
   writing logs, bring it back without touching the consumer: nothing is lost and the
   lag drains on its own. Measured: 500 injected, 500 returned by LogsQL, lag back to 0.
2. **Consumer lag as an alerting signal**, which is the one runbook entry that tells a
   story across several components instead of a single failing pod.

The volume of this lab does not justify a three-node Kafka cluster and nothing here
pretends otherwise. Presented as a technical necessity it would not survive the first
"what throughput?"; presented as a deliberate choice, it shows what the cost is.

## Why three combined nodes

The three KRaft nodes carry both roles, `controller` and `broker`, in a single
`KafkaNodePool`. The Strimzi documentation reserves combined nodes for development and
testing and expects a production cluster to separate controllers from brokers.

This lab keeps them combined on purpose: separating them costs six pods instead of
three for exactly the same demonstration — an in-sync replica set that shrinks when a
broker dies, and rebuilds when it comes back. The behaviour under test is replication,
and replication does not change with the split. Same reasoning as Kafka itself: a
choice that is stated, not a constraint that is invented.

## The two settings that make the buffer real

Neither is a default, and only one of them is not enough.
Both live in `gitops/manifests/otel/consumer.yaml`.

- `message_marking: {after: true, on_error: false}` — by default the Kafka receiver
  commits the offset *before* the pipeline has succeeded. A backend outage then loses
  the data while the consumer lag stays at zero: the failure looks like health.
- `error_backoff: {enabled: true, ...}` — with `message_marking` alone the receiver
  pauses the partition on the first error and never resumes without a rebalance, so
  the data is kept but the pipeline stays stuck until someone restarts the consumer.
  The backoff turns the pause into a retry, and the recovery becomes automatic.

No encoding is configured anywhere. The Kafka exporter and the Kafka receiver both
default to `otlp_proto`, which carries the OTLP structure and the Kubernetes resource
attributes through the broker untouched. Setting `raw` on the exporter, or `json` on
the receiver, silently flattens them.

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
with `no matches for kind "Kafka" ... ensure CRDs are installed first`, which blames a
missing CRD for what is a version mismatch.

## Run it

```sh
make bootstrap   # apply the root Application; Argo CD does the rest
make smoke       # inject N logs at the OTLP endpoint, count them in VictoriaLogs
make reset       # clean slate, CRDs included
```

`make dev` replaces `make bootstrap` while the repository has not been pushed: it
serves a local mirror to the cluster over a git daemon bound to the cluster bridge.

`make smoke` is only useful if it can fail, so it was made to. With the Argo CD
application controller stopped, so that nothing heals the damage, scaling the consumer
to zero gives `injected=100 found=0` and a non-zero exit.

## Milestones

| | | |
|---|---|---|
| M1 | Collector agent and gateway, `make smoke` | in progress |
| M2 | Kafka buffer, consumer, VictoriaLogs | this commit |
| M3 | kube-prometheus-stack, two alerts | |
| M4 | `mep/` and `runbook/`, fluentd to otel migration on a non-cluster host | |
| M5 | Scheduled jobs | |
