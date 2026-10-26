# Chapter 01 — Scrape yourself

**Goal:** get one target, any target, and understand what a "target" is.

---

## Where you are

`make setup` left everything running and nothing collected: Prometheus runs with an empty scrape list. This chapter gives it its first target, itself.

Grade it before you start:

```bash
make test
```

Chapter 01's three checks fail. They describe the goal: a job, a healthy target, and samples stored.

---

## The idea

By default, Prometheus does not receive metrics. It goes and gets them.

No agent, no queue. There is a list of HTTP addresses in a config file, and every 15 seconds Prometheus walks it, does a `GET /metrics` on each, and stores whatever comes back. Everything else in this course is elaboration on that loop. (Prometheus 3 can also accept pushed data, through remote write and OTLP receivers you switch on with a flag. This course uses the default: pull.)

Yours is running right now and doing nothing, because its config says:

```yaml
scrape_configs: []
```

---

## Do it wrong first

Prometheus exposes its own metrics on `/metrics`, like anything else it scrapes, so the first target is itself. In `prometheus/prometheus.yml`, replace `scrape_configs: []` with this — the port is wrong on purpose:

```yaml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9099"]
```

```bash
make apply
```

Open the Targets page (`make apply` prints its URL). One target, red, `connection refused`.

**Worth a pause.** The config is valid, Prometheus started fine, `promtool` was happy. The only thing telling you otherwise is this page, which is where to look first whenever a target's data is missing.

---

## Now do it right

Change `9099` to `9090`, then `make apply`. The target goes green.

```promql
up
```

`1`. But `up` is not a metric the target produced — Prometheus **synthesises** it after every scrape. No target's `/metrics` ever contains `up`, which is exactly why it works for targets too broken to report anything about themselves.

For about five minutes you will also see `up{instance="localhost:9099"}` at `0`: the broken target's last recorded scrape, before your fix. It drops out on its own.

Something the target really did produce:

```promql
prometheus_tsdb_head_series
```

Distinct series in memory. **Note roughly what it says**: chapter 06 comes back to it, after five chapters of targets have added to it.

And the raw text Prometheus parses:

```bash
curl -s http://localhost:9090/metrics | head -30
```

One line per series, `name{label="value"} number`. That format is the interface between Prometheus and everything it monitors, and no SDK is required: anything that serves it over HTTP with a `text/plain` (or OpenMetrics) `Content-Type` can be scraped. Prometheus 3 rejects a response with no `Content-Type` unless the job sets `fallback_scrape_protocol`.

---

## Grade it

```bash
make test
```

Chapter 01's checks: the job exists, the target is up, samples are landing. The third matters: a config can parse and a target can be listed without a single sample ever being stored.

## In the field

- **In superdemo:** its Prometheus config lives inside `utils/prometheus-grafana/grafana.yaml`, in the `prom-config` ConfigMap, and its Targets page is on port 9090, as here. When a demo shows no data, that page is the first place to look.
- **What customers ask:** "Do we need an agent on every app?" Not for Prometheus: the app serves `/metrics` and Prometheus fetches it. Most customers already run Prometheus somewhere, so ask how many servers they run, what they scrape, and how long they keep data.
- **Tailor it:** anything that serves this text format can be a target: an app's client library, an exporter, a collector. `up` works the same for all of them, which makes it a good first alert.

## What you now know

| | |
|---|---|
| **Prometheus server** | pulls over HTTP on a timer, stores locally |
| **Target** | one address that serves `/metrics` |
| **Job** | a named group of targets |
| **`up`** | synthesised per scrape; the first health signal to check |
| **Targets page** | where you find out what is actually broken |

Next: send it to Elastic, so the data outlives this cluster and you can query it in Kibana.
