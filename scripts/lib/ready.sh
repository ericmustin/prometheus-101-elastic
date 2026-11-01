#!/usr/bin/env bash
# The image pre-pull, what later chapters leave in the cluster, and the
# "Ready for the session" checklist. Sourced, never executed, after env.sh.
#
#   prepull_images         build.sh -K (make setup): cache images on every node
#   readiness_checklist    the end of make setup, and of make status
#   has_rbac, has_ksm...   is a later chapter's work already in the cluster?

# shellcheck source=../../test/lib/elastic.sh
source "${ROOT_DIR}/test/lib/elastic.sh"

# Every kubectl call here names the course cluster, so a checklist run while
# kubectl points somewhere else still reports on the right cluster.
kc() { kubectl --context "k3d-${CLUSTER_NAME}" "$@"; }

# --------------------------------------------------------------- images

# The cluster's node containers (the server and the agent, not the load
# balancer), one per line.
cluster_nodes() {
  docker ps --filter "label=k3d.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}} {{.Label "k3d.role"}}' 2>/dev/null \
    | awk '$2 == "server" || $2 == "agent" { print $1 }' | sort
}

# The image ksm.sh's chart installs: the chart's appVersion, as a v-tag.
# Reads helm's local repo cache, so run `helm repo update` first if it matters.
ksm_image() {
  command -v helm >/dev/null 2>&1 || return 1
  local v
  v="$(helm show chart prometheus-community/kube-state-metrics 2>/dev/null \
       | awk '/^appVersion:/ { gsub(/"/, "", $2); print $2 }')"
  [[ -n "${v}" ]] || return 1
  printf 'registry.k8s.io/kube-state-metrics/kube-state-metrics:v%s\n' "${v#v}"
}

# The images a chapter starts after setup, one per line, read from the files
# that deploy them so the two cannot drift:
#   - the EDOT collector (chapter 05, make collector)
#   - Grafana: chapter 07's make grafana restarts it, and with no volume to pin
#     it the new pod usually lands on the node that has never pulled it
#   - kube-state-metrics (chapter 04, make ksm), when helm can say which image
course_images() {
  awk '/^[[:space:]]*image:/ { print $2; exit }' "${ROOT_DIR}/agents/apm/local.yaml"
  awk '/^[[:space:]]*image:[[:space:]]*grafana\// { print $2; exit }' \
    "${ROOT_DIR}/utils/prometheus-grafana/grafana.yaml"
  ksm_image || true
}

image_cached() { docker exec "$1" crictl inspecti "$2" >/dev/null 2>&1; }

# Pull every course image into every node's image store. Pulled, never
# deployed: nothing starts, so no chapter's work is done ahead of it.
#
# `crictl pull` inside each node, not `k3d image import`: on Docker's
# containerd image store the import lands nothing, and kubelet would then pull
# 450 MB of collector in the middle of chapter 05.
prepull_images() {
  local nodes; nodes="$(cluster_nodes)"
  if [[ -z "${nodes}" ]]; then
    log_warn "No nodes found for k3d cluster '${CLUSTER_NAME}', so nothing was pre-pulled."
    return 0
  fi

  if command -v helm >/dev/null 2>&1; then
    # The same two commands ksm.sh runs, so this resolves the chart it installs.
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update prometheus-community >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 \
      || log_warn "helm repo update failed; using the chart version helm already knows."
    ksm_image >/dev/null || log_warn "Could not read kube-state-metrics' chart, so its image is not pre-pulled."
  else
    log_warn "helm is not installed, so the kube-state-metrics image is not pre-pulled (chapter 04 needs helm)."
  fi

  local images=() img node
  while IFS= read -r img; do [[ -n "${img}" ]] && images+=("${img}"); done < <(course_images)

  # One background pull per node and image. Already-cached images are skipped,
  # so re-running setup does not need the network for them.
  local log="${TMP_DIR}/prepull.log" total
  total="$(wc -w <<<"${nodes}" | tr -d ' ')"
  local where="all ${total} nodes"; [[ "${total}" -eq 2 ]] && where="both nodes"
  : > "${log}"
  log_info "pulling ${#images[@]} images onto ${total} nodes: ${images[*]##*/}"
  for node in ${nodes}; do
    for img in "${images[@]}"; do
      { image_cached "${node}" "${img}" || docker exec "${node}" crictl pull "${img}"; } >>"${log}" 2>&1 &
    done
  done
  wait

  local missing
  for img in "${images[@]}"; do
    missing=""
    for node in ${nodes}; do image_cached "${node}" "${img}" || missing="${missing} ${node}"; done
    if [[ -z "${missing}" ]]; then
      log_ok "${img##*/} is cached on ${where}."
    else
      log_warn "${img##*/} did not land on:${missing} (see .tmp/prepull.log)."
    fi
  done
}

# ------------------------------------------- what later chapters leave behind
# Each answers yes (0) or no (1). Used by `make catchup` to undo work from a
# chapter after the one you are catching up to, and by the checklist below.

has_rbac() {                       # chapter 03: kubectl apply -f rbac.yml
  kc get clusterrolebinding prometheus-101 >/dev/null 2>&1
}

has_router_annotation() {          # chapter 03: the scrape annotation
  local ns v
  for ns in $(namespaces_from_region); do
    v="$(kc -n "${ns}" get deploy router \
         -o jsonpath='{.spec.template.metadata.annotations.prometheus\.io/scrape}' 2>/dev/null || true)"
    [[ -n "${v}" ]] && return 0
  done
  return 1
}

