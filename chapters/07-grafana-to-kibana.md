# Chapter 07 — Grafana, pointed at Elastic

**Goal:** add Elastic to Grafana as a second Prometheus datasource, so existing dashboards and PromQL read from Elastic, then keep the same queries in a Kibana dashboard.

**Time:** 7 minutes

## Why it matters

Teams that run Prometheus have years of Grafana dashboards and PromQL habits, and nobody wants to rebuild them. Elasticsearch speaks the Prometheus HTTP API, so it can sit behind a Grafana `prometheus` datasource. It's "and", not "or": Grafana keeps its dashboards and gains retention and a view across clusters, and Kibana runs the same PromQL next to logs and traces.

![Where you are, before chapter 07: Everything reaches Elastic. Grafana reads only the local Prometheus. This chapter: Add Elastic as a second Grafana datasource.](../docs/images/topology-07-before.png)

## Steps at a glance

1. Start the chapter: `make chapter 7`
2. Add Elastic as a Grafana datasource: `make grafana`
3. Run PromQL against Elastic in Grafana's Explore
4. Save the same queries to a Kibana dashboard
5. Import superdemo's saved search: `make import`
6. Grade it: `make test`

## Step 1 · Start the chapter

```bash
make chapter 7
```

## Step 2 · Add Elastic to Grafana

```bash
make grafana
```

`make grafana` adds a second datasource to Grafana and restarts it. It is the pair superdemo provisions in `utils/prometheus-grafana/grafana.yaml`, trimmed:

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

Both are **`type: prometheus`**. One is a real Prometheus and one is Elasticsearch, and Grafana talks to both the same way. The URL names the data stream you have been writing to since chapter 02. This workshop's copy names the second one `Elastic` and fills in the URL and key from your `.env`.

## Step 3 · Query Elastic from Grafana

Open Grafana (`make check` prints the URL) → **Explore**, pick the **Elastic** datasource, and run:

```promql
histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, region))
```

You should see two lines, `na` and `emea`. That is a histogram quantile computed by Elasticsearch, answered through the Prometheus API and drawn by Grafana, with no dashboard rebuilt. Switch the datasource to **Prometheus** and run it again: same shape, different source. This Prometheus keeps six hours, and Elastic keeps whatever the data stream's retention says.

<details>
<summary>Note · What carries over, and what doesn't</summary>

Elasticsearch implements a **subset** of the Prometheus HTTP API, and of PromQL. Measured on this course's Serverless project:

- **Through Grafana:** instant and range queries, label values, series and metadata all answer, so template variables such as `label_values(redis_up, instance)` work. **Exemplars** don't: `/api/v1/query_exemplars` has no handler, so a panel that overlays exemplars on a histogram shows the histogram without them.
- **In Kibana's `PROMQL`** (31 October 2026), every query in this course runs, but four kinds of query don't:
  - `absent()` is not implemented, and `absent_over_time` on a metric that has never existed doesn't behave as it does in Prometheus.
  - Metric-name patterns such as `{__name__=~"kube_.*"}` are rejected.
  - `label_replace` works only inside a `by()`.
  - Dividing two different metrics needs both sides aggregated by the labels they match on, as chapter 04's replica query does.

  Beyond this course, `and`, `unless`, `on`, `ignoring`, `group_left`, `@` and subqueries return an error today. Kubernetes dashboards often join series with `group_left`, so test those first. Elastic's [PromQL limitations page](https://www.elastic.co/docs/reference/query-languages/promql/promql-limitations) lists the rest, and the list is getting shorter.

One difference is not an error. A Grafana variable lists every value inside the time range you ask for, and Elastic can answer for a far longer range than Prometheus, so a variable can offer pods that are long gone. That is the retention argument, turning up in a dropdown.

What held up here: the course's queries, panels and template variables worked through Elastic; exemplars did not. Test a customer's own dashboards before you promise more than that.

</details>

<details>
<summary>Note · Keep the key in a Secret</summary>

Here, as in superdemo, the API key is written into Grafana's datasource ConfigMap, which is fine for a lab. In a customer's cluster, put it in a Secret, give it to Grafana as an environment variable, and reference that variable in `secureJsonData`, because Grafana expands environment variables in provisioning files. The datasource URL can also name a pattern: `metrics-*.prometheus-*` reads every Prometheus data stream through one datasource.

</details>

## Step 4 · Save it to a Kibana dashboard

In Kibana's Discover, run chapter 03's requests per region:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  sum by (region) (rate(http_requests_total[5m]))
```

Then **Save visualization to dashboard** (the save icon above the chart), into a new dashboard. Add the p95 query the same way:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  histogram_quantile(0.95, sum by (le, region) (rate(http_request_duration_seconds_bucket[5m])))
```

You should have a Kibana dashboard written entirely in PromQL, over as much history as the data stream keeps.

<details>
<summary>Note · The same question in ES|QL</summary>

PromQL is one way into this data. ES|QL's `TS` command is the other, and it's the one you extend with joins and lookups:

```bash
make esql Q=queries/esql/07-requests-by-region-ts.esql
```

That is the same requests per region, as `SUM(RATE(...)) BY region, TBUCKET(1 minute)`.

</details>

## Step 5 · Import superdemo's saved search

```bash
make import
```

```
OK:   Imported 2 saved object(s).
       tag  metrics
       search  Prometheus

  open: https://<your-kibana>/app/discover#/view/<id>
```

Follow the `open:` link. It is superdemo's `assets/objects/metrics_esql.ndjson`, imported **unmodified**, and it works because you have been writing to the data stream it reads. Its `node.js prom (remote_write)` tab is chapter 02's `TS` view, and its `PROMQL` tab groups requests by `region`.

<details>
<summary>Note · The third tab is empty</summary>

The third tab reads `metrics-prometheusreceiver.otel-default`, the collector-as-scraper path from chapter 05. Your collector exports to `debug`, so that tab stays empty. If you share a project with other demos, that data stream is not specific to this course and may already hold unrelated data, so check the timestamps.

</details>

## Step 6 · Grade it

```bash
make test
```

You should see every check pass: two `type: prometheus` datasources, one of them Elasticsearch's `_prometheus` endpoint, answering PromQL through Grafana's proxy, which is the path a dashboard uses.

## The whole change

No file changes. The commands, in order:

```bash
make chapter 7
make grafana
make import
make test
```

## Say it

"Keep Grafana: add Elastic as a Prometheus datasource, and the PromQL in your dashboards runs against it. Let's test your top five together. The same PromQL runs in Kibana, next to your logs and traces, over as much history as you keep."

![What you collect after chapter 07: Grafana and Kibana both read the same data from Elastic. Now you can answer: The same dashboards and PromQL, over as much history as you keep.](../docs/images/topology-07-after.png)

<details>
<summary>Note · In the field</summary>

- **Ask:** "Which five dashboards would you test first?" and "Do any of them use exemplars, or functions beyond the basics?"
- **If they say** "Do we have to rebuild our dashboards?": often not. Test their most important ones through the Elastic datasource, and be precise about the gaps. Elastic's migration tool, [GA in 9.5](https://www.elastic.co/blog/whats-new-elastic-9-5-0), brings Grafana dashboards and alerts into Kibana; test what it converts, as you would the datasource.
- **In superdemo:** Grafana has the same two datasources, and Kibana has the saved search you imported, with its PromQL tab. Those are the two places to show this chapter's outcome.

</details>

That is the workshop. README's **What you built** walks through the finished pipeline end to end, `docs/FIELD-GUIDE.md` collects the talk tracks and a five-minute demo, and `docs/SUPERDEMO-MAP.md` shows where each piece you built lives in superdemo.
