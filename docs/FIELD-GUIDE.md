# Field guide

The workshop's customer-facing material in one place: the story, the PromQL patterns behind every dashboard, the questions to ask, the objections you will hear, and a five-minute demo to run in Kibana. Each part points back to the chapter that teaches it.

---

## The story in five sentences

1. Most of your Kubernetes customers already run Prometheus, because it is the default for Kubernetes metrics: an open format, hundreds of exporters, and PromQL, which their engineers already know.
2. What they struggle with is around it: a Prometheus server keeps weeks of data on one disk for one cluster, so longer history, a view across clusters and metrics next to logs and traces each mean running another system.
3. Remote write adds Elastic as a destination with one block of config; Prometheus keeps scraping, and its rules and alerts keep working (chapter 02).
4. The same PromQL runs in Kibana and, through Elastic's Prometheus API, in their existing Grafana, so dashboards and skills carry over (chapter 07).
5. They decide what is kept where and for how long, with filtering in Prometheus and retention and downsampling in Elastic (chapter 06).

---

## The value, chapter by chapter

| Chapter | The customer's problem | The Prometheus skill | What Elastic adds |
|---|---|---|---|
| 01 | health signals without an agent in every app | pull, `/metrics`, `up` | — (it starts here) |
| 02 | data stuck on one disk, one cluster, 15 days by default | remote write, `external_labels` | retention, one view across clusters, PromQL in Kibana |
| 03 | metrics nobody can group; new services unmonitored | discovery, relabeling, RED queries | the same labels as dimensions, queried over any range |
| 04 | "is it the app or the platform?" | exporters, kube-state-metrics | cluster state and app metrics in one data stream |
| 05 | silent data loss in the pipeline | collector self-metrics, in minus out | one place to watch Prometheus and OpenTelemetry paths |
| 06 | cost and cardinality | filter at the scrape, at remote write | retention and downsampling per data stream |
| 07 | years of Grafana dashboards | the Prometheus HTTP API | Grafana keeps working; Kibana dashboards in PromQL |

---

## PromQL patterns you'll see in every customer dashboard

Learn to read these and you can read most dashboards a customer shows you.

| Pattern | Example | Answers | Chapter |
|---|---|---|---|
| Health | `up == 0` | which targets stopped answering | 01 |
| Freshness | `time() - <newest timestamp>` | how long since something last happened | 02 |
| Rate of a counter | `rate(http_requests_total[5m])` | per second, coping with restarts | 03 |
| Aggregate to the question | `sum by (region) (...)` | one line per thing the business asks about | 03 |
| Latency percentile | `histogram_quantile(0.95, sum by (le, region) (rate(..._bucket[5m])))` | what slow requests users feel; averages hide them | 03 |
| Inventory | `count by (namespace, service) (up)` | how many of each thing, grouped | 03 |
| Ratio | `sum by (x) (a) / sum by (x) (b)` | availability, replicas, error ratio | 04 |
| Threshold | `... > 0` | only the rows that need attention | 04 |
| Conservation | `sum(rate(in[5m])) - sum(rate(out[5m]))` | is a stage losing data | 05 |
| Absent, not zero | an empty result | "never happened" is not the same as 0 | 05 |
| Cardinality | `sum by (job) (scrape_samples_scraped)` | which job drives series count, and cost | 04, 06 |

Together, rate, error ratio and percentile are **RED** (rate, errors, duration), the usual first dashboard for a service.

---

## Questions to ask

- How many Prometheus servers do you run, who owns them, and how long do they keep data? (01)
- How many clusters, and how do you see across them today? (02)
- How would you know if a cluster stopped sending metrics? (02)
- How does a new service get monitored: a ticket, a config change, or automatically? (03)
- When an incident starts, where do people look first? (04)
- Are you standardising on Prometheus, OpenTelemetry, or both? (05)
- Which metrics do your dashboards and alerts actually use, and for how long do you need full resolution? (06)
- Which five Grafana dashboards would you test first? (07)

To size it, ask for three numbers:

- Active series and ingest rate, across their servers: `sum(prometheus_tsdb_head_series)` and `sum(rate(prometheus_tsdb_head_samples_appended_total[5m]))`. (06)
- What metrics cost them today: the long-term store's infrastructure and the people who run it, or a vendor's bill.
- How long they must keep metrics, who sets that, and what is forcing a decision this year.

---

## Where alerts run

Customers ask this right after dashboards.

- **Per-cluster rules and Alertmanager stay in Prometheus.** Remote write doesn't change them.
- **Alerts across clusters run in Kibana**, as rules over the data in Elastic. "Which cluster stopped sending?" is an ES|QL query, because `absent()` isn't available in Kibana's PromQL:

  ```esql
  TS metrics-generic.prometheus-default
  | WHERE @timestamp > NOW() - 1 day
  | STATS newest = MAX(@timestamp) BY cluster = labels.cluster
  | EVAL quiet = DATE_DIFF("minute", newest, NOW())
  | WHERE quiet > 5
  ```

  No rows means every cluster sent something in the last five minutes.

