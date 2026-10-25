#!/usr/bin/env bash
# Prometheus 101 — deploy orchestrator.
#
# Shaped after superdemo/build.sh on purpose: getopts with the same flag
# letters, envsubst templates applied per region, the retry protocol from
# assets/scripts/retry.sh. If you can drive this you can drive superdemo's,
# which is roughly the point of the whole course.
#
#   ./build.sh -1 true -b true -s all     # everything (what `make setup` runs)
#   ./build.sh -s router                  # redeploy one service
#   ./build.sh -r na -s all               # one region only, for a small laptop
#   ./build.sh -g true                    # Prometheus + Grafana
#   ./build.sh -o local                   # the EDOT collector
#
# Flag letters follow superdemo:
#   -h kibana  -i apikey  -j es  -k ingest  -t fleet
#   -c course  -r region  -a arch  -s service  -v version
#   -1 prereqs -b build   -o otel  -g grafana -K pull-images
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
# shellcheck source=assets/scripts/retry.sh
source "${ROOT_DIR}/assets/scripts/retry.sh"

# ---------------------------------------------------------------- defaults
course="${COURSE:-o11y--course--field--prom-101--local}"
repo="${REPO:-prom101}"
arch="${ARCH:-linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')}"
region="${REGION:-na,emea}"
namespace_base="trading"
service_version="${SERVICE_VERSION:-1.0}"
service="none"
prereq=false
build_service=false
deploy_otel=false
grafana=false
pull_images=false

OPTIND=1
while getopts "h:i:j:k:t:c:r:a:s:v:1:b:o:g:K:" opt; do
  case "$opt" in
    h ) KIBANA_URL="$OPTARG" ;;
    i ) ELASTIC_API_KEY="$OPTARG" ;;
    j ) ELASTIC_ES_URL="$OPTARG" ;;
    k ) ELASTIC_PROM_RW_ENDPOINT="$OPTARG" ;;
    t ) ELASTIC_FLEET_URL="$OPTARG" ;;
    c ) course="$OPTARG" ;;
    r ) region="$OPTARG" ;;
    a ) arch="$OPTARG" ;;
    s ) service="$OPTARG" ;;
    v ) service_version="$OPTARG" ;;
    1 ) prereq="$OPTARG" ;;
    b ) build_service="$OPTARG" ;;
    o ) deploy_otel="$OPTARG" ;;
    g ) grafana="$OPTARG" ;;
    K ) pull_images="$OPTARG" ;;
    * ) die "Unknown flag. See the header of $(basename "$0")." ;;
  esac
done

export COURSE="${course}" REPO="${repo}" SERVICE_VERSION="${service_version}"

# region=na,emea -> "trading-na trading-emea", exactly as superdemo expands it.
namespaces=""
for r in ${region//,/ }; do
  namespaces="${namespaces} ${namespace_base}-${r}"
done

# Each region's router gets its own host port, matching superdemo's Traefik
# map: trading-na on 9000, trading-emea on 9001.
nodeport_for_region() {
  case "$1" in
    na)   printf '30900' ;;
    emea) printf '30901' ;;
    *)    printf '30902' ;;
  esac
}

