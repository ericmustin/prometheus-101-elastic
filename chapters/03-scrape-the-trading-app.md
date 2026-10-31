# Chapter 03 — Scrape the trading app

**Goal:** scrape the trading app by naming its targets, see why that stops scaling, then let Kubernetes tell Prometheus what to scrape and how to label it.

## Why it matters

- **The problem:** a metric is only as useful as its labels. "Requests per second" helps nobody; "requests per second in EMEA, for the router" does. And in Kubernetes things move, so a list of addresses goes stale the day someone adds a service.
- **What Prometheus does:** Kubernetes discovery finds every pod that asks to be scraped, and relabeling turns what Kubernetes knows (namespace, pod, service, node) into labels you query by.
- **Why it's worth it:** new services are covered without a ticket, and every team's metrics carry the same dimensions, so one dashboard or alert works for every region. That consistency is what makes an estate's metrics queryable as a whole, in Prometheus and in Elastic.

---

## Where you are

Prometheus scrapes itself and sends its own metrics to Elastic. The trading app's routers and the Redis exporter serve metrics that nothing collects yet. This chapter collects them, first by naming them, then by letting Kubernetes tell Prometheus where they are.

![Where you are, before chapter 03: The routers and Redis serve metrics. Nothing collects them yet. This chapter: Scrape the routers and Redis, then let Kubernetes tell Prometheus where they are.](../docs/images/topology-03-before.png)

```bash
make goals
```

Chapters 01 and 02 pass. Chapter 03's are to do: no router is discovered yet, and nothing carries Kubernetes labels.

---

## Start by naming the targets

The quickest way to scrape something is to list it.

**▶ Your turn:** add a second job to `prometheus/prometheus.yml`, below `prometheus`:

```yaml
  - job_name: trading-app
    static_configs:
      - targets:
        - router.trading-na.svc.cluster.local:9000
        - router.trading-emea.svc.cluster.local:9000
        - redis-service.infra.svc.cluster.local:9000
```

The two routers and the Redis exporter, by their Service hostnames. It is the same list superdemo's own Prometheus scrapes.

```bash
make apply
```

Three new targets, all green on the Targets page. Now ask Elastic where each one runs:

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  up{job="trading-app"}
```

The `_timeseries` column lists each series' labels: `job` and `instance`, plus the `cluster` and `env` that `external_labels` stamped on the way out. The only thing telling North America from EMEA is a hostname. There is no namespace, pod or service to group by.

## Why naming targets stops working

Three targets are fine. The trouble starts as the app grows:

- **Every change is an edit to this file.** A new service is scraped only once someone adds it here, and a moved one breaks until someone notices.
- **Named targets know only what you type.** Any label you want, a namespace or a region, you add by hand and keep correct by hand. Nothing checks it.

Kubernetes already knows every pod, where it runs and what it is called. Prometheus can ask it.

---

## Let Kubernetes tell Prometheus

The workload declares how to scrape it; Prometheus discovers it.

### Half one: the workload declares

**▶ Your turn:** the router's pod template has no scrape annotation yet. Add one to `k8s/router.yaml`, under the pod template's `metadata:` (`spec.template.metadata`), next to its `labels:`:

```yaml
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9000"
```

```bash
./build.sh -s router
```

Two lines, owned by the right team: the application team knows which port serves metrics, and whoever runs Prometheus does not have to.

### Half two: Prometheus discovers

**▶ Your turn:** delete the `trading-app` job, and add this one in its place:

```yaml
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: ["trading-na", "trading-emea", "infra"]

    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_service]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node
```

```bash
make apply
```

### What the rules do

Discovery turns every pod in those namespaces into a candidate target, carrying `__meta_kubernetes_*` labels: its namespace, name and node, its labels and its annotations. Annotation names are made safe for Prometheus on the way, so `prometheus.io/scrape` arrives as `__meta_kubernetes_pod_annotation_prometheus_io_scrape`. Relabeling then runs top to bottom:

| Rule | What it does |
|---|---|
| `keep` on the scrape annotation | drops every pod that has not opted in |
| rewrite `__address__` | scrapes the port the annotation names |
| `__metrics_path__` | honours a custom path if a pod sets one; `/metrics` otherwise |
| the last four | copy discovery metadata into labels you can query: `namespace`, `pod`, `service`, `node` |

Anything still starting with `__` is dropped once relabeling finishes. That is why the pod's other labels, `pod_template_hash` among them, never reach your series: you choose what becomes a label.

---

## Discovery needs permission

No targets. Not red: absent. Discovery asks the Kubernetes API for pods, and Prometheus logs why it can't:

```bash
make logs | grep -i forbidden
```

```
pods is forbidden: User "system:serviceaccount:infra:prometheus"
cannot list resource "pods" in API group "" in the namespace "trading-na"
```

Prometheus runs as a ServiceAccount, and nothing has granted that account permission to list pods yet. The workshop's RBAC file grants it read access to pods, services, endpoints and nodes.

**▶ Your turn:**

```bash
kubectl apply -f utils/prometheus-grafana/rbac.yml
```

Targets appear within half a minute, no restart: Prometheus was already retrying. This is a common first error with Kubernetes discovery, and in a customer cluster the fix is the same ClusterRole and binding, or the one their Helm chart creates.

## No backreferences

`role: pod` produces one candidate per **declared container port**, so a pod declaring two gives you two targets for one workload. The obvious fix is to keep the candidate whose port matches the annotation:

```yaml
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port,
                        __meta_kubernetes_pod_container_port_number]
        action: keep
        regex: (\d+);\1          # rejected