---

## Objections, and honest answers

| They say | You say |
|---|---|
| "We already have Prometheus." | Keep it. Remote write adds a destination; scraping, rules and alerts carry on as before. The send queue costs Prometheus some memory and CPU. (02) |
| "We already run Thanos (or Mimir)." | Then they know why central storage matters. Ask what running it costs in people and infrastructure, and how they get from a metric to the logs behind it today. (02) |
| "We use the Prometheus Operator." | ServiceMonitors do what this course's annotations do. Everything after discovery works the same. (03) |
| "We'll just send everything." | A reasonable start. Show the series count per job, and agree who reviews it. (06) |
| "Do we have to rebuild our dashboards?" | Often not: Elastic is a Prometheus datasource for Grafana. Test their top dashboards, and be precise about the gaps below. (07) |
| "Does Elastic support all of PromQL?" | Not yet, and say so. Every query in this course runs; the gaps are listed below and in Elastic's docs. |

---

## Five-minute demo, in Kibana

Run it against a cluster at the end of chapter 07, or a running superdemo. Every query is in `queries/esql/`, and `make links` opens each one in Discover.

1. **"Your Prometheus, unchanged."** Show `prometheus/prometheus.yml`: scrape jobs, and one `remote_write` block. *Nothing else changed in Prometheus.*
2. **"Every cluster, in one place."** `count by (cluster, env) (up)` (`02-clusters.esql`). *One row per cluster; a missing row is a cluster that stopped sending.*
3. **"The questions your dashboards ask."** Requests per region, then p95 latency (`03-requests-by-region.esql`, `03-p95-latency.esql`). *The same PromQL your engineers write, here over as much history as you keep.*
4. **"App or platform?"** Deployments at their replica count (`04-replicas.esql`). *Cluster state next to the app, under the same labels.*
5. **"Keep Grafana."** Grafana Explore on the Elastic datasource, the same p95 query. *The PromQL in their dashboards runs here too; test their top five first.*
6. **"You decide what it costs."** Samples kept per job (`06-kept-per-job.esql`). *Filter what nobody uses, keep debug data local, set retention per data stream.*

Close with the question that matters for them: which of these problems do they have today?

---

## Be precise

Measured on this course's Serverless project, 31 October 2026. Re-check before you promise more, and point customers at [Elastic's PromQL limitations page](https://www.elastic.co/docs/reference/query-languages/promql/promql-limitations).

- **PromQL in Kibana** (`PROMQL`) ran every query in this course, except these:
  - `absent()` is not implemented, and `absent_over_time` on a metric that has never existed doesn't behave as it does in Prometheus.
  - Metric-name patterns such as `{__name__=~"kube_.*"}` are rejected.
  - `label_replace` works only inside a `by()`.
  - Dividing two different metrics needs both sides aggregated by their matching labels.
- **Through Grafana**, instant and range queries, label values, series and metadata answer; exemplars do not.
- **Field shape:** remote write stores values under `metrics.` and labels under `labels.`, and infers counters from the `_total`, `_sum`, `_count` and `_bucket` suffixes. PromQL hides the prefixes; ES|QL shows them.
- **No staleness markers:** a series that stops stays visible until its last sample leaves the query's window.
- **Empty, not zero:** a ratio whose numerator has no series, such as an error ratio with no `5xx` traffic, returns no result rather than 0.
- **Grafana datasource:** the URL takes a data stream or a pattern; `metrics-*.prometheus-*` reads them all.
- **Production endpoint:** on Serverless and Elastic Cloud Hosted, Elastic recommends its managed remote write endpoint over writing to Elasticsearch directly, as this course does (chapter 02).

---

## Numbers you can cite

Elastic's own published figures. Quote them as Elastic states them, with the link, including the "up to".

- PromQL and Prometheus remote write are generally available in Elastic Serverless and Elastic Stack 9.5: [What's new in 9.5](https://www.elastic.co/blog/whats-new-elastic-9-5-0).
- "Keep Prometheus scraping and add Elastic as a `remote_write` target": [Elastic docs, metrics](https://www.elastic.co/docs/solutions/observability/metrics).
- "Up to 30x faster and with up to 2.5x better storage efficiency" than Prometheus, on Elastic's own benchmark; read its setup before you quote it: [the benchmark](https://www.elastic.co/search-labs/blog/elasticsearch-columnar-metrics-engine-30x-faster-prometheus).
- Downsampling "cuts time series storage by 94% in our OTel benchmark", and ES|QL dashboards on raw data run unchanged on downsampled data: [downsampling](https://www.elastic.co/search-labs/blog/elasticsearch-downsampling-methods-esql).
- Grafana can query Elasticsearch through its native Prometheus API: [Grafana setup](https://www.elastic.co/docs/reference/query-languages/promql/promql-grafana).
