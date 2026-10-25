#!/usr/bin/env bash
# Environment loading and derivation. Sourced, never executed.
#
# Pure string math - this file never touches the network, so every script that
# sources it stays deterministic and fast. The one thing that IS guessed here
# (DATA_STREAM) is verified against the live cluster by scripts/setup.sh.

# ROOT_DIR is the repo root, regardless of who sourced us.
if [[ -z "${ROOT_DIR:-}" ]]; then
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
export ROOT_DIR

# shellcheck source=log.sh
source "${ROOT_DIR}/scripts/lib/log.sh"

# --- .env ---------------------------------------------------------------
# Load .env if present. Values already in the environment win, so
# `ELASTIC_API_KEY=xxx make test` overrides the file.
load_env_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      ''|'#'*) continue ;;
    esac
    [[ "${line}" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "${key}" | tr -d '[:space:]')"
    key="${key#export }"
    # Strip one layer of matching quotes.
    case "${value}" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    # Only set if not already exported.
    if [[ -z "$(eval "printf '%s' \"\${${key}:-}\"" 2>/dev/null)" ]]; then
      export "${key}=${value}"
    fi
  done < "${file}"
}

load_env_file "${ROOT_DIR}/.env"
load_env_file "${ROOT_DIR}/.env.local"

# --- Defaults -----------------------------------------------------------
# Names, namespaces and ports mirror superdemo so that what you learn here is
# what you see there. superdemo runs -r na,emea giving trading-na and
# trading-emea, with prometheus/grafana/redis in infra.
: "${CLUSTER_NAME:=prometheus-101}"
: "${COURSE:=o11y--course--field--prom-101--local}"
: "${REPO:=prom101}"
: "${REGION:=na,emea}"
: "${NAMESPACE_BASE:=trading}"
: "${PROM_NAMESPACE:=infra}"
: "${SERVICE_VERSION:=1.0}"
: "${PROM_IMAGE:=prom/prometheus:v3.7.3}"
: "${SECRET_NAME:=elastic-secret-otel}"

# Host ports. 9090/9464/8080 are the obvious defaults, but a laptop that
# already runs a Prometheus, or the OpenTelemetry demo, will be holding some
# of them. setup.sh detects that and shifts all three at once, then records
# the choice here in .env so every later script agrees.
: "${PROM_HOST_PORT:=9090}"
# 9000 / 9001 / 9012 are the ports superdemo exposes through Traefik
# (superdemo/utils/traefik/values.yaml). Matching them is free recognition.
: "${ROUTER_NA_HOST_PORT:=9000}"
: "${ROUTER_EMEA_HOST_PORT:=9001}"
: "${GRAFANA_HOST_PORT:=9012}"

: "${PROM_URL:=http://localhost:${PROM_HOST_PORT}}"
: "${ROUTER_NA_URL:=http://localhost:${ROUTER_NA_HOST_PORT}}"
: "${ROUTER_EMEA_URL:=http://localhost:${ROUTER_EMEA_HOST_PORT}}"
: "${GRAFANA_URL:=http://localhost:${GRAFANA_HOST_PORT}}"
export CLUSTER_NAME COURSE REPO REGION NAMESPACE_BASE PROM_NAMESPACE
export SERVICE_VERSION PROM_IMAGE SECRET_NAME
export PROM_HOST_PORT ROUTER_NA_HOST_PORT ROUTER_EMEA_HOST_PORT GRAFANA_HOST_PORT
export PROM_URL ROUTER_NA_URL ROUTER_EMEA_URL GRAFANA_URL

# NodePorts are fixed inside the cluster; only the host side ever moves.
NODEPORT_PROM=30090
NODEPORT_ROUTER_NA=30900
NODEPORT_ROUTER_EMEA=30901
NODEPORT_GRAFANA=30912
export NODEPORT_PROM NODEPORT_ROUTER_NA NODEPORT_ROUTER_EMEA NODEPORT_GRAFANA

# The namespaces build.sh expands region into.
namespaces_from_region() {
  local out=""
  for r in ${REGION//,/ }; do out="${out} ${NAMESPACE_BASE}-${r}"; done
  printf '%s' "${out# }"
}

port_in_use() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

TMP_DIR="${ROOT_DIR}/.tmp"
export TMP_DIR
mkdir -p "${TMP_DIR}"

# --- Derivations --------------------------------------------------------

# es_url_from_rw_endpoint <remote-write-url>
# Strips the path, leaving scheme://host[:port]. This is only a *candidate*;
# scripts/setup.sh probes it before anything trusts it.
es_url_from_rw_endpoint() {
  local url="${1:-}"
  [[ -n "${url}" ]] || return 1
  local scheme rest host
  scheme="${url%%://*}"
  rest="${url#*://}"
  host="${rest%%/*}"
  printf '%s://%s' "${scheme}" "${host}"
}

# data_stream_from_rw_endpoint <remote-write-url>
# Elasticsearch's native endpoint routes by path:
#   /_prometheus/<type>/<dataset>/<namespace>/api/v1/write
#     -> <type>-<dataset>.prometheus-<namespace>
#   /_prometheus/<type>/<dataset>/api/v1/write
#     -> <type>-<dataset>.prometheus-default
#   /_prometheus/<target>/api/v1/write
#     -> <target> used verbatim
#   /_prometheus/api/v1/write
#     -> metrics-generic.prometheus-default  (Elasticsearch's own default)
#
# That last form is the one superdemo uses:
#   superdemo/utils/prometheus-grafana/grafana.yaml
#     url: "$elasticsearch_es_endpoint/_prometheus/api/v1/write"
# and it reads the data back from metrics-generic.prometheus-default in both
# the Grafana datasource and assets/objects/metrics_esql.ndjson. Measured
# against a live Serverless project: 10,002 documents landed there within
# three minutes of pointing a Prometheus at the zero-segment endpoint.
data_stream_from_rw_endpoint() {
  local url="${1:-}"
  [[ -n "${url}" ]] || return 1

  # Deliberately NOT named `path`: in zsh that name is tied to $PATH, and a
  # learner who sources this file interactively would lose their shell.
  #
  # The host is not stripped here - the */_prometheus/* case below is what
  # actually anchors the match, so stripping it would be busywork.
  local urlpath mid
  urlpath="/${url#*://}"
  urlpath="${urlpath%%\?*}"     # drop any query string

  case "${urlpath}" in
    */_prometheus/*) : ;;
    *) return 1 ;;
  esac

  mid="${urlpath#*/_prometheus/}"
  mid="${mid%/api/v1/write}"
  mid="${mid%/}"
  mid="${mid#/}"

  # An endpoint with no routing segments leaves nothing between the marker and
  # /api/v1/write, and Elasticsearch routes it to its own default.
  if [[ -z "${mid}" || "${mid}" == "api/v1/write" ]]; then
    printf 'metrics-generic.prometheus-default'
    return 0
  fi

  local count
  count="$(printf '%s\n' "${mid}" | awk -F/ '{print NF}')"

  case "${count}" in
    1) printf '%s' "${mid}" ;;
    2) printf '%s-%s.prometheus-default' \
         "$(printf '%s\n' "${mid}" | cut -d/ -f1)" \
         "$(printf '%s\n' "${mid}" | cut -d/ -f2)" ;;
    *) printf '%s-%s.prometheus-%s' \
         "$(printf '%s\n' "${mid}" | cut -d/ -f1)" \
         "$(printf '%s\n' "${mid}" | cut -d/ -f2)" \
         "$(printf '%s\n' "${mid}" | cut -d/ -f3)" ;;
  esac
}

