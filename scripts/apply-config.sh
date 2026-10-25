#!/usr/bin/env bash
# Push prometheus/prometheus.yml into the cluster. The command you run after
# every edit.
#
#   render + validate  ->  ConfigMap prom-config  ->  rollout restart
#
# `rollout restart`, not POST /-/reload: kubelet's ConfigMap projection is
# eventually consistent, so an immediate reload re-reads the OLD file. That
# race would silently poison half the chapters.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

log_step "Rendering and validating prometheus/prometheus.yml"
# Not the same path render-config.sh writes internally: the shell truncates a
# redirect target before the command runs, so redirecting into that file would
# have it cat itself.
"${ROOT_DIR}/scripts/render-config.sh" > "${TMP_DIR}/prometheus.applied.yml"
log_ok "config is valid"

log_step "Applying to cluster"
kubectl -n "${PROM_NAMESPACE}" create configmap prom-config \
  --from-file=prometheus.yml="${TMP_DIR}/prometheus.applied.yml" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
log_ok "ConfigMap prom-config updated"

kubectl -n "${PROM_NAMESPACE}" rollout restart deployment/prometheus >/dev/null
kubectl -n "${PROM_NAMESPACE}" rollout status deployment/prometheus --timeout=120s
log_ok "Prometheus restarted with your config"

log_info "Targets page: ${PROM_URL}/targets"
