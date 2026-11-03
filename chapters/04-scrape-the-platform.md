# Chapter 04 — Scrape the platform

**Goal:** collect cluster state with kube-state-metrics, in a job of its own, and put it next to the app's metrics.

**Time:** 7 minutes

## Why it matters

The first question in most incidents is "is it the app or the platform?", and application metrics can't answer it. Exporters translate other systems into the Prometheus format, and kube-state-metrics does it for the Kubernetes API: pods, deployments, restarts. Cluster state then lands next to the app's metrics, under the same labels, so one query can compare them.

![Where you are, before chapter 04: The app is collected. Nothing describes the cluster itself. This chapter: Install kube-state-metrics and give it a job of its own.](../docs/images/topology-04-before.png)

## Steps at a glance

1. Start the chapter: `make chapter 4`
2. Install kube-state-metrics: `make ksm`
3. Add a `kube-state-metrics` job to `prometheus/prometheus.yml`
4. Apply it: `make apply`
5. See it: running pods and deployment health, in Kibana
6. Grade it: `make test`

## Step 1 · Start the chapter

```bash
make chapter 4
```

## Step 2 · Install kube-state-metrics

```bash
make ksm
```

This runs `utils/ksm/ksm.sh`, the same Helm install superdemo uses. It puts kube-state-metrics in `kube-system`.

## Step 3 · Add its job

kube-state-metrics needs a job of its own, because its Helm chart annotates its **Service**, not its pod, and chapter 03's job discovers pods by their annotations. In `prometheus/prometheus.yml`, add this job below `kubernetes-pods`:

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

The first rule finds the pod by its label. The second keeps the port named `http` (8080), which serves the cluster state. The port named `metrics` (8081) serves kube-state-metrics' own process telemetry.

<details>
<summary>Note · See why chapter 03's job doesn't find it</summary>

```bash
kubectl -n kube-system get pod -l app.kubernetes.io/name=kube-state-metrics \
  -o jsonpath='{.items[0].metadata.annotations}'      # empty

kubectl -n kube-system get svc kube-state-metrics -o jsonpath='{.metadata.annotations}'
```

```json
{"meta.helm.sh/release-name":"kube-state-metrics","meta.helm.sh/release-namespace":"default","prometheus.io/scrape":"true"}
```

The annotation is on the Service. That isn't a bug, just a different convention, and both are common. Annotation discovery is a good default, not a complete answer: some things have to be named.

</details>

<details>
<summary>Note · Why this job sets no <code>pod</code> or <code>node</code> label</summary>

kube-state-metrics' series already carry `pod` and `node`: the pod and node each series describes. A target label with the same name would win and rename the real one to `exported_pod`, and every per-pod query would group by kube-state-metrics' own pod instead.

</details>

## Step 4 · Apply it

```bash
make apply
```

You should see a `kube-state-metrics` job on the Targets page with one target, **UP**.

## Step 5 · Ask the cluster a question

Running pods per namespace:

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  sum by (namespace) (kube_pod_status_phase{phase="Running"})
```

Deployments at their replica count:

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  sum by (namespace, deployment) (kube_deployment_status_replicas_available)
  / sum by (namespace, deployment) (kube_deployment_status_replicas)
```

You should see a row per namespace, then a row per deployment at `1`, which means fully rolled out. Anything lower is worth an alert. Both sides of the ratio are summed by the labels they match on: Kibana requires that when you divide two different metrics. None of this is something the trading app could tell you about itself.

<details>
<summary>Note · Anything restarting?</summary>

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  sum by (namespace, pod) (rate(kube_pod_container_status_restarts_total[15m])) > 0
```

The `> 0` keeps only the rows worth looking at, which is how alert expressions are written. No results is the good answer: nothing has restarted in fifteen minutes.

</details>

<details>
<summary>Note · How many series it adds</summary>

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  scrape_samples_scraped{job="kube-state-metrics"}
```

This is about 1,250 on this lab's thirteen pods, and about 80 more for each pod you add. The count follows the cluster, not your application, so it grows when capacity is added. `scrape_samples_scraped` sizes any exporter with no extra setup. To see which families the series come from, ask Prometheus itself, because Kibana's PromQL doesn't match metric-name patterns:

```promql
topk(8, count by (__name__) (last_over_time({__name__=~"kube_.*"}[1m])))
```

Chapter 06 trims it.

</details>

<details>
<summary>Note · App and cluster, side by side</summary>

```bash
make esql Q=queries/esql/04-cluster-state.esql
```

This gives running pods per namespace, five minutes at a time, from the same data stream as the trading app and under the same `labels.namespace`. Put it on a dashboard next to chapter 03's requests per region, and "did throughput drop because pods went away?" has an answer.

</details>

## Step 6 · Grade it

```bash
make test
```

You should see every check pass: kube-state-metrics installed and scraped by its own job, and running pods per namespace answering in Kibana.

## The whole change

In `prometheus/prometheus.yml`, below the `kubernetes-pods` job:

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

The commands, in order:

```bash
make chapter 4
make ksm
make apply
make test
```

## Say it

"Exporters bring the rest of your estate into the same format: Kubernetes, databases, queues. In Elastic, cluster state sits next to the app's metrics under the same labels, so 'is it the app or the platform?' is one query."

![What you collect after chapter 04: Cluster state, from kube-state-metrics, next to the app's metrics. Now you can answer: Is anything restarting? Are deployments at their replica count?](../docs/images/topology-04-after.png)

<details>
<summary>Note · In the field</summary>

- **Ask:** "Which exporters do you run beyond node and kube-state-metrics?" and "When an incident starts, where do people look first?"
- **If they say** "We get Kubernetes metrics from our cloud provider": that covers the platform. kube-state-metrics adds the workload view (replicas, restarts, phases), labelled the same way as their apps, and it moves with them across clouds.
- **Good practice:** give an exporter with a different shape its own job, and know its series count before you size Prometheus or plan storage. kube-state-metrics reports state; CPU and memory usage come from the kubelet's cAdvisor endpoint or a node exporter.
- **In superdemo:** `utils/ksm/ksm.sh` installs kube-state-metrics, the same script you ran.

</details>

Next: the collector.
