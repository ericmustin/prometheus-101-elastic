# Chapter 03 — Scrape the trading app

**Goal:** start from the scrape config superdemo actually ships, find its three problems, and replace it with one that does not need editing when someone adds a service.

---

## What superdemo actually runs

From `superdemo/utils/prometheus-grafana/grafana.yaml`, unedited:

```yaml
scrape_configs:
  - job_name: prometheus
    honor_timestamps: true
    metrics_path: /metrics
    scheme: http
    static_configs:
    - targets:
      - router.trading-na.svc.cluster.local:9000
      - router.trading-emea.svc.cluster.local:9000
      - redis-service.infra.svc.cluster.local:9000
      labels:
        namespace: 'infra'
```

You already have a job called `prometheus`, and Prometheus rejects two jobs with the same name. Add superdemo's targets to yours as a second `static_configs` entry:

```yaml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
      - targets:
        - router.trading-na.svc.cluster.local:9000
        - router.trading-emea.svc.cluster.local:9000
        - redis-service.infra.svc.cluster.local:9000
        labels:
          namespace: 'infra'
```

Then `make apply`. Three new targets, all green. Nine lines, four minutes — a perfectly reasonable thing to have written for three services.

Now look at what it costs.

**1. The job is called `prometheus` and does not scrape Prometheus.**

```promql
up{job="prometheus"}
```

Four series: the real Prometheus, two routers, a Redis exporter. Every query from here on has to know that. Free to fix on day one, expensive on day four hundred, because by then it is in dashboards.

**2. The namespace label is a lie.**

```promql
count by (namespace) (up)
```

All three of superdemo's targets say `infra` (Prometheus's own target has no namespace at all). But two of those three are in `trading-na` and `trading-emea`. The label is applied by hand to the whole list, nothing checks it, and anything grouping by namespace silently merges two regions into one.

**This is the most important thing in the chapter.** A wrong label is worse than a missing one, because a missing one makes you go and look.

**3. It does not scale.** Add a service, nothing happens until you edit this file. Move one and it breaks. Rename a namespace and you get a green target scraping the wrong thing.

---

## Do it properly

The workload declares; the platform discovers.

### Half one: the workload declares

`superdemo/k8s/router.yaml` has no scrape annotation, and neither does the copy here — deliberately. Add it to `k8s/router.yaml`, under the pod template's `metadata:` (`spec.template.metadata`), next to its `labels:`:

```yaml
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9000"
```

```bash
./build.sh -s router
```

Two lines, and **a real PR you could open against superdemo**. The application team knows which port serves metrics; the platform team does not, and should not have to.

### Half two: the platform discovers

Take superdemo's targets back out of the `prometheus` job, leaving `localhost:9090`, and add this job below it:

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

---

## The failure you will hit first

No targets. Not red — absent.

```bash
make logs | grep -i forbidden
```

```
pods is forbidden: User "system:serviceaccount:infra:prometheus"
cannot list resource "pods" in API group "" in the namespace "trading-na"
```

A ServiceAccount is an identity. Nobody granted that identity anything.

```bash
kubectl apply -f utils/prometheus-grafana/rbac.yml
```

Targets appear within half a minute, no restart — Prometheus was already retrying. Every engineer hits this exactly once.

## The trap that costs an afternoon

`role: pod` produces one candidate per **declared container port**, so a pod declaring two gives you two targets for one workload. The obvious fix is to keep the candidate whose port matches the annotation:

```yaml
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_port,
                        __meta_kubernetes_pod_container_port_number]
        action: keep
        regex: (\d+);\1          # never matches
```

**Prometheus regexes are RE2, which has no backreferences.** `\1` is not an error — it simply never matches, so the rule keeps nothing and you get an empty Targets page from a config `promtool` calls perfect.

Rule 2 above sidesteps it: rewriting `__address__` from the annotation makes every candidate for a pod **identical**, and Prometheus deduplicates identical targets.

Carry this with you: **a relabel rule that matches zero things looks exactly like a rule that is not there.**

---

## What you get

```promql
count by (namespace, service) (up)
```

```
{}                                                   1
{namespace="infra"}                                  1
{namespace="trading-emea", service="router"}         1
{namespace="trading-na",   service="router"}         1
```

Each target labelled with the namespace it is *actually* in; the `{}` row is Prometheus scraping itself. For about five minutes `infra` reads 4 instead of 1: the hardcoded targets you removed, still showing their last scrape. And something you did not ask for:

```promql
redis_up
```

The Redis exporter. You never named it or touched `utils/redis/redis.yml`. Its annotations have been sitting in superdemo since the file was written — correct, and unused, because superdemo scrapes by hostname. Your rules read them.

**That is the payoff, and it compounds:** chapters 04 and 05 add two more workloads and neither needs a line of scrape config.

```bash
make esql Q=queries/esql/06-identity.esql
```

```
labels.cluster |  labels.env   |labels.namespace|labels.service |      labels.pod       | labels.region
---------------+---------------+----------------+---------------+-----------------------+---------------
prometheus-101 |lab            |trading-na      |router         |router-c59f76fc6-k8rqx |na
```

`cluster`/`env` from chapter 02's `external_labels`, `namespace`/`service`/`pod` from the rules you just wrote, `region` from the application. Your pod name will differ. superdemo sets no `external_labels`, so its first two are empty.

---

## Grade it

```bash
make test
```

| | |
|---|---|
| **Hardcoded targets** | fine at three, a maintenance job at thirty, silently wrong when something moves |
| **A wrong label** | worse than a missing one — nothing will tell you |
| **Annotation discovery** | a contract: the workload declares, the platform honours |
| **RBAC** | a ServiceAccount is identity; permission is separate |
| **RE2** | no backreferences; a rule matching nothing looks like no rule |
| **Target dedup** | identical label sets collapse into one target |

Next: the exporter superdemo installs and never scrapes.
