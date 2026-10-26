# Chapter 04 — Scrape the platform

**Goal:** collect cluster state with kube-state-metrics, and see why it needs a job of its own.

---

## Where you are

Prometheus discovers the routers and Redis, and their metrics reach Elastic with Kubernetes labels. Nothing yet describes the cluster itself: which pods are running, whether deployments have their replicas, whether anything is restarting. This chapter installs kube-state-metrics and gives it a job.

Grade it before you start:

```bash
make test
```

Chapters 01 to 03 pass. Chapter 04's first check fails, because kube-state-metrics isn't installed yet.

---

## The idea

So far you have collected application metrics, which answer "is the service healthy". They do not answer "is the *cluster* healthy" — is anything crash-looping, are deployments at their replica count, is a pod stuck Pending.

That layer is what **exporters** are for: a process translating something into the Prometheus exposition format. There are hundreds, and you already met one without noticing — the `redis_exporter` sidecar that appeared for free in chapter 03.

For cluster state the standard is **kube-state-metrics**, one Helm install:

```bash
make ksm
```

That runs `utils/ksm/ksm.sh`, the same script superdemo uses. Now check the Targets page.

**Nothing.** For the first time in three chapters, a new workload did *not* appear.

---

## Why discovery didn't find it

```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=kube-state-metrics \
  -o jsonpath='{.items[0].metadata.annotations}'      # empty

kubectl -n kube-system get svc kube-state-metrics -o jsonpath='{.metadata.annotations}'
```

```json
{"meta.helm.sh/release-name":"kube-state-metrics","meta.helm.sh/release-namespace":"default","prometheus.io/scrape":"true"}
```

The chart annotates the **Service**, not the **pod**, and your discovery uses `role: pod`. Not a bug — a different convention, and both are common. It is why annotation discovery is a good default rather than a complete answer: **some things have to be named.**

---

## Give it a job

```yaml
  - job_name: kube-state-metrics
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: ["kube-system"]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        action: keep
        regex: kube-state-metrics

      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: http
```

```bash
make apply
```

That second `keep` is load-bearing. kube-state-metrics declares two ports:

```
http    8080    the cluster state you want
metrics 8081    kube-state-metrics' own process telemetry
```

The port named `metrics` is **not** the metrics you want. Without the rule you scrape both, and the second target is kube-state-metrics' own process telemetry, not cluster state.

And unlike chapter 03's job, this one sets no `pod` or `node` label. kube-state-metrics' series already carry those: the pod and node each series describes. A target label of the same name would win and rename the real one to `exported_pod`, and every per-pod query would group by kube-state-metrics' own pod instead.

---

## Ask the cluster a question

```promql
sum by (namespace) (kube_pod_status_phase{phase="Running"})

kube_deployment_status_replicas_available / kube_deployment_status_replicas

sum by (namespace, pod) (rate(kube_pod_container_status_restarts_total[15m])) > 0
```

Below 1 on the second means not fully rolled out — most of a useful cluster alert in one expression. The third is anything crash-looping in the last fifteen minutes. None of this is something the trading app could tell you about itself.

---

## How many series it adds

```promql
count(last_over_time({__name__=~"kube_.*"}[1m]))
```

**About 1,250 series** on the thirteen pods you have now. Measured while building this course: **1,239** on thirteen pods, **1,316** once chapter 05's collector makes it fourteen — one more pod, about 80 more series.

```promql
topk(8, count by (__name__) (last_over_time({__name__=~"kube_.*"}[1m])))
```

`kube_pod_status_qos_class`, `kube_pod_status_scheduled` — one series per pod per possible value, whether or not anything queries them.

**Worth knowing when you size things:** this count follows the *cluster*, not your application, so it grows when capacity is added. Chapter 06 looks at the options for managing it.

> `last_over_time` matters here. A bare `count()` returns the last sample of every series inside the five-minute staleness window, so straight after a change it reports the old number and looks like nothing happened.

---

## In Elastic

```bash
make esql Q=queries/esql/04-cluster-state.esql
```

Running pods per namespace, five minutes at a time, from the same data stream as the trading app and under the same `labels.namespace` its series have carried since chapter 03. Cluster state next to trading throughput, so you can see whether they move together. Seeing them side by side is one of the main reasons to centralise.

---

## Grade it

```bash
make test
```

Chapter 04's checks: kube-state-metrics is installed; its pod carries no scrape annotation, which is why it needs naming; the job has a healthy target; pod phase and deployment replicas are collected; it can count running pods; and cluster state reached Elastic alongside the application's metrics.

## In the field

- **In superdemo:** `utils/ksm/ksm.sh` installs kube-state-metrics, the same script you ran.
- **What customers ask:** "Can we see cluster health next to the app?" Yes: cluster state lands in the same data stream as the app, under the same `labels.namespace`, so one query can compare them. kube-state-metrics reports state (phases, replicas, restarts); CPU and memory usage come from the kubelet's cAdvisor endpoint or a node exporter.
- **Good practice:** give an exporter with a different shape its own job, and know its series count before you size Prometheus or plan storage.

## What you now know

| | |
|---|---|
| **Exporters** | translate anything into the Prometheus format |
| **kube-state-metrics** | cluster state, from one Helm install |
| **Service vs pod annotations** | both conventions are common, so some things need naming |
| **Two ports** | the one called `metrics` is often not the metrics you want |
| **Cluster cardinality** | follows the cluster, not the app |

Next: the collector.
