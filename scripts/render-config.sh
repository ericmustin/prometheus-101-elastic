#!/usr/bin/env bash
# Render prometheus/prometheus.yml and validate it. Writes the rendered config
# to stdout; everything else goes to stderr so this composes.
#
# Two guarantees this file exists to keep, both of which predate the superdemo
# retarget and neither of which may be lost:
#
#   1. promtool validates before anything reaches the cluster, so a typo fails
#      here rather than in a crash loop.
#   2. a pasted API key is refused. This config becomes a ConfigMap, and a
#      ConfigMap is plaintext to anyone who can run `kubectl get cm -o yaml`.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

CONFIG_SRC="${1:-${ROOT_DIR}/prometheus/prometheus.yml}"
CONFIG_OUT="${TMP_DIR}/prometheus.rendered.yml"

[[ -f "${CONFIG_SRC}" ]] || die "Missing ${CONFIG_SRC}"

if grep -q '\${ELASTIC_PROM_RW_ENDPOINT}' "${CONFIG_SRC}"; then
  require_env ELASTIC_PROM_RW_ENDPOINT
fi

# Prometheus does not expand environment variables in its config, so something
# outside Prometheus has to. sed rather than envsubst, deliberately: envsubst
# would also eat the $1 and $2 in relabel `replacement:` values.
sed -e "s|\${ELASTIC_PROM_RW_ENDPOINT}|${ELASTIC_PROM_RW_ENDPOINT:-}|g" \
    "${CONFIG_SRC}" > "${CONFIG_OUT}"

if grep -qE 'credentials:[[:space:]]*["'\'']?[A-Za-z0-9+/=_-]{30,}' "${CONFIG_SRC}"; then
  log_fail "prometheus/prometheus.yml looks like it contains a literal API key."
  log_hint "Use 'credentials_file: /etc/elastic/api-key' - a ConfigMap is plaintext."
  exit 1
fi

# The image entrypoint is /bin/prometheus, so promtool must be selected.
#
# Keep promtool's own output and its exit status apart. "docker could not run
# promtool" and "promtool read your config and hated it" are different
# problems with different fixes, and reporting the second when it was the
# first sends a learner off to hunt a YAML bug that is not there.
promtool_out="$(docker run --rm --entrypoint=/bin/promtool \
    -v "${CONFIG_OUT}:/tmp/prometheus.yml:ro" \
    "${PROM_IMAGE}" check config /tmp/prometheus.yml 2>&1)" && promtool_rc=0 || promtool_rc=$?

if [[ "${promtool_rc}" -ne 0 ]]; then
  printf '%s\n' "${promtool_out}" >&2
  if grep -qiE 'cannot connect to the docker daemon|docker desktop|permission denied while trying to connect|error response from daemon|no such host|manifest unknown|pull access denied' <<<"${promtool_out}"; then
    log_fail "promtool could not RUN. Your config was not checked, and nothing was applied."
    log_hint "This is Docker, not your YAML - read the error above."
    log_hint "Common causes: Docker Desktop not started, or asking you to sign in."
  else
    log_fail "promtool rejected the config. Nothing was applied."
  fi
  exit 1
fi
printf '%s\n' "${promtool_out}" >&2

cat "${CONFIG_OUT}"
