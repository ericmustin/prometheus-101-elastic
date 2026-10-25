#!/usr/bin/env bash
# Build the whole lab environment. Idempotent - safe to re-run.
#
#   1. sanity-check the machine
#   2. find (or ask for) the Elasticsearch URL that answers _query
#   3. create the k3d cluster
#   4. build the router image and import it into the cluster
#   5. deploy the trading app, Redis, Prometheus and Grafana (via build.sh)
#   6. Gate 0.5 - prove the router really is exposing the metrics this
#      course is about to spend seven chapters teaching you to collect
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

# ---------------------------------------------------------------- 1. machine
"${ROOT_DIR}/scripts/check-env.sh" >/dev/null || die "Gate 0 failed. Run scripts/check-env.sh to see why."
log_ok "Gate 0 passed."

# --------------------------------------------------- 2. probe for ELASTIC_ES_URL
# The remote write endpoint and the query endpoint are not guaranteed to be the
# same host, so we do not assume. We try the plausible candidates in order and
# keep the first one that actually answers POST /_query with our key.
probe_es_url() {
  local candidate="${1:-}"
  [[ -n "${candidate}" ]] || return 1
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "Authorization: ApiKey ${ELASTIC_API_KEY}" \
    -H 'Content-Type: application/json' \
    -X POST "${candidate%/}/_query?format=json" \
    -d '{"query":"ROW probe = 1"}' 2>/dev/null || true)"
  [[ "${code}" == "200" ]]
}

record_es_url() {
  export ELASTIC_ES_URL="$1"
  if [[ -f "${ROOT_DIR}/.env" ]] && ! grep -q '^ELASTIC_ES_URL=' "${ROOT_DIR}/.env"; then
    printf '\n# Discovered by scripts/setup.sh\nELASTIC_ES_URL=%s\n' "$1" >> "${ROOT_DIR}/.env"
    log_ok "Wrote ELASTIC_ES_URL to .env"
  fi
}

if [[ -n "${ELASTIC_API_KEY:-}" ]]; then
  log_step "Locating the Elasticsearch query endpoint"
  if [[ -n "${ELASTIC_ES_URL:-}" ]] && probe_es_url "${ELASTIC_ES_URL}"; then
    log_ok "ELASTIC_ES_URL from your environment answers _query."
  else
    found=""
    for candidate in \
      "$(es_url_from_rw_endpoint "${ELASTIC_PROM_RW_ENDPOINT:-}" 2>/dev/null || true)" \
      "$(printf '%s' "${ELASTIC_PROM_RW_ENDPOINT:-}" | sed -e 's|/_prometheus/.*||' -e 's|\.ingest\.|.es.|')" \
      "$(printf '%s' "${KIBANA_URL:-}" | sed -e 's|\.kb\.|.es.|')" ; do
      [[ -n "${candidate}" ]] || continue
      log_info "trying ${candidate}"
      if probe_es_url "${candidate}"; then
        found="${candidate}"
        break
      fi
    done

    if [[ -n "${found}" ]]; then
      log_ok "Found it: ${found}"
      record_es_url "${found}"
    else
      log_warn "No candidate host answered POST /_query with your API key."
      log_hint "Chapter 01 works without it. Chapter 02 onward does not."
      printf 'Enter your Elasticsearch URL (or press enter to skip): '
      read -r manual
      if [[ -n "${manual}" ]]; then
        if probe_es_url "${manual}"; then
          log_ok "That works."
          record_es_url "${manual}"
        else
          log_warn "That host did not answer either. Continuing without it."
        fi
      fi
    fi
  fi
  [[ -n "${DATA_STREAM}" ]] && log_ok "Remote write should land in: ${DATA_STREAM}"
fi

