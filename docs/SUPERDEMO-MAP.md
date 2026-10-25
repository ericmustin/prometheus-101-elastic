# What you built, and where it is in superdemo

Read this last. It is the reason the course uses superdemo's names, ports, namespaces and file layout instead of inventing its own: so that this table is short, and so that the differences are the interesting part.

Everything below was verified against a live run of both.

---

## The five files

superdemo's entire Prometheus surface is five files. You have now written the equivalent of all of them.

| You built | superdemo | |
|---|---|---|
| `src/router/` | `superdemo/src/router/` | **byte-identical** — vendored unmodified |
| `utils/redis/redis.yml` | `superdemo/utils/redis/redis.yml` | **byte-identical** |
| `utils/ksm/ksm.sh` | `superdemo/utils/ksm/ksm.sh` | **byte-identical** |
| `prometheus/prometheus.yml` | inside `utils/prometheus-grafana/grafana.yaml` | rewritten — see below |
| `utils/prometheus-grafana/grafana.yaml` | same path | same two datasources, rendered rather than hardcoded |

---

## The scrape config

This is where the course and superdemo genuinely differ, and the differences are all fixable.

| | You | superdemo |
|---|---|---|
| How targets are found | `kubernetes_sd_configs` + three annotations | three hostnames typed by hand |
| Job name | `kubernetes-pods` | `prometheus` — **a job named `prometheus` that does not scrape Prometheus** |
| Namespace label | discovered per target | `labels: {namespace: 'infra'}` on all three — **and two of them are in `trading-na` / `trading-emea`** |
| Adding a workload | annotate it | edit `grafana.yaml`, redeploy Prometheus |
| `external_labels` | `cluster`, `env` | **none** — every series is anonymous once it lands |
| Image | `prom/prometheus:v3.7.3` | `prom/prometheus` — **unpinned**, so an upstream push changes the demo |
| Storage | a PVC | **none** — a pod restart loses all local history |

---

## Eight things you could open a PR for on Monday

Each of these is real, each is small, and you now know why each one matters.

**1. `k8s/router.yaml` has no scrape annotation.** The router is the only service in superdemo that exposes `/metrics`, and nothing declares it. That is why the scrape config has to name it by hostname. Two lines fix it:

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "9000"
```

**2. The `namespace: 'infra'` label is wrong for two of its three targets.** Anything that groups by namespace in Kibana or Grafana is silently merging two regions into one.

**3. kube-state-metrics is installed and never scraped.** `utils/ksm/ksm.sh` runs the helm install; no scrape config mentions it. All of that cluster state is being paid for in cluster resources and none of it reaches Elastic.

**4. `utils/redis/redis.yml`'s scrape annotations have never done anything.** They have been there since the file was written. They are correct. Nothing reads them, because superdemo does not use annotation discovery.

**5. `metrics-prometheusreceiver.otel-default` has no producer.** `assets/objects/metrics_esql.ndjson` ships a "Prometheus" saved search whose third tab queries a data stream nothing writes to. Two closed doors: `scrape_configs_file: ""` in `agents/apm/serverless.yaml`, and no `io.opentelemetry.discovery.metrics` annotation on the router. The course's chapter 05 opens the second one.

**6. The collectors expose no Prometheus endpoint.** Self-telemetry goes out over OTLP to the gateway on `:4319`. That is a legitimate choice, and it means you cannot answer "is the collector dropping my data" in PromQL. Adding a pull reader to `service.telemetry.metrics.readers` is about six lines and is what chapter 05 has you do.

**7. `transactions` and `shares_traded` are named without `_total`.** Elasticsearch infers metric type from the name suffix, so **both arrive as gauges**:

```
metrics.http_requests_total | counter   <- has _total
metrics.shares_traded       | gauge     <- should be a counter
metrics.transactions        | gauge     <- should be a counter
```

`RATE()` does not apply to a gauge. Renaming them in `src/router/app.ts` to `transactions_total` and `shares_traded_total` would make the two most business-relevant metrics in the demo behave correctly in ES|QL.

**8. `image: prom/prometheus` is unpinned and there is no PVC.** The first means a registry push can change the demo under you. The second means every Prometheus restart starts the graphs from zero, which is a bad surprise thirty seconds into a live demo.

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

It is also the thing to change first when a second cluster writes into the same project. "Generic" is a fine name for one cluster and a useless one for the second, and the explicit `/_prometheus/<type>/<dataset>/<namespace>/api/v1/write` form is how you separate them. Chapter 02 shows both.

---

## Where the course deliberately goes further

Not criticism — these are things a one-hour teaching environment can afford and a demo that has to install in eight minutes cannot.

- **Annotation-driven discovery** rather than hostnames. superdemo has three targets; the argument only starts paying at ten.
- **`metric_relabel_configs` and `write_relabel_configs`.** superdemo has neither, and at three targets it does not need them. Chapter 06 is about the point where that stops being true — kube-state-metrics alone is 1,239 series on a 13-pod cluster and 1,316 on a 14-pod one — it scales with the cluster rather than with your app.
- **A Prometheus-facing read path.** superdemo provisions the Elastic datasource in Grafana already; chapter 07 has you actually query through it, including a histogram quantile, and find out where the API subset ends.
- **A pinned image and a PVC.**
- **`external_labels`.**

---

## What superdemo has that this course does not

So you know what you are walking into:

- Three collector tiers (cluster, daemonset, gateway) via the `opentelemetry-kube-stack` Helm chart, plus tail-based sampling and Fleet enrolment over OpAMP.
- EDOT auto-instrumentation for Java, .NET, Node and Go.
- Kafka, Postgres, MySQL, and per-database collector sidecars.
- The full trading app: recorders, canary deployments, an eBPF variant, and the `monkey` chaos API.
- Traefik, and the whole terraform/GKE deploy path.

None of that changes what you learned about Prometheus. All of it changes how long it takes to install.
