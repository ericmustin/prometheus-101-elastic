# Chapter 06 — Decide what you pay for

**Goal:** drop what you do not want, and understand that *where* you drop it is a separate decision from *whether*.

---

## The idea

You now forward everything you collect to a system that charges for what it stores. You are scraping five targets, and one of them is kube-state-metrics.

Start with the number chapter 01 asked you to remember:

```promql
prometheus_tsdb_head_series
```

Everything you have added since is in it. Now see who added the most:

```promql
topk(5, count by (job) (last_over_time({__name__=~".+"}[1m])))
```

kube-state-metrics dominates, and it is the one component with nothing to do with your application.

## Two mechanisms

| | `metric_relabel_configs` | `write_relabel_configs` |
|---|---|---|
| Sits under | the scrape job | the `remote_write` block |
| Runs | after the scrape, before local storage | before shipping |
| Local Prometheus | data is **gone** | data is **kept** |
| Elastic | never arrives | never arrives |
| Saves | local memory **and** ingest | ingest only |

The question that picks between them: **would you want this at 3am?** If yes, drop at the write boundary — keep it locally where it is cheap, stop paying to retain it for thirty days. If no, drop at the scrape and save the memory too.

---

## Case one: an allow list, at the scrape

kube-state-metrics is the "no" case: ~1,300 series of cluster bookkeeping, and you will not debug a trade with `kube_pod_tolerations`. Because it has a job to itself you can use an **allow list**, which is safe here precisely because the job holds one kind of target:

```yaml
    metric_relabel_configs:
      - source_labels: [__name__]
        action: keep
        regex: kube_(pod_status_phase|pod_container_status_restarts_total|deployment_status_replicas.*|node_status_condition|namespace_created|daemonset_status_number_ready)
```

```bash
make apply
```

```promql
count(last_over_time({__name__=~"kube_.*"}[1m]))
```

Give it a minute: the `[1m]` window still holds the last scrape before your change. Then **186**, down from about **1,300** — nine metric families instead of more than 90, and every chapter 04 query still works.

Note which number is stable: 186 is set by your allow list and stays put as the cluster grows; the 1,300 is set by the cluster and does not.

**This is why chapter 04 gave it its own job.** `metric_relabel_configs` applies to every target in a job, so this allow list in the shared job would have deleted the trading app too. **"I cannot express this rule" usually means "these targets belong in different jobs."**

---

## Case two: a drop list, at the boundary

The router is the "yes" case. `prom-client` ships Node's runtime internals with every scrape — heap, GC, event loop. Useful when the router is misbehaving *right now*; rarely worth thirty days in someone else's storage.

```yaml
    write_relabel_configs:
      - action: drop
        source_labels: [__name__]
        regex: nodejs_.*|process_.*

      - action: drop
        source_labels: [__name__]
        regex: go_.*|promhttp_.*
```

A **drop list**, not an allow list, deliberately: RE2 has no negative lookahead, so "everything except" cannot be expressed — and a drop list fails safe, because a new family shows up rather than silently vanishing.

---

## The proof

The clearest demonstration in the course of what "where" means — two windows, one screen.

**Still in Prometheus:**

```promql
nodejs_heap_size_total_bytes
```

**Gone from Elastic:**

```bash
make test
```

Same rule, two answers.

Two things that trip people up:

- **Dropping is not deleting.** What already landed still counts against storage. A drop rule stops the bleeding; it does not heal the wound.
- **Do not get greedy.** `.*_total` would take `http_requests_total` with it, and remote write would report complete success throughout. The test checks the application's metrics are *still* arriving.

---

## The anchoring trap

Prometheus wraps every relabel regex as `^(?:...)$`. So this:

```yaml
        regex: nodejs_heap
```

matches nothing, because the metric is `nodejs_heap_size_total_bytes`. Valid config, happy `promtool`, no log line, and the rule matches zero things forever — the same shape as chapter 03's backreference. **A rule that matches nothing is indistinguishable from a rule that is not there.**

---

## What you now know

| | |
|---|---|
| **`metric_relabel_configs`** | drop at scrape: cheaper, gone everywhere |
| **`write_relabel_configs`** | drop at the boundary: keep locally, stop paying |
| **Allow lists need a homogeneous job** | which is why chapter 04 split one out |
| **Drop lists fail safe** | new families appear rather than vanish |
| **Anchored regexes** | `nodejs_heap` never matches `nodejs_heap_size_total_bytes` |
| **Dropping ≠ deleting** | already-ingested data stays and still costs |

Next: Grafana.