# ------------------------------------------------------------------ 3. ports
# Only pick ports if the cluster does not exist yet - once created the
# mappings are baked in, and re-picking would silently disagree with reality.
if ! grep -q "^${CLUSTER_NAME} " <<<"$(k3d cluster list 2>/dev/null)"; then
  if port_in_use "${PROM_HOST_PORT}" || port_in_use "${ROUTER_NA_HOST_PORT}" \
     || port_in_use "${ROUTER_EMEA_HOST_PORT}" || port_in_use "${GRAFANA_HOST_PORT}"; then
    log_step "Port conflict"
    for p in "${PROM_HOST_PORT}" "${ROUTER_NA_HOST_PORT}" "${ROUTER_EMEA_HOST_PORT}" "${GRAFANA_HOST_PORT}"; do
      port_in_use "${p}" && log_warn "Port ${p} is already in use on this machine."
    done
    # Shift all of them together - one rule to remember beats four exceptions.
    # Note this loses the deliberate match with superdemo's Traefik ports; the
    # course still works, it is just no longer the same numbers.
    PROM_HOST_PORT=$(( PROM_HOST_PORT + 20000 ))
    ROUTER_NA_HOST_PORT=$(( ROUTER_NA_HOST_PORT + 20000 ))
    ROUTER_EMEA_HOST_PORT=$(( ROUTER_EMEA_HOST_PORT + 20000 ))
    GRAFANA_HOST_PORT=$(( GRAFANA_HOST_PORT + 20000 ))
    for p in "${PROM_HOST_PORT}" "${ROUTER_NA_HOST_PORT}" "${ROUTER_EMEA_HOST_PORT}" "${GRAFANA_HOST_PORT}"; do
      port_in_use "${p}" && die "Fallback port ${p} is also in use. Set the *_HOST_PORT vars in .env by hand."
    done
    PROM_URL="http://localhost:${PROM_HOST_PORT}"
    ROUTER_NA_URL="http://localhost:${ROUTER_NA_HOST_PORT}"
    ROUTER_EMEA_URL="http://localhost:${ROUTER_EMEA_HOST_PORT}"
    GRAFANA_URL="http://localhost:${GRAFANA_HOST_PORT}"
    export PROM_HOST_PORT ROUTER_NA_HOST_PORT ROUTER_EMEA_HOST_PORT GRAFANA_HOST_PORT
    export PROM_URL ROUTER_NA_URL ROUTER_EMEA_URL GRAFANA_URL
    if [[ -f "${ROOT_DIR}/.env" ]] && ! grep -q '^PROM_HOST_PORT=' "${ROOT_DIR}/.env"; then
      {
        printf '\n# Chosen by scripts/setup.sh because the defaults were taken.\n'
        printf 'PROM_HOST_PORT=%s\n'         "${PROM_HOST_PORT}"
        printf 'ROUTER_NA_HOST_PORT=%s\n'    "${ROUTER_NA_HOST_PORT}"
        printf 'ROUTER_EMEA_HOST_PORT=%s\n'  "${ROUTER_EMEA_HOST_PORT}"
        printf 'GRAFANA_HOST_PORT=%s\n'      "${GRAFANA_HOST_PORT}"
      } >> "${ROOT_DIR}/.env"
    fi
    log_ok "Using ${PROM_HOST_PORT} prometheus, ${ROUTER_NA_HOST_PORT}/${ROUTER_EMEA_HOST_PORT} routers, ${GRAFANA_HOST_PORT} grafana."
  fi
fi

# ---------------------------------------------------------------- 4. cluster
log_step "Cluster"
if grep -q "^${CLUSTER_NAME} " <<<"$(k3d cluster list 2>/dev/null)"; then
  log_ok "k3d cluster '${CLUSTER_NAME}' already exists."
  k3d cluster start "${CLUSTER_NAME}" >/dev/null 2>&1 || true
else
  log_info "Creating k3d cluster '${CLUSTER_NAME}' (this takes about a minute)."
  sed -e "s|\${PROM_HOST_PORT}|${PROM_HOST_PORT}|g" \
      -e "s|\${ROUTER_NA_HOST_PORT}|${ROUTER_NA_HOST_PORT}|g" \
      -e "s|\${ROUTER_EMEA_HOST_PORT}|${ROUTER_EMEA_HOST_PORT}|g" \
      -e "s|\${GRAFANA_HOST_PORT}|${GRAFANA_HOST_PORT}|g" \
      "${ROOT_DIR}/k8s/k3d/cluster.yml" > "${TMP_DIR}/cluster.yml"
  k3d cluster create --config "${TMP_DIR}/cluster.yml"
  log_ok "Cluster created."
fi

kubectl config use-context "k3d-${CLUSTER_NAME}" >/dev/null
kubectl cluster-info >/dev/null || die "Cannot reach the cluster."
log_ok "kubectl is pointed at k3d-${CLUSTER_NAME}."

# ------------------------------------------------- 5. workloads, via build.sh
# From here on setup.sh delegates. build.sh is the file that mirrors
# superdemo's deploy idiom, and it is the one a learner should read.
log_step "Deploying (build.sh)"
"${ROOT_DIR}/build.sh" -K true -b true -1 true -s all -g true

# ---------------------------------------------------------------- 6. gates
log_step "Gate 0.5: the router is exposing what the course expects"
deadline=$(( $(date +%s) + 180 ))
metrics=""
while :; do
  metrics="$(curl -sS --max-time 5 "${ROUTER_NA_URL}/metrics" 2>/dev/null || true)"
  [[ -n "${metrics}" ]] && break
  [[ "$(date +%s)" -ge "${deadline}" ]] && die "No response from ${ROUTER_NA_URL}/metrics after 180s."
  sleep 5
done

# These are superdemo's real metric names, from src/router/app.ts. If
# prom-client or the middleware ever renames one, fail here with the name
# rather than three chapters later with a mystery.
missing=0
for want in transactions shares_traded http_requests_total \
            http_request_duration_seconds_bucket nodejs_heap_size_total_bytes; do
  if grep -q "^${want}" <<<"${metrics}"; then
    log_ok "${want} is exposed."
  else
    log_fail "${want} is NOT exposed on ${ROUTER_NA_URL}/metrics."
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || { log_hint "curl -s ${ROUTER_NA_URL}/metrics | grep -E '^(transactions|shares)'"; exit 1; }

echo
log_ok "Environment is ready."
echo
log_info "Prometheus     : ${PROM_URL}"
log_info "router (na)    : ${ROUTER_NA_URL}/metrics"
log_info "router (emea)  : ${ROUTER_EMEA_URL}/metrics"
log_info "Grafana        : ${GRAFANA_URL}"
log_info "data stream    : ${DATA_STREAM}"
echo
log_info "Next: open chapters/01-scrape-yourself.md and edit prometheus/prometheus.yml"
