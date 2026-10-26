# Chapter 07 — Grafana, pointed at Elastic

**Goal:** add Elastic to Grafana as a second datasource, so existing dashboards and PromQL can read from Elastic, then see the same data in Kibana.

---

## Where you are

Everything you collect reaches Elastic. Grafana, in `infra`, reads only the local Prometheus, which holds about six hours. This chapter adds Elastic as a second Grafana datasource and opens the same data in Kibana.

Grade it before you start:

```bash
make test
```

Chapters 01 to 06 pass. Chapter 07's checks fail: Grafana has one datasource, not two.

---

## The idea

The first question from most teams that already run Prometheus:

> "So I have to rebuild my dashboards?"

Often not. Elasticsearch exposes a **Prometheus-compatible read API**: point Grafana at it as a `type: prometheus` datasource, and Grafana queries it the same way it queries Prometheus. From `superdemo/utils/prometheus-grafana/grafana.yaml`, trimmed:

```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus.infra.svc.cluster.local:9090

  - name: Elasticsearch
    type: prometheus                                    # <- both are prometheus
    url: "$elasticsearch_es_endpoint/_prometheus/metrics-generic.prometheus-default"
    isDefault: true
    jsonData:
      httpMethod: GET
      httpHeaderName1: "Authorization"
    secureJsonData:
      httpHeaderValue1: "ApiKey $elasticsearch_api_key"
```

Two datasources, **both `type: prometheus`**. One is a real Prometheus, one is Elasticsearch, and Grafana talks to both the same way. The whole change fits on one screen. Note the URL carries the data stream — the read side of the endpoint you have been writing to since chapter 02.

This workshop's copy, in `utils/prometheus-grafana/grafana.yaml`, is the same pair, with the second one named `Elastic` and its URL filled in from your `.env`. Keep `httpMethod: GET`: Grafana sends POST by default, and Elasticsearch accepts a form-encoded POST only when TLS terminates on Elasticsearch itself.

---

## Do it

```bash
make grafana
```

Grafana starts with one datasource, the local Prometheus. `make grafana` adds the Elastic one: `build.sh` renders it, substituting `$ELASTIC_ES_URL`, `$DATA_STREAM` and `$ELASTIC_API_KEY`, and restarts Grafana so it reads the new list. Open Grafana (`make check` prints the URL) → **Connections → Data sources**. Two entries, both Prometheus.

## Prove it

Explore, pick **Elastic**, and run PromQL:

```promql
up
sum(rate(http_requests_total[5m])) by (region)
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, region))
```

The last one is worth pausing on: a histogram quantile, computed by Elasticsearch, answered through the Prometheus API, rendered by Grafana. Nothing in that sentence required rebuilding a dashboard.

Switch the dropdown to **Prometheus** and run it again. Same shape, different source; the panel does not care.

**The difference to point out:** this Prometheus keeps six hours; Elastic keeps what the data stream's retention says. Longer history, across clusters and next to logs and traces, is one of the main reasons teams centralise.

---

## What carries over, and what doesn't

Be precise with customers. Elasticsearch implements a **subset** of the Prometheus HTTP API. Measured through Grafana's proxy on this course's Serverless project:

- **Instant and range queries, label values, series and metadata** all answer — so template variables such as `label_values(redis_up, instance)` work.
- **Exemplars** do not: `/api/v1/query_exemplars` has no handler, so a panel that overlays exemplars on a histogram shows the histogram without them.

One difference is not an error. A variable lists every value inside the time range you ask for, and Elastic can answer for a far longer range than Prometheus — so a variable can offer pods that are long gone. That is the retention argument, turning up in a dropdown.

What held up here: **the course's queries, panels and template variables worked through Elastic; exemplars did not.** Test a customer's own dashboards before you promise more than that.

---

## Then look at it in Kibana

Many teams keep Grafana. Kibana reads the same data with ES|QL and PromQL, next to logs and traces, so either can be the front end.

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
| `PROMQL` | `PROMQL index=metrics-* … sum by (region) (rate(metrics.http_requests_total[5m]))` | works, and groups by `region`, which has a value once chapter 03 scrapes the routers |

The second one is worth saying out loud: PromQL, typed into Kibana, over a data stream, grouped by a label that arrived with the router's metrics in chapter 03. Two chapters of your work in one query somebody else wrote.

Its third tab reads `metrics-prometheusreceiver.otel-default`, the collector-as-scraper path from chapter 05. Your collector exports to `debug`, so that tab stays empty. **If you share a project with other demos**, that data stream is not course-specific and may already hold unrelated data; check the timestamps.

---

## Grade it

```bash
make test
```

Chapter 07's checks: Grafana is deployed with two datasources, both `type: prometheus`; one points at Elasticsearch's `_prometheus` endpoint; and it answers a PromQL query through Grafana's proxy, the whole path a dashboard uses, not just that the config exists.

## In the field

- **In superdemo:** Grafana has the same two datasources, and Kibana has the saved search you imported, with its PromQL tab. Those are the two places to show this chapter's outcome.
- **What customers ask:** "Do we have to rebuild our dashboards?" Often not: Elastic can be a Prometheus datasource in Grafana. Ask which dashboards matter most and whether they use exemplars, and try those first.
- **Tailor it:** the datasource URL names a data stream, so point each team's Grafana at the data stream it writes to.
- **Keep the key in a Secret:** here, as in superdemo, the API key is written into Grafana's datasource ConfigMap, which is fine for a lab. In a customer's cluster, put it in a Secret, give it to Grafana as an environment variable, and reference that variable in `secureJsonData`: Grafana expands environment variables in provisioning files.

## What you now know

| | |
|---|---|
| **`type: prometheus` twice** | Elasticsearch's read API speaks the Prometheus HTTP API |
| **Above the datasource** | the course's PromQL, panels and variables worked unchanged |
| **Retention** | six hours here; Elastic keeps what each data stream's retention says |
| **A subset of the API** | test exemplars, and a customer's own dashboards |
| **superdemo's saved search** | works against your data unmodified |

That is the workshop. You now know what each piece of superdemo's Prometheus setup does, why it is there, and how to change it for a customer's environment.

When you open superdemo next, `docs/SUPERDEMO-MAP.md` shows where each piece you built lives there.