has_ksm() {                        # chapter 04: make ksm
  [[ -n "$(kc get deployments --all-namespaces -l app.kubernetes.io/name=kube-state-metrics \
           -o name 2>/dev/null || true)" ]]
}

has_collector() {                  # chapter 05: make collector
  kc -n "${PROM_NAMESPACE}" get deploy otel-collector >/dev/null 2>&1
}

has_grafana_elastic() {            # chapter 07: make grafana
  grep -q 'name: Elastic' <<<"$(kc -n "${PROM_NAMESPACE}" get configmap grafana-datasources \
                                -o jsonpath='{.data}' 2>/dev/null || true)"
}

# -------------------------------------------------------------- checklist

ready_ok()   { printf '  %s✓%s %s\n' "${C_OK}"   "${C_OFF}" "$*"; }
ready_warn() { printf '  %s!%s %s\n' "${C_WARN}" "${C_OFF}" "$*"; READY_WARNINGS=$(( READY_WARNINGS + 1 )); }

# readiness_checklist
# Is this machine ready for a session that starts at chapter 01? Prints one
# line per item, green ✓ or yellow !, and never fails the caller.
readiness_checklist() {
  READY_WARNINGS=0
  log_step "Ready for the session"

  local cluster_up=0
  if kc get --raw /readyz --request-timeout=5s >/dev/null 2>&1; then
    cluster_up=1
    ready_ok "k3d cluster '${CLUSTER_NAME}' is up."
  else
    ready_warn "k3d cluster '${CLUSTER_NAME}' is not answering. Run: make setup"
  fi

  if curl -sS --max-time 5 -o /dev/null "${PROM_URL}/-/ready" 2>/dev/null; then
    ready_ok "Prometheus answers at ${PROM_URL}."
  else
    ready_warn "Prometheus is not answering at ${PROM_URL}. Run: make setup"
  fi

  # Chapter 01's start: the committed prometheus.yml, and nothing a later
  # chapter adds already running (that would hand you its lesson for free).
  local chapter="" sol="${ROOT_DIR}/solutions/01/prometheus.yml"
  [[ -f "${ROOT_DIR}/.chapter" ]] && chapter="$(tr -dc '0-9' < "${ROOT_DIR}/.chapter")"
  [[ -n "${chapter}" ]] && chapter="$(printf '%02d' "$((10#${chapter}))")"
  if [[ -n "${chapter}" && "${chapter}" != "01" ]]; then
    ready_warn "On chapter ${chapter}, not at chapter 01's start (fine mid-session; before one: make catchup 1)."
  elif ! diff -q "${sol}" "${ROOT_DIR}/prometheus/prometheus.yml" >/dev/null 2>&1; then
    ready_warn "prometheus/prometheus.yml is not chapter 01's starting file. Run: make catchup 1"
  else
    local later=""
    if [[ "${cluster_up}" -eq 1 ]]; then
      has_rbac              && later="${later}, RBAC (03)"
      has_router_annotation && later="${later}, router annotation (03)"
      has_ksm               && later="${later}, kube-state-metrics (04)"
      has_collector         && later="${later}, collector (05)"
      has_grafana_elastic   && later="${later}, Grafana's Elastic datasource (07)"
    fi
    if [[ -n "${later}" ]]; then
      ready_warn "The cluster already has later chapters' work: ${later#, }. Run: make catchup 1"
    else
      ready_ok "Chapter 01's start: prometheus.yml as committed${chapter:+, .chapter = 01}, nothing from a later chapter running."
    fi
  fi

  local nodes; nodes="$(cluster_nodes)"
  if [[ -z "${nodes}" ]]; then
    ready_warn "No cluster nodes to check the image cache on. Run: make setup"
  else
    local total img node missing
    total="$(wc -w <<<"${nodes}" | tr -d ' ')"
    local where="all ${total} nodes"; [[ "${total}" -eq 2 ]] && where="both nodes"
    while IFS= read -r img; do
      [[ -n "${img}" ]] || continue
      missing=""
      for node in ${nodes}; do image_cached "${node}" "${img}" || missing="${missing} ${node#k3d-${CLUSTER_NAME}-}"; done
      if [[ -z "${missing}" ]]; then
        ready_ok "${img##*/} is cached on ${where}."
      else
        ready_warn "${img##*/} is not cached on:${missing}. Re-run: make setup"
      fi
    done < <(course_images)
    ksm_image >/dev/null \
      || ready_warn "Cannot tell which kube-state-metrics image chapter 04 installs (is helm installed?)."
  fi

  local objects="${SUPERDEMO_OBJECTS:-${ROOT_DIR}/../superdemo/assets/objects/metrics_esql.ndjson}"
  if [[ -f "${objects}" ]]; then
    ready_ok "superdemo is checked out next to this repo (chapter 07's make import needs it)."
  else
    ready_warn "superdemo is not at ../superdemo. Clone it there before chapter 07 (make import)."
  fi

  if ! es_available; then
    ready_warn "Elastic is not configured in .env (chapter 02 onward needs it). See: make check"
  elif [[ "$(esql_value 'ROW ok = 1' 2>/dev/null || true)" == "1" ]]; then
    ready_ok "Elasticsearch answers ES|QL at ${ELASTIC_ES_URL}."
  else
    ready_warn "Elasticsearch did not answer ES|QL at ${ELASTIC_ES_URL}. Check ELASTIC_API_KEY in .env."
  fi

  echo
  if [[ "${READY_WARNINGS}" -eq 0 ]]; then
    log_ok "Ready for the session."
  else
    log_warn "${READY_WARNINGS} thing(s) to sort out before the session: the ! lines above."
  fi
  return 0
}
