# Chapter 05 — Scrape the collector

**Goal:** be able to answer "is the collector dropping my data" — which in a superdemo environment you currently cannot.

---

## The idea

superdemo's telemetry does not go through Prometheus at all. It goes through three tiers of EDOT collectors, which raises a question someone will ask you sooner or later: **when telemetry goes missing, how do you tell whether the collector is the problem?**

Right now, mostly you cannot. From superdemo's `agents/apm/serverless.yaml`:

```yaml
        telemetry:
          metrics:
            readers:
              - periodic:
                  exporter:
                    otlp:
                      endpoint: "http://opentelemetry-kube-stack-gateway-collector-headless:4319"
```

Self-telemetry goes over OTLP to the gateway. Reasonable — and it means there is **no Prometheus endpoint anywhere in superdemo**, so none of the tooling you have spent four chapters building can see it. This chapter is the six-line fix.

---

## Deploy a collector

```bash
make collector
```

One collector rather than superdemo's three tiers, on the same image (`elastic-agent:9.5.0`, invoked as `elastic-agent otel`).

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

A `pull` reader instead of superdemo's `periodic`/`otlp` one: the collector now serves its own metrics in Prometheus format.

Port **8889**, not the conventional 8888, because superdemo's daemonset collector runs `hostNetwork: true` — a port you bind is a port on the node.

---

## The four metrics that matter

```promql
otelcol_receiver_accepted_metric_points     # came in
otelcol_receiver_refused_metric_points      # came in and was rejected
otelcol_exporter_sent_metric_points         # went out
otelcol_exporter_send_failed_metric_points  # tried to go out and failed
```

Read them as a pipeline: `accepted` minus `sent` is data that entered and did not leave — buffering, a processor dropping it, or a broken exporter.

```promql
  sum(rate(otelcol_receiver_accepted_metric_points[5m]))
- sum(rate(otelcol_exporter_sent_metric_points[5m]))
```

Near zero in a healthy collector. (Empty straight after `make collector`: `rate` needs two scrapes, so give it half a minute.)

Prometheus may also show two yellow *Query notice* boxes saying the metric "might not be a counter". It is one, as its metadata says: Prometheus guesses from a `_total` suffix, and these names do not have one. The notice is a guess, not an error, and the number under it is right.

**One thing that will confuse you:** `otelcol_exporter_send_failed_metric_points` may not exist at all. OpenTelemetry creates these lazily — a counter that has never counted is **absent, not zero**. An empty result means "this has never happened", which is the answer you wanted but not the answer PromQL appears to give.

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

This matters in superdemo specifically: `assets/objects/metrics_esql.ndjson` ships a saved search whose third tab queries `TS metrics-prometheusreceiver.otel-default`, and **nothing in superdemo writes there**. Two doors are closed — `scrape_configs_file: ""` in `agents/apm/serverless.yaml`, and no `io.opentelemetry.discovery.metrics` annotation on the router. Pointing this receiver's exporter at Elastic opens one.

Two ways to get the router's metrics into Elastic, and superdemo has the plumbing for both:

| | Path | Lands in |
|---|---|---|
| What you built | router → Prometheus → remote write | `metrics-generic.prometheus-default` |
| What superdemo half-built | router → collector → OTLP | `metrics-prometheusreceiver.otel-default` |

Neither is wrong. Remote write gives you `metrics.*` / `labels.*` and the Prometheus read API; OTLP gives you the OTel field model and everything else the collector can do on the way through. What you should not do is run both by accident and wonder why one metric has two shapes.

---

## Grade it

```bash
make test
```

## What you now know

| | |
|---|---|
| **Collectors are scrape targets** | if you give them an endpoint, which superdemo does not |
| **`pull` vs `periodic` readers** | Prometheus format on a port, or OTLP to a gateway |
| **The four counters** | accepted / refused / sent / send_failed, read as a pipeline |
| **Lazy metric creation** | a counter that never counted is absent, not zero |
| **`hostNetwork`** | a port you bind is a port on the node |
| **A collector can be a Prometheus** | and in superdemo that path is wired but switched off |

Next: the bill.
