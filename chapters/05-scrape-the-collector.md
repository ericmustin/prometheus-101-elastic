# Chapter 05 — Scrape the collector

**Goal:** scrape an OpenTelemetry collector's own metrics, so you can tell whether it is dropping data.

## Why it matters

- **The problem:** many pipelines have a collector between the apps and the backend, and when telemetry goes missing the first question is whether the collector dropped it. Data lost silently is the most expensive kind of failure: nobody knows the dashboards are wrong.
- **What Prometheus does:** a collector can serve its own counters on a Prometheus endpoint, and the discovery rules you already wrote find it like any other workload.
- **Why it's worth it:** OpenTelemetry and Prometheus increasingly run side by side, and Elastic takes both. Monitoring the pipeline with the same tools as the apps means one way of working, not two.

---

## Where you are

Prometheus collects the app, Redis and the cluster's state. Between apps and Elastic there is often an OpenTelemetry collector, and collectors report on their own health. This chapter deploys one and lets chapter 03's rules scrape it.

![Where you are, before chapter 05: Many pipelines have a collector between the apps and Elastic. This chapter: Deploy an EDOT collector. Chapter 03's rules find it.](../docs/images/topology-05-before.png)

```bash
make goals
```

Chapters 01 to 04 pass. Chapter 05's are to do, starting with deploying a collector.

---

## The idea

Between your apps and Elastic there is often a collector, and when telemetry goes missing someone will ask: **is the collector dropping it?**

The collector can answer that itself. It counts what it receives, refuses, sends and fails to send, and where those counts go is configuration. superdemo's collectors send theirs over OTLP to a gateway. Here you give one collector a Prometheus endpoint instead, and let chapter 03's rules find it.

---

## Deploy a collector

**▶ Your turn:**

```bash
make collector
```

One collector, on the same image superdemo runs (`elastic-agent:9.5.0`, invoked as `elastic-agent otel`).

Look at the Targets page. **It is already there** — chapter 03's rules found it, because the manifest carries the same two annotations everything else does. Third workload, still zero scrape config.

---

## What made it visible

The annotations, and the reader in this repo's `agents/apm/local.yaml` that gives them something to point at:

```yaml
    service:
      telemetry:
        metrics:
          readers:
            - pull:
                exporter:
                  prometheus:
                    host: 0.0.0.0
                    port: 8889
```

A `pull` reader: the collector serves its own metrics in Prometheus format, on a port, for anything to scrape. A `periodic` reader would push them over OTLP instead.

Port **8889**, not the usual 8888. A collector that runs with `hostNetwork: true`, as node-level collectors often do, binds its ports on the node itself, so two collectors on one node cannot both have 8888.

---

## The four metrics that matter

```promql
otelcol_receiver_accepted_metric_points     # came in
otelcol_receiver_refused_metric_points      # came in and was rejected
otelcol_exporter_sent_metric_points         # went out
otelcol_exporter_send_failed_metric_points  # tried to go out and failed
```

Read them as a pipeline: `accepted` minus `sent` is data that entered and did not leave — buffering, a processor dropping it, or a broken exporter. In Kibana:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  sum(rate(otelcol_receiver_accepted_metric_points[5m]))
  - sum(rate(otelcol_exporter_sent_metric_points[5m]))
```

Near zero in a healthy collector. (Empty straight after `make collector`: `rate` needs two scrapes, so give it half a minute.)

*Why this shape:* in minus out is a conservation check. It works for any stage that should pass everything through, and a line that stays above zero is the alert.

**One thing that surprises people:** the fourth counter may not exist at all.

```esql
PROMQL index=metrics-generic.prometheus-default time=?_tend
  otelcol_exporter_send_failed_metric_points
```

**No results.** The collector creates some counters lazily, and this one is **absent, not zero**, until a send first fails. (Others, such as `otelcol_receiver_refused_metric_points`, appear at 0 from the start.) An empty result means "this has never happened", which is the answer you wanted but not the answer it appears to give. An alert written as `send_failed > 0` is fine; one that expects the series to exist never fires.

If you run these in the Prometheus expression browser instead, it may show two yellow *Query notice* boxes saying the metric "might not be a counter". It is one: Prometheus guesses from a `_total` suffix, and these names do not have one. Elasticsearch guesses from the suffix too, and stores them as gauges. PromQL's `rate()` works on them anyway, in both places; ES|QL's own `RATE()` would refuse them, because it requires a counter. Names are an interface.

---

## The other half: the collector as a Prometheus

Look at what else `agents/apm/local.yaml` has this collector doing:

```yaml
    receivers:
      prometheus:
        config:
          scrape_configs:
            - job_name: router-via-otel
              static_configs:
                - targets:
                    - router.trading-na.svc.cluster.local:9000
                    - router.trading-emea.svc.cluster.local:9000
```

It is scraping the router. A collector with a `prometheus` receiver **is** a Prometheus for collection purposes.

That gives you two ways to get the router's metrics into Elastic:

| | Path | Lands in |
|---|---|---|
| What you built | router → Prometheus → remote write | `metrics-generic.prometheus-default` |
| A collector as the scraper | router → collector → OTLP | `metrics-prometheusreceiver.otel-default` |

Here the collector's receiver exports to `debug`, so only the first one writes to Elastic.

Neither is wrong. Remote write gives you `metrics.*` / `labels.*`; OTLP gives you the OTel field model and everything else the collector can do on the way through. Both land in time series data streams that PromQL in Kibana can read, but the same metric has different field names on each path. Choose one path per metric: running both sends the same data twice, in two shapes.

---

## Grade it

```bash
make test
```

Chapter 05's checks: the collector is deployed; it was found by the same annotation rules, with no config change; its `otelcol_*` metrics are being scraped, including accepted and sent points and its memory; it is accepting data; and accepted minus sent answers in Kibana.

## What you collect now

![What you collect after chapter 05: The collector's own health, found by the same discovery rules. Now you can answer: Is the collector accepting and sending everything it receives?](../docs/images/topology-05-after.png)

## In the field

- **Say it:** "Your collectors report what they receive and what they send. Put those counters next to everything else, and 'did we lose data?' is a query, not a guess."
- **Ask:** "Do you run collectors between your apps and your backend, and who watches them?" and "Are you standardising on Prometheus, OpenTelemetry, or both?"
- **If they say** "Should our Prometheus metrics come through remote write or a collector?": both work, and they land with different field shapes. Pick one path per metric, so the same data doesn't arrive twice, and prefer the one their teams already operate.
- **Good practice:** treat collectors as part of the pipeline you monitor: alert on refused and failed points, and on accepted minus sent staying above zero.
- **In superdemo:** the EDOT collectors in `agents/apm/` run in three tiers, and each reports the same `otelcol_*` counters. There they go over OTLP to a gateway, not to a Prometheus endpoint.

**Explain it back:** a customer asks how they would know their collectors are dropping data. What do you show them, and why is an empty `send_failed` not proof that nothing failed?

## What you now know

![Chapter 05 on one page: deploy a collector and change no config; chapter 03's rules find it through its annotations and a pull reader on port 8889. Read its counters as a pipeline: accepted minus sent, and send_failed is absent, not zero, until a send first fails.](../docs/images/05-scrape-the-collector.png)

| | |
|---|---|
| **Collectors are scrape targets** | once a `pull` reader gives them an endpoint |
| **`pull` vs `periodic` readers** | Prometheus format on a port, or OTLP to a gateway |
| **The four counters** | accepted / refused / sent / send_failed, read as a pipeline |
| **In minus out** | the conservation check; above zero is the alert |
| **Lazy metric creation** | `send_failed` is absent, not zero, until a send first fails |
| **`hostNetwork`** | a port you bind is a port on the node |
| **A collector can be a Prometheus** | a `prometheus` receiver scrapes, then exports over OTLP |

Next: choosing what to send.
