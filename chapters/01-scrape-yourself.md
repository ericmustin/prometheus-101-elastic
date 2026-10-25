# Chapter 01 — Scrape yourself

**Goal:** get one target, any target, and understand what a "target" is.

---

## The idea

Prometheus does not receive metrics. It goes and gets them.

No agent, no queue, no push. There is a list of HTTP addresses in a config file, and every 15 seconds Prometheus walks it, does a `GET /metrics` on each, and stores whatever comes back. Everything else in this course is elaboration on that loop.

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

**Worth a pause.** The config is valid, Prometheus started fine, `promtool` was happy. The only thing telling you otherwise is this page — which, in a cluster with two hundred targets, is where you will spend your time.

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

Distinct series in memory. **Remember roughly what it says** — chapter 06 comes back to it, and the number will have grown in a way you will not like.

And the raw text Prometheus parses:

```bash
curl -s http://localhost:9090/metrics | head -30
```

One line per series, `name{label="value"} number`. That format is the entire interface between Prometheus and everything it monitors — no SDK, no protocol negotiation. Anything that can serve that text over HTTP can be scraped.

---

## Grade it

```bash
make test
```

Three checks: the job exists, the target is up, samples are landing. The third matters — a config can parse and a target can be listed without a single sample ever being stored.

## What you now know

| | |
|---|---|
| **Prometheus server** | pulls over HTTP on a timer, stores locally |
| **Target** | one address that serves `/metrics` |
| **Job** | a named group of targets |
| **`up`** | synthesised per scrape; the universal health signal |
| **Targets page** | where you find out what is actually broken |

Next: get it out of the cluster, so Kibana rather than this browser is where you spend the rest of the course.
