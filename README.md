# Prometheus 101

A hands-on Prometheus workshop, and an on-ramp to [**superdemo**](https://github.com/ty-elastic/superdemo).

superdemo shows what Prometheus metrics in Elastic can do. This workshop builds the same pieces by hand, one chapter at a time, so you understand each one well enough to explain it to a customer, answer the technical follow-up questions, and change the setup to fit their environment.

You start with a Prometheus config that does nothing:

```yaml
scrape_configs: []
```

Seven chapters later you have superdemo's trading app, its Redis exporter, kube-state-metrics and an EDOT collector, all discovered automatically. Their metrics reach Elastic Serverless through remote write, filtered at the scrape and at remote write, and Grafana and Kibana run the same PromQL against Elastic.

The app and its layout come from superdemo: its `router` service, namespaces, ports, `build.sh` idiom, remote write endpoint and data stream. So when you open superdemo afterwards, its Prometheus setup will look familiar.

**About 60 minutes as a group**, with setup done beforehand. Alone it takes an estimated 40–45 minutes; the machine's part of that (applies, waits for data, grading) measured under 5 minutes. Every chapter is a short list of steps done right the first time. What can go wrong, and the deeper detail, sit in collapsed **Note ·** blocks under the step they belong to, for when you want them. Each chapter also has a walkthrough video.

---

## Why this workshop

Most of your Kubernetes customers already run Prometheus. It is the default for Kubernetes metrics: an open format, hundreds of exporters, and a query language, PromQL, that their engineers already know. What they struggle with is everything around it: keeping data longer than one server's disk allows, seeing across clusters, putting metrics next to logs and traces, and controlling what it all costs.

Elastic answers those without asking them to give anything up. Prometheus keeps scraping, remote write adds Elastic as a destination, and the same PromQL runs in Kibana and in their existing Grafana. Each chapter ends with one sentence to say to a customer. [`docs/FIELD-GUIDE.md`](docs/FIELD-GUIDE.md) has the rest: questions to ask, objections and honest answers, and a five-minute demo.

---

## Before the session

Do this beforehand. It takes 10–15 minutes, most of it downloading images, and the session starts at chapter 01.

You need macOS or Linux, `docker`, `k3d`, `kubectl`, `jq`, `curl`, `git`, `make`, `helm`, about 3 GB of RAM for the cluster, and **your own Elastic Serverless project**. Everyone writes to their own project, so the grader only sees your data.

```bash
brew install k3d kubectl jq          # macOS; Docker Desktop for docker
brew install helm                    # chapter 04 installs kube-state-metrics with it
```

Clone this repo, and superdemo next to it (chapter 07 imports superdemo's saved search):

```bash
git clone https://github.com/ericmustin/prometheus-101-elastic
git clone https://github.com/ty-elastic/superdemo
cd prometheus-101-elastic
```

```bash
cp .env.example .env
$EDITOR .env                         # ELASTIC_PROM_RW_ENDPOINT, ELASTIC_API_KEY, KIBANA_URL

make check                           # is this machine ready? prints your URLs
make setup                           # cluster, app, Prometheus, images (a few minutes)
```

**You're ready when** `make setup` ends with every line of its readiness summary green and you can log in to Kibana. `make status` shows the same summary again at any time.

> `make check` prints the URLs you will actually use. The chapters are written with superdemo's port numbers — 9090 Prometheus, 9000/9001 the routers, 9012 Grafana — but if any of those were taken when you ran `make setup`, all four shifted by +20000. `make check` warns you when that has happened.

---

## Where you start

`make setup` builds superdemo's trading app the way you would find it on your first day: a `router` in each of two regions with a traffic generator hitting it, Redis with its exporter, and a Prometheus and a Grafana in `infra`.

![Where you start: superdemo's trading app is running in a k3d cluster, with a router in two regions, Redis, Grafana and a Prometheus whose scrape list is empty. Nothing is collecting its metrics yet, and Elastic holds none of your data.](docs/images/topology-00.png)

```bash
kubectl get pods -A | grep -v kube-system
curl -s http://localhost:9000/metrics | grep '^shares_traded'
```

Everything is producing metrics, and nothing is collecting them: Prometheus runs with `scrape_configs: []`, and your Elastic project holds none of your data. Each chapter closes part of that gap with superdemo's own names, ports and files.

---

## The loop

Every chapter follows the same steps.

```bash
make chapter 3                       # start chapter 3: its starting config
$EDITOR prometheus/prometheus.yml    # make the change the chapter shows
make apply                           # validate, push to the cluster, restart Prometheus
make test                            # grade it
```

Each chapter opens with **Steps at a glance** and closes with **The whole change**: every edit and command it asked for, in one place.

If you fall behind, or something breaks, one command puts you at the start of any chapter with your cluster caught up:

```bash
make catchup 4                       # chapter 4's starting config, plus everything chapters 1-3 deployed
```

Stuck on an edit:

```bash
make hint                            # what is still different from the solution
make answer                          # the exact change this chapter wants
make status                          # which chapter am I on, and is the cluster ready?
```

`make goals` lists a chapter's checks without waiting, and `make` on its own lists everything.

### How it works

`solutions/NN/` holds the state you **start** chapter NN in, which is the same thing as the solution to chapter NN-1. `make chapter N` copies it into place, and `make answer` diffs `solutions/N` against `solutions/N+1`. Your current chapter is a number in `.chapter`, which is gitignored.

There are seven chapters and eight solution directories: `solutions/08` is the finished pipeline, so that chapter 07 has something to be compared against.

There are no branches. Editing `prometheus/prometheus.yml` and running `make chapter N` are the only two things that change your working tree, and `make chapter` saves your previous config into `.tmp/` before overwriting it.

---

## The seven chapters

| | Chapter | You learn | You add | Time |
|---|---|---|---|---|
| 01 | Scrape yourself | targets, jobs, `up` | a `prometheus` job | 5 min |
| 02 | Get it into Elastic | remote write, `external_labels`, PromQL in Kibana | `external_labels` and `remote_write` | 8 min |
| 03 | Scrape the trading app | Kubernetes discovery, relabeling, RED queries | RBAC, router annotations, a `kubernetes-pods` job | 12 min |
| 04 | Scrape the platform | exporters, kube-state-metrics | `make ksm` and a `kube-state-metrics` job | 7 min |
| 05 | Scrape the collector | a collector's own metrics, found by discovery | `make collector`, no config | 5 min |
| 06 | Choose what to send | filtering at the scrape and at remote write | an allow list and a drop list | 7 min |
| 07 | Grafana → Elastic | Elastic as a Prometheus datasource, PromQL dashboards in Kibana | `make grafana` and `make import` | 7 min |

With a 4-minute welcome and a 5-minute wrap-up, that is 60 minutes. [`docs/FACILITATOR.md`](docs/FACILITATOR.md) has the run of show for leading it as a group.

You mostly edit `prometheus/prometheus.yml`. Chapter 03 also edits `k8s/router.yaml`, and chapters 05 and 07 change no file at all.

---

## Looking at the data

From chapter 02 onward you query in **Kibana**: Discover, in ES|QL mode. PromQL runs there through the `PROMQL` command, so the queries are the ones a Prometheus user already writes:

```esql
PROMQL index=metrics-generic.prometheus-default step=1m
  sum by (region) (rate(http_requests_total[5m]))
```

`step=1m` draws a line over the date picker's range, like Prometheus's Graph tab; `time=?_tend` gives one answer at its end, like the Table tab. The Prometheus expression browser stays for chapter 01, and for questions about Prometheus itself.

```bash
make links                                               # this chapter's queries, each with a link that opens it in Discover
make esql Q=queries/esql/03-requests-by-region.esql      # or run one here and print a table
```

`queries/esql/*.esql` contain `${DATA_STREAM}`, which Kibana does not expand, so paste from the chapter or from `make links`, not from the files. `make links` needs `KIBANA_URL` in `.env`, and `make links ALL=1` prints every chapter's.

---

## What you built

Seven chapters, one pipeline. Each chapter started with `make chapter N` and ended with `make test`, and the rest was this:

| | You edited | You ran |
|---|---|---|
| 01 | a `prometheus` job | `make apply` |
| 02 | `external_labels`, `remote_write` | `make apply` |
| 03 | router annotations, a `kubernetes-pods` job | `kubectl apply -f utils/prometheus-grafana/rbac.yml`, `./build.sh -s router`, `make apply` |
| 04 | a `kube-state-metrics` job | `make ksm`, `make apply` |
| 05 | nothing | `make collector` |
| 06 | an allow list, a drop list | `make apply` |
| 07 | nothing | `make grafana`, `make import` |

The finished `prometheus/prometheus.yml` is `solutions/08/prometheus.yml`. Read top to bottom, it is five blocks.

### Label the cluster

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: prometheus-101
    env: lab
```

Every series leaves this Prometheus labelled with the cluster it came from, which is how one Elastic project tells many clusters apart. (Chapter 02.)

### Scrape Prometheus itself

```yaml
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
```

One named target. Prometheus pulls `/metrics` from it every 15 seconds and writes `up` for every scrape. (Chapter 01.)

### Discover every workload that asks

```yaml
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: ["trading-na", "trading-emea", "infra"]

    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__

      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)

      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_service]
        target_label: service
      - source_labels: [__meta_kubernetes_pod_node_name]
        target_label: node
```

Any pod annotated `prometheus.io/scrape: "true"` is scraped on the port it names, and labelled with its namespace, pod, service and node. This one job found the routers and Redis in chapter 03, and the collector in chapter 05, with no further config.

### Name the exporter that discovery can't find

```yaml
  - job_name: kube-state-metrics
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: ["kube-system"]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        action: keep
        regex: kube-state-metrics

      - source_labels: [__meta_kubernetes_pod_container_port_name]
        action: keep
        regex: http

    metric_relabel_configs:
      - source_labels: [__name__]
        action: keep
        regex: kube_(pod_status_phase|pod_container_status_restarts_total|deployment_status_replicas.*|node_status_condition|namespace_created|daemonset_status_number_ready)
```

Cluster state, found by its pod label because its chart annotates the Service, scraped on its `http` port, and trimmed at the scrape to the families the dashboards use. (Chapters 04 and 06.)

### Send it all to Elastic, minus the debug detail

```yaml
remote_write:
  - name: elastic
    url: "${ELASTIC_PROM_RW_ENDPOINT}"
    authorization:
      type: ApiKey
      credentials_file: /etc/elastic/api-key
    queue_config:
      capacity: 2500
      max_shards: 4
      min_shards: 1
      max_samples_per_send: 500
      batch_send_deadline: 5s
    write_relabel_configs:
      - action: drop
        source_labels: [__name__]
        regex: nodejs_.*|process_.*

      - action: drop
        source_labels: [__name__]
        regex: go_.*|promhttp_.*
```

Every sample streams to Elasticsearch's remote write endpoint, authenticated with a key read from a Secret, except the runtime internals, which stay in Prometheus for live debugging. Grafana and Kibana then read it all back with PromQL. (Chapters 02, 06 and 07.)

**The story in one breath:** keep your Prometheus; let workloads declare what to scrape; send it to Elastic with one block of config; choose what to keep where; and run the same PromQL in Grafana and Kibana, over as much history as you keep. When you open superdemo next, [`docs/SUPERDEMO-MAP.md`](docs/SUPERDEMO-MAP.md) shows where each of these pieces lives there.

---

## Layout

```
prometheus/prometheus.yml   the file you edit
chapters/                   the course, one markdown file per chapter
solutions/NN/               each chapter's starting state
queries/esql/               the Kibana queries (ES|QL and PROMQL), by chapter
src/router/                 superdemo's router, vendored unmodified
k8s/                        envsubst templates: router, recorder, monkey
utils/                      redis, kube-state-metrics, prometheus + grafana
agents/apm/                 the EDOT collector
build.sh                    superdemo's deploy idiom; make wraps it
scripts/                    setup, apply, chapter switching, assertions
test/                       the grader
docs/FACILITATOR.md         running the workshop for a group, in an hour
docs/FIELD-GUIDE.md         what to say, ask and demo: the course's field material in one place
docs/SUPERDEMO-MAP.md       what you built, and where it is in superdemo
docs/images/                the cluster maps the chapters use, and video stills
```

---

## Troubleshooting

**`make apply` says promtool rejected the config** — the error names the line. Nothing was applied; your cluster is still on the previous config.

**`make apply` says promtool could not run** — that is Docker, not your YAML. Check `docker run --rm hello-world`.

**Prometheus is not where the chapter says** — your ports were shifted. `make check` prints the real ones.

**Pods will not start** — `kubectl get pods -A`. Workloads live in `trading-na`, `trading-emea` and `infra`.

**Chapter 02 says nothing is arriving** — `make test` names the failing check and diagnoses the failure mode. Chapter 02's note "If nothing arrives" explains the two ways remote write fails.

**Behind, or not sure what state you're in** — `make catchup N` for the chapter the group is on.

**Start over** — `make clean && make setup`.

---

## Credits

The trading app and much of the deployment come from [superdemo](https://github.com/ty-elastic/superdemo). `src/router/`, `utils/redis/redis.yml`, `utils/ksm/ksm.sh` and `assets/scripts/retry.sh` are copied from it unmodified, and `build.sh`, `k8s/router.yaml` and `utils/prometheus-grafana/grafana.yaml` are adapted from it. See `NOTICE`.

The idea of a free, self-paced, hands-on Prometheus workshop comes from Eric D. Schabell's [Getting started with Prometheus](https://gitlab.com/o11y-workshops/workshop-prometheus) workshop from [o11y-workshops](https://gitlab.com/o11y-workshops). If you want Prometheus on its own, without Elastic, start there.

## License

[Apache License 2.0](LICENSE).
