# Chapter 03 — Scrape the trading app

**Goal:** scrape the trading app by naming its targets, see why that stops scaling, then let Kubernetes tell Prometheus what to scrape and how to label it.

---

## Start by naming the targets

The quickest way to scrape something is to list it. Add a second job to `prometheus/prometheus.yml`, below `prometheus`:

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

Three new targets, all green. Now ask where each one runs:

```promql
up{job="trading-app"}
```

```
up{instance="redis-service.infra.svc.cluster.local:9000", job="trading-app"}   1
up{instance="router.trading-emea.svc.cluster.local:9000", job="trading-app"}   1
up{instance="router.trading-na.svc.cluster.local:9000", job="trading-app"}     1
```

Two labels, `job` and `instance`. The only thing telling North America from EMEA is a hostname. There is no namespace, pod or service to group by.

## Why naming targets stops working

Three targets are fine. The trouble starts as the app grows:

- **Every change is an edit to this file.** A new service is scraped only once someone adds it here, and a moved one breaks until someone notices.
- **Named targets know only what you type.** Any label you want, a namespace or a region, you add by hand and keep correct by hand. Nothing checks it.

Kubernetes already knows every pod, where it runs and what it is called. Prometheus can ask it.

---

## Let Kubernetes tell Prometheus

The workload declares how to scrape it; Prometheus discovers it.

### Half one: the workload declares

The router's pod template has no scrape annotation yet. Add one to `k8s/router.yaml`, under the pod template's `metadata:` (`spec.template.metadata`), next to its `labels:`:

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

Delete the `trading-app` job, and add this one in its place:

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

Each target labelled with the namespace it runs in; the `{}` row is Prometheus scraping itself. For a few minutes after the change the `{}` row reads 4: the named targets you deleted, still showing their last scrape. And something you did not ask for:

```promql
redis_up
```

The Redis exporter, from the `kubernetes-pods` job. Nothing in that job names it: `utils/redis/redis.yml` already carries the two annotations, so the same rules found it. For a few minutes you may also see a second row, the deleted `trading-app` job's last scrape.

**That is the payoff, and it compounds:** chapters 04 and 05 add two more workloads and neither needs a line of scrape config.

```bash
make esql Q=queries/esql/06-identity.esql
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

| | |
|---|---|
| **Named targets** | fine at three, a maintenance job at thirty |
| **Annotation discovery** | a contract: the workload declares, Prometheus discovers |
| **Relabeling** | turns discovery metadata into the labels you query by |
| **RBAC** | a ServiceAccount is identity; permission is separate |
| **RE2** | no backreferences; a rule matching nothing looks like no rule |
| **Target dedup** | identical label sets collapse into one target |

Next: cluster state, from kube-state-metrics.
