# Chapter 07 — Grafana, pointed at Elastic

**Goal:** the payoff. Keep your Grafana, keep your dashboards, keep your PromQL — change the storage underneath and nothing above it notices.

---

## The idea

The obvious question from anyone who already runs Prometheus, and the one that decides whether they move at all:

> "So I have to rebuild my dashboards?"

No. Elasticsearch exposes a **Prometheus-compatible read API** — point Grafana at it as a `type: prometheus` datasource and Grafana cannot tell the difference. From `superdemo/utils/prometheus-grafana/grafana.yaml`:

```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090

  - name: Elastic
    type: prometheus                                    # <- both are prometheus
    url: $es_endpoint/_prometheus/metrics-generic.prometheus-default
    isDefault: true
    jsonData:
      httpHeaderName1: 'Authorization'
    secureJsonData:
      httpHeaderValue1: 'ApiKey $api_key'
```

Two datasources, **both `type: prometheus`**. One is a real Prometheus, one is Elasticsearch, and Grafana treats them identically. That is the whole trick, and it fits on one screen. Note the URL carries the data stream — the read side of the endpoint you have been writing to since chapter 02.

---

## Do it

```bash
make grafana
```

`build.sh` renders both, substituting `$ELASTIC_ES_URL` and `$DATA_STREAM`. Open Grafana (`make check` prints the URL) → **Connections → Data sources**. Two entries, both Prometheus.

## Prove it

Explore, pick **Elastic**, and run PromQL:

```promql
up
sum(rate(http_requests_total[5m])) by (region)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, region))
```

The last one is worth pausing on: a histogram quantile, computed by Elasticsearch, answered through the Prometheus API, rendered by Grafana. Nothing in that sentence required a migration.

Switch the dropdown to **Prometheus** and run it again. Same shape, different source; the panel does not care.

**Say the honest version out loud:** Elastic goes back as far as your retention, Prometheus goes back six hours. That asymmetry is the whole reason to do this.

---

## What does not survive

Be precise, because an over-claim gets found out. Elasticsearch implements a **subset** of the Prometheus HTTP API. Measured through Grafana's proxy on this course's Serverless project:

- **Instant and range queries, label values, series and metadata** all answer — so template variables such as `label_values(redis_up, instance)` work.
- **Exemplars** do not: `/api/v1/query_exemplars` has no handler, so a panel that overlays exemplars on a histogram shows the histogram without them.

One difference is not an error. A variable lists every value inside the time range you ask for, and Elastic can answer for a far longer range than Prometheus — so a variable can offer pods that are long gone. That is the retention argument, turning up in a dropdown.

The claim that survives contact: **your queries, panels and variables port; exemplars do not.** Stronger than "it all just works", because it is true.

---

## Then look at it in Kibana

The point of centralising was never to keep Grafana forever — it was to stop having two systems.

```bash
make import
```

```
OK:   Imported 2 saved object(s).
       tag  metrics
       search  Prometheus

  open: https://<your-kibana>/app/discover#/view/<id>
```

Follow the `open:` link. It is superdemo's `assets/objects/metrics_esql.ndjson`, imported **unmodified**, because you have been writing to the data stream it reads:

| Tab | Query | Against your data |
|---|---|---|
| `node.js prom (remote_write)` | `TS metrics-generic.prometheus-default` | works — what chapter 02 built |
| `PROMQL` | `PROMQL index=metrics-* … sum by (region) (rate(metrics.http_requests_total[5m]))` | works, and groups by `region` — which only has a value because of chapter 03 |
| third tab | `TS metrics-prometheusreceiver.otel-default` | **nothing of yours** |

The middle one is worth saying out loud: PromQL, typed into Kibana, over a data stream, grouped by a label you created with a relabel rule. Two chapters of your work in one query somebody else wrote.

The third tab is the gap chapter 05 explained — your collector exports to `debug`, so it writes nothing there. **If you share a project with other demos**, that data stream is not course-specific and may already hold unrelated data; check the timestamps.

---

## Grade it

```bash
make test
```

The test runs a PromQL query through Grafana's proxy against the Elastic datasource — the whole path a dashboard would use, not just that the config exists.

## What you now know

| | |
|---|---|
| **`type: prometheus` twice** | Elasticsearch's read API is Prometheus's API |
| **Nothing above the datasource changes** | same PromQL, same panels, same dashboards |
| **Retention is the argument** | six hours vs however long you pay for |
| **The subset is real** | queries, panels and variables port; exemplars do not |
| **superdemo's saved search** | works against your data unmodified, and one tab is empty for a reason |

That is the workshop.

Read `docs/SUPERDEMO-MAP.md` next. It is one page: what you built, where the same thing lives in superdemo, and the eight differences small enough to open a PR for.
