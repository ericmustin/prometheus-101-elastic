#!/usr/bin/env bash
# Gate 0: is this machine able to run the course?
#
# Hard-fails only on things with no workaround. Everything else warns, so you
# can start chapter 01 with no Elastic credentials at all - chapter 01 is
# entirely local. Chapter 02 onward needs Elastic.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

log_step "Gate 0: environment"
log_info "Project: ${ROOT_DIR}"

fatal=0

for tool in docker kubectl k3d jq curl; do
  if command -v "${tool}" >/dev/null 2>&1; then
    log_ok "${tool} is on PATH ($(command -v "${tool}"))."
  else
    log_fail "${tool} is not installed or not on PATH."
    fatal=1
  fi
done

if [[ "${fatal}" -ne 0 ]]; then
  log_hint "macOS:  brew install k3d kubectl jq   (Docker Desktop for docker)"
  log_hint "Linux:  https://k3d.io/#installation"
  exit 1
fi

if docker info >/dev/null 2>&1; then
  log_ok "Docker daemon is responding ($(docker info --format '{{.ServerVersion}}' 2>/dev/null))."
else
  die "Docker daemon is not responding. Start Docker Desktop and retry."
fi

# Ask k3d once, and keep both its output and whether it worked at all. A
# failing `k3d cluster list` is NOT the same as "no cluster" - Docker Desktop
# demanding an org sign-in makes the listing fail while the cluster keeps
# running - and reporting the second when it is the first sends a learner off
# to re-run setup for no reason.
k3d_out="$(k3d cluster list 2>&1)" && k3d_ok=1 || k3d_ok=0
cluster_exists=0
[[ "${k3d_ok}" -eq 1 ]] && grep -q "^${CLUSTER_NAME} " <<<"${k3d_out}" && cluster_exists=1
conflicts=0
for port in "${PROM_HOST_PORT}" "${ROUTER_NA_HOST_PORT}" "${ROUTER_EMEA_HOST_PORT}" "${GRAFANA_HOST_PORT}"; do
  if port_in_use "${port}"; then
    owner="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -F c 2>/dev/null | sed -n 's/^c//p' | head -1)"
    if [[ "${cluster_exists}" -eq 1 ]]; then
      log_ok "Port ${port} is in use by ${owner:-something} (expected - your cluster is running)."
    else
      log_warn "Port ${port} is in use by ${owner:-something}."
      conflicts=1
    fi
  else
    log_ok "Port ${port} is free."
  fi
done
if [[ "${conflicts}" -eq 1 ]]; then
  log_info "Not a problem: setup.sh shifts all of them by +20000 and records them in .env."
fi

log_step "Elastic configuration"
if [[ -f "${ROOT_DIR}/.env" ]]; then
  log_ok ".env exists."
else
  log_warn ".env is missing. Chapter 01 works without it; chapter 02 onward needs it."
  log_hint "  cp .env.example .env"
fi

if [[ -n "${ELASTIC_PROM_RW_ENDPOINT:-}" ]]; then
  log_ok "ELASTIC_PROM_RW_ENDPOINT is set."
  if [[ -n "${DATA_STREAM}" ]]; then
    log_ok "Data stream derived from the endpoint path: ${DATA_STREAM}"
  else
    log_warn "Could not derive a data stream from that endpoint path."
    log_hint "  Set DATA_STREAM explicitly in .env (see .env.example)."
  fi
else
  log_warn "ELASTIC_PROM_RW_ENDPOINT is not set (needed from chapter 02)."
fi

if [[ -n "${ELASTIC_API_KEY:-}" ]]; then
  log_ok "ELASTIC_API_KEY is set (${#ELASTIC_API_KEY} chars)."
else
  log_warn "ELASTIC_API_KEY is not set (needed from chapter 02)."
fi

if [[ -n "${ELASTIC_ES_URL:-}" ]]; then
  log_ok "ELASTIC_ES_URL is set."
else
  log_warn "ELASTIC_ES_URL is not set. scripts/setup.sh will probe for it."
fi

if [[ -n "${KIBANA_URL:-}" && -n "${KIBANA_API_KEY:-}" ]]; then
  log_ok "Kibana credentials are set (needed from chapter 07)."
else
  log_warn "KIBANA_URL / KIBANA_API_KEY are not both set (needed from chapter 07)."
fi

log_step "Cluster"
if [[ "${k3d_ok}" -eq 0 ]]; then
  log_warn "k3d could not list clusters. Its error was:"
  printf '%s\n' "${k3d_out}" | sed 's/^/       /'
  log_hint "The cluster may still be running - this is a k3d/Docker problem,"
  log_hint "not necessarily a missing cluster. Check with: kubectl get ns"
elif [[ "${cluster_exists}" -eq 1 ]]; then
  log_ok "k3d cluster '${CLUSTER_NAME}' exists."
  for ns in $(namespaces_from_region) infra; do
    if kubectl get ns "${ns}" >/dev/null 2>&1; then
      log_ok "Namespace ${ns} exists."
    else
      log_warn "Namespace ${ns} is missing. Run: make setup"
    fi
  done
else
  log_warn "k3d cluster '${CLUSTER_NAME}' does not exist yet. Run: make setup"
fi

# Always print these. The chapters are written with superdemo's port numbers,
# but setup.sh shifts every one of them by +20000 if the defaults were taken -
# so the numbers in the prose are the numbers you get on a clean machine and
# these are the numbers you actually have.
log_step "Your URLs"
log_info "Prometheus     : ${PROM_URL}"
log_info "router (na)    : ${ROUTER_NA_URL}/metrics"
log_info "router (emea)  : ${ROUTER_EMEA_URL}/metrics"
log_info "Grafana        : ${GRAFANA_URL}"
if [[ "${PROM_HOST_PORT}" != "9090" ]]; then
  log_warn "These are NOT the ports the chapters print, because the defaults were taken."
  log_hint "To match the course text (and superdemo), free 9090/9000/9001/9012,"
  log_hint "remove the *_HOST_PORT lines from .env, and re-run: make clean && make setup"
fi

echo
log_info "Gate 0 complete."