```

**Prometheus regexes are RE2, which has no backreferences.** `make apply` stops at `promtool`, and nothing reaches the cluster:

```
error parsing regexp: invalid escape sequence: `\1`
```

Rule 2 above sidesteps it: rewriting `__address__` from the annotation makes every candidate for a pod **identical**, and Prometheus deduplicates identical targets. When a relabel rule seems to need a backreference, look for a rewrite that makes the values equal instead.

---

## What you get

Back in Kibana:

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  count by (namespace, service) (up)
```

```
count by (namespace, service) (up) | namespace    | service
1.0                                | trading-emea | router
1.0                                | trading-na   | router
1.0                                | infra        | null
1.0                                | null         | null
```

Each target labelled with the namespace it runs in. `infra` with no service is Redis, whose pod has no `service` label; the row with neither is Prometheus scraping itself. For about five minutes after the change that row reads 4: the named targets you deleted, still showing their last scrape, because a series stays visible until its last sample leaves the lookback window.

*Why this shape:* `count by` the labels you care about is the inventory pattern: how many of each thing, grouped the way the business asks.

And something you did not ask for:

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  redis_up
```

The Redis exporter, from the `kubernetes-pods` job. Nothing in that job names it: `utils/redis/redis.yml` already carries the two annotations, so the same rules found it. **This is what discovery buys you:** chapter 05's collector is found the same way, with no new scrape config. Chapter 04 shows the exception.

---

## Labels pay off: the golden signals

Labels are why you can now ask the questions every service dashboard asks. They are known as **RED**: **R**ate, **E**rrors, **D**uration.

**Rate**, requests per second per region:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  sum by (region) (rate(http_requests_total[5m]))
```

*Why this shape:* `http_requests_total` only ever goes up, so its raw value means nothing. `rate()` turns it into a per-second figure and copes with restarts, which reset the counter to zero. `sum by (region)` adds up every pod behind a region and keeps the one label the question is about.

**Errors**, the same rate split by status code:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  sum by (region, status) (rate(http_requests_total[5m]))
```

Every line here is `200`. An error ratio divides the `5xx` rate by the total, the number most availability targets are written against. Here it returns no result rather than 0, because no `5xx` series exists yet: absent, not zero, which chapter 05 comes back to.

**Duration**, the 95th percentile per region:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  histogram_quantile(0.95, sum by (le, region) (rate(http_request_duration_seconds_bucket[5m])))
```

*Why this shape:* a histogram counts requests into buckets (`le` is "less than or equal to"), so buckets from every pod can be added up before the percentile is taken. An average hides the slow requests users actually feel; the 95th percentile shows them.

The same three queries run unchanged in Prometheus and in Grafana. Here they also run over as much history as your data stream keeps.

And in ES|QL, where you can look at the documents themselves:

```bash
make esql Q=queries/esql/03-identity.esql
```

```
labels.cluster |  labels.env   |labels.namespace|labels.service |      labels.pod       | labels.region
---------------+---------------+----------------+---------------+-----------------------+---------------
prometheus-101 |lab            |trading-na      |router         |router-c59f76fc6-k8rqx |na
```

`cluster`/`env` from chapter 02's `external_labels`, `namespace`/`service`/`pod` from the rules you just wrote, `region` from the application. Your pod name will differ.

---

## Grade it

```bash
make test
```

Chapter 03's checks: one healthy router per region, found by discovery and labelled with its own namespace; Redis found by the same rules; the `trading-app` job gone, so nothing is scraped twice; Prometheus allowed to list pods; only the labels you chose, so no `pod_template_hash`; the Kubernetes labels arriving in Elastic; and requests per region answering in Kibana.

## What you collect now

![What you collect after chapter 03: Both routers and Redis, found by discovery and labelled by namespace and service. Now you can answer: Requests and trades, by region, namespace and service.](../docs/images/topology-03-after.png)

## In the field

- **Say it:** "Your workloads declare how to be scraped, and Prometheus finds them. Every metric arrives labelled with where it came from, so the same dashboard works for every region and every new service."
- **Ask:** "How does a new service get monitored today: a ticket, a config change, or automatically?" and "Do your teams use the same labels for the same things?"
- **If they say** "We use the Prometheus Operator": good, its ServiceMonitor and PodMonitor resources do the job these annotations do here. Everything after discovery, the labels, remote write and PromQL, works the same.
- **Good practice:** labels become dimensions in Elastic (`labels.namespace`, `labels.service`), so choose them on purpose: enough to group and filter by, without per-request values that multiply series.
- **In superdemo:** its Prometheus names its three targets, the way this chapter starts. Discovery is how that setup grows: annotate a workload, and the same rules find it.

**Explain it back:** a customer's engineer asks why every panel on their dashboard wraps a counter in `rate()`, and why latency is a percentile rather than an average. Answer in two sentences.

## What you now know

![Chapter 03 on one page: targets named by hand carry only job and instance. With discovery, pods declare scrape annotations and the kubernetes-pods job finds both routers and Redis, labelled by namespace, pod, service and node. Watch for RBAC and for RE2's missing backreferences. The workload declares, Prometheus discovers.](../docs/images/03-discover-the-app.png)

| | |
|---|---|
| **Named targets** | fine at three, a maintenance job at thirty |
| **Annotation discovery** | a contract: the workload declares, Prometheus discovers |
| **Relabeling** | turns discovery metadata into the labels you query by |
| **RBAC** | a ServiceAccount is identity; permission is separate |
| **RE2** | no backreferences: `promtool` rejects `\1`; rewrite `__address__` instead |
| **RED** | rate, errors, duration: `rate()`, `sum by`, `histogram_quantile` |

Next: cluster state, from kube-state-metrics.
