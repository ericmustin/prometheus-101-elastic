# From this workshop to superdemo

Read this when you move on to superdemo. The course uses superdemo's names, ports, namespaces and file layout on purpose, so most of what you find there will already look familiar. This page shows where each piece you built lives.

![Where each chapter lives in superdemo: your first scrape job and remote write live in the prometheus.yml inside utils/prometheus-grafana/grafana.yaml; pod discovery annotations on the router in k8s/router.yaml and Redis in utils/redis/redis.yml; kube-state-metrics from utils/ksm/ksm.sh; the EDOT collectors in agents/apm/; filters under any scrape job or its remote_write; and the same two Grafana datasources and saved search.](images/00-maps-to-superdemo.png)

---

## The five files

superdemo's Prometheus surface is five files, and you have worked with the equivalent of all of them.

| You built | superdemo | |
|---|---|---|
| `src/router/` | `superdemo/src/router/` | byte-identical, vendored unmodified |
| `utils/redis/redis.yml` | `superdemo/utils/redis/redis.yml` | byte-identical |
| `utils/ksm/ksm.sh` | `superdemo/utils/ksm/ksm.sh` | byte-identical |
| `prometheus/prometheus.yml` | inside `utils/prometheus-grafana/grafana.yaml` | the same kind of config, grown chapter by chapter |
| `utils/prometheus-grafana/grafana.yaml` | same path | same two datasources, rendered rather than hardcoded |

---

## Where each chapter's piece lives

| Chapter | You added | In superdemo |
|---|---|---|
| 01 | a scrape job | the `prometheus.yml` inside `utils/prometheus-grafana/grafana.yaml` |
| 02 | remote write and `external_labels` | the same file, with the same remote write URL and data stream |
| 03 | pod discovery and scrape annotations | the router in `k8s/router.yaml`, Redis in `utils/redis/redis.yml` |
| 04 | a kube-state-metrics job | `utils/ksm/ksm.sh` installs it |
| 05 | a collector's own metrics | the EDOT collectors in `agents/apm/` |
| 06 | filtering at the scrape and at remote write | any scrape job, and the `remote_write` block |
| 07 | Elastic as a Grafana datasource | the same two datasources, and the saved search in `assets/objects/metrics_esql.ndjson` |

superdemo's Prometheus names its three targets directly, the way chapter 03 starts. Discovery, relabeling and filtering are what you add as an environment grows.

---

## Things that are the same on purpose

So that nothing surprises you when you open the real thing:

| | |
|---|---|
| Namespaces | `trading-na`, `trading-emea`, `infra` |
| Ports | 9000 trading-na, 9001 trading-emea, 9012 Grafana — from `utils/traefik/values.yaml` |
| Naming | Deployment == Service == container == `src/` directory |
| ConfigMap | `prom-config` |
| Secret | `elastic-secret-otel` |
| Deploy idiom | getopts `build.sh`, `envsubst` templates per region, `retry_command_lin` |
| Flag letters | `-h` kibana, `-i` apikey, `-j` es, `-k` ingest, `-c` course, `-r` region, `-s` service |
| Remote write URL | `$ES/_prometheus/api/v1/write` — the zero-segment form |
| Data stream | `metrics-generic.prometheus-default` |
| Grafana datasources | two, both `type: prometheus` |

The remote write URL is worth dwelling on. superdemo uses the form with **no routing segments**, which lands everything in `metrics-generic.prometheus-default`. That is why superdemo's own saved search reads from exactly that name, and why the course writes there too — import `assets/objects/metrics_esql.ndjson` from superdemo unmodified and it works against your data.

It is also the thing to change first when a second cluster writes into the same project. "Generic" works for one cluster; with a second, the explicit `/_prometheus/metrics/<dataset>/<namespace>/api/v1/write` form separates them (or the `data_stream_dataset` and `data_stream_namespace` labels, through Elastic's managed remote write endpoint), and lets each data stream have its own retention. Chapter 02 shows both.

---

## What superdemo has that this course does not

So you know what you are walking into:

- Three collector tiers (cluster, daemonset, gateway) via the `opentelemetry-kube-stack` Helm chart, plus tail-based sampling and Fleet enrolment over OpAMP.
- EDOT auto-instrumentation for Java, .NET, Node and Go.
- Kafka, Postgres, MySQL, and per-database collector sidecars.
- The full trading app: recorders, canary deployments, an eBPF variant, and the `monkey` chaos API.
- Traefik, and the whole terraform/GKE deploy path.

None of that changes what you learned about Prometheus. All of it changes how long it takes to install.