# ------------------------------------------------------------ image builds
if [[ "${build_service}" == "true" ]]; then
  log_step "Building service images"
  for dir in "${ROOT_DIR}"/src/*/; do
    svc="$(basename "${dir}")"
    if docker image inspect "${repo}/${svc}:${course}" >/dev/null 2>&1; then
      log_ok "${repo}/${svc}:${course} already built."
    else
      log_info "building ${repo}/${svc}:${course}"
      docker build --platform "${arch}" -q -t "${repo}/${svc}:${course}" "${dir}" >/dev/null
      log_ok "${repo}/${svc}:${course}"
    fi
    k3d image import "${repo}/${svc}:${course}" -c "${CLUSTER_NAME}" >/dev/null 2>&1 || \
      log_warn "could not import ${svc} into the cluster"
  done
fi

if [[ "${pull_images}" == "true" ]]; then
  log_step "Pre-pulling third-party images"
  for img in nginx:1.27-alpine curlimages/curl:8.11.1 redis:7.2-alpine \
             oliver006/redis_exporter:latest prom/prometheus:v3.7.3 \
             grafana/grafana:11.6.0 docker.elastic.co/elastic-agent/elastic-agent:9.5.0; do
    docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >/dev/null 2>&1 || \
      log_warn "could not pre-pull ${img}"
    k3d image import "${img}" -c "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  done
  log_ok "images available in the cluster"
fi

# ---------------------------------------------------------------- prereqs
if [[ "${prereq}" == "true" ]]; then
  log_step "Prereqs: infra namespace, Redis, RBAC"
  kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -f "${ROOT_DIR}/utils/redis/redis.yml" >/dev/null
  log_ok "Redis + redis_exporter (ns infra)"
  log_info "kube-state-metrics is NOT installed here - chapter 04 installs it."
fi

# ---------------------------------------------------------- service deploy
if [[ "${service}" != "none" ]]; then
  log_step "Deploying services to:${namespaces}"

  # The API key lives in a Secret, never in the ConfigMap that carries
  # prometheus.yml. superdemo uses one secret per namespace named
  # elastic-secret-otel; the course needs one key from it.
  if [[ -n "${ELASTIC_API_KEY:-}" ]]; then
    kubectl -n infra create secret generic "${SECRET_NAME}" \
      --from-literal=api-key="${ELASTIC_API_KEY}" \
      --from-literal=elastic_api_key="${ELASTIC_API_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log_ok "Secret ${SECRET_NAME} (ns infra)"
  fi

  for ns in ${namespaces}; do
    export NAMESPACE="${ns}"
    export REGION="${ns#${namespace_base}-}"
    export ROUTER_NODEPORT="$(nodeport_for_region "${REGION}")"

    envsubst '$NAMESPACE' < "${ROOT_DIR}/k8s/_namespace.yaml" | kubectl apply -f - >/dev/null

    for file in "${ROOT_DIR}"/k8s/*.yaml; do
      current_service="$(basename "${file}" .yaml)"
      [[ "${current_service}" == "_namespace" ]] && continue
      [[ "${service}" == "all" || "${service}" == "${current_service}" ]] || continue

      # ALWAYS pass an explicit variable list. A bare envsubst would also
      # expand $1 and $2, which appear in relabel `replacement:` values - and
      # the result still passes promtool, still starts, and silently collapses
      # every discovered target's address.
      envsubst '$NAMESPACE,$REGION,$REPO,$COURSE,$SERVICE_VERSION,$ROUTER_NODEPORT' \
        < "${file}" | kubectl apply -f - >/dev/null
      log_ok "${current_service} -> ${ns}"
    done
  done
fi

# ------------------------------------------------------ prometheus/grafana
if [[ "${grafana}" == "true" ]]; then
  log_step "Prometheus + Grafana (ns infra)"
  kubectl create namespace infra --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # Only the identity the Deployment runs as. What that identity may list is
  # the rest of rbac.yml, and chapter 03 has you apply it after seeing the
  # failure without it - so it is not granted here.
  kubectl -n infra create serviceaccount prometheus --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # Seed the ConfigMap so the Deployment has something to mount. Whatever is
  # in prometheus/prometheus.yml right now is the chapter you are starting.
  # Not the path render-config.sh writes internally - a redirect target is
  # truncated before the command runs, so it would cat itself.
  "${ROOT_DIR}/scripts/render-config.sh" > "${TMP_DIR}/prometheus.seed.yml"
  kubectl -n infra create configmap prom-config \
    --from-file=prometheus.yml="${TMP_DIR}/prometheus.seed.yml" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  envsubst '$ELASTIC_ES_URL,$DATA_STREAM,$ELASTIC_API_KEY' \
    < "${ROOT_DIR}/utils/prometheus-grafana/grafana.yaml" | kubectl apply -f - >/dev/null
  retry_command kubectl -n infra rollout status deployment/prometheus --timeout=180s >/dev/null
  log_ok "prometheus"
  retry_command kubectl -n infra rollout status deployment/grafana --timeout=180s >/dev/null
  log_ok "grafana"
fi

# ------------------------------------------------------------- collector
if [[ "${deploy_otel}" != "false" ]]; then
  log_step "EDOT collector (agents/apm/${deploy_otel}.yaml)"
  kubectl apply -f "${ROOT_DIR}/agents/apm/${deploy_otel}.yaml" >/dev/null
  retry_command kubectl -n infra rollout status deployment/otel-collector --timeout=240s >/dev/null
  log_ok "otel-collector"
fi

log_ok "build.sh complete."