if [[ -z "${DATA_STREAM:-}" && -n "${ELASTIC_PROM_RW_ENDPOINT:-}" ]]; then
  DATA_STREAM="$(data_stream_from_rw_endpoint "${ELASTIC_PROM_RW_ENDPOINT}" || true)"
fi
export DATA_STREAM="${DATA_STREAM:-}"

# --- Guards -------------------------------------------------------------
# Call these from scripts that genuinely need the value, so that chapters 1-4
# work with no Elastic credentials at all.

require_env() {
  local missing=0 name
  for name in "$@"; do
    if [[ -z "$(eval "printf '%s' \"\${${name}:-}\"")" ]]; then
      log_fail "${name} is not set."
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    log_hint "Copy .env.example to .env and fill it in, then re-run scripts/setup.sh."
    exit 1
  fi
}

require_elastic() {
  require_env ELASTIC_ES_URL ELASTIC_API_KEY
  if [[ -z "${DATA_STREAM}" ]]; then
    log_fail "DATA_STREAM could not be derived from ELASTIC_PROM_RW_ENDPOINT."
    log_hint "Set DATA_STREAM explicitly in .env (see .env.example)."
    exit 1
  fi
}

# verify_data_stream
# Make the derivation above answer to reality instead of being trusted.
#
# Polls, because the data stream does not exist until the first sample lands.
# On failure it lists the metrics-*.prometheus-* streams that DO exist, which
# turns "nothing is arriving" from a dead end into a one-line .env edit.
#
# Uses _count rather than the _data_stream API: an API key can be perfectly
# able to write and to query while still being refused data-stream metadata,
# and in that case _data_stream returns an empty list that looks exactly like
# "your stream does not exist".
verify_data_stream() {
  local timeout="${1:-180}"
  [[ -n "${DATA_STREAM}" ]] || { log_fail "DATA_STREAM is empty."; return 1; }

  printf '%s %s...\n' "${FUNCNAME[0]}" "${DATA_STREAM}"
  local deadline=$(( $(date +%s) + timeout )) n
  while :; do
    n="$(es_curl POST "${DATA_STREAM}/_count" \
         -d '{"query":{"range":{"@timestamp":{"gte":"now-10m"}}}}' 2>/dev/null \
         | jq -r '.count // 0' 2>/dev/null || echo 0)"
    if [[ "${n}" =~ ^[0-9]+$ ]] && [[ "${n}" -gt 0 ]]; then
      printf '%s...SUCCESS (%s documents in the last 10m)\n' "${FUNCNAME[0]}" "${n}"
      return 0
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      printf '%s...ERROR: nothing in %s\n' "${FUNCNAME[0]}" "${DATA_STREAM}" >&2
      log_hint "Data streams that do exist:"
      es_curl GET "_resolve/index/metrics-*.prometheus-*" 2>/dev/null \
        | jq -r '.data_streams[]?.name' 2>/dev/null | sed 's/^/         /' >&2
      log_hint "If one of those is yours, set it in .env:  DATA_STREAM=<name>"
      return 1
    fi
    sleep 10
  done
}

# es_curl <method> <path-or-url> [curl args...]
# Absolute URLs pass through; anything else is appended to ELASTIC_ES_URL.
es_curl() {
  local method="$1" target="$2"; shift 2
  local url="${target}"
  case "${target}" in
    http://*|https://*) : ;;
    *) url="${ELASTIC_ES_URL%/}/${target#/}" ;;
  esac
  curl -sS --max-time 30 -X "${method}" \
    -H "Authorization: ApiKey ${ELASTIC_API_KEY}" \
    -H "Content-Type: application/json" \
    "${url}" "$@"
}
