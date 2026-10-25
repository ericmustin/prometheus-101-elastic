#!/usr/bin/env bash
# Poll an ES|QL query until it returns data, or fail loudly.
#
# Remote write is asynchronous: Prometheus batches, ships, and Elasticsearch
# indexes on its own schedule. A single query right after `make apply` will
# almost always come back empty, which is why every Elastic assertion in this
# course polls instead of asking once.
#
# Usage:
#   scripts/assert-esql-rows.sh queries/esql/01-landed.esql
#   scripts/assert-esql-rows.sh <file> --min-rows 3 --min-value 1 --timeout 300
#
# ${DATA_STREAM} inside the query file is substituted, so query files stay
# portable across learners whose endpoints differ.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
require_elastic

query_file="${1:-}"
[[ -n "${query_file}" ]] || die "Usage: $(basename "$0") <query.esql> [--min-rows N] [--min-value N] [--timeout S]"
[[ -f "${query_file}" ]] || die "No such query file: ${query_file}"
shift

min_rows=1
min_value=""
timeout_s=180
label="$(basename "${query_file}")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-rows)  min_rows="$2";  shift 2 ;;
    --min-value) min_value="$2"; shift 2 ;;
    --timeout)   timeout_s="$2"; shift 2 ;;
    --label)     label="$2";     shift 2 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

payload="$(sed -e "s|\${DATA_STREAM}|${DATA_STREAM}|g" "${query_file}" | jq -Rs '{query: .}')"
deadline=$(( $(date +%s) + timeout_s ))
attempt=0
body=""

while :; do
  attempt=$(( attempt + 1 ))
  body="$(es_curl POST "_query?format=json" -d "${payload}" || true)"

  # A data stream that does not exist yet, or a field that is not in the
  # mapping yet, both mean "not landed" - not "broken". Keep polling.
  #
  # Read the error with jq rather than grepping the body: a bare FROM returns
  # every column, and one of this course's metrics is called
  # node_filesystem_device_error.
  rows="$(printf '%s' "${body}" | jq -r '
    if has("error") then -1 else ((.values // []) | length) end' 2>/dev/null || echo -1)"

  if [[ "${rows}" =~ ^[0-9]+$ ]] && [[ "${rows}" -ge "${min_rows}" ]]; then
    if [[ -z "${min_value}" ]]; then
      log_ok "${label}: ${rows} row(s) after ${attempt} attempt(s)."
      printf '%s' "${body}" | jq -r '.columns[].name' | paste -sd $'\t' - 2>/dev/null || true
      printf '%s' "${body}" | jq -r '.values[0:3][] | @tsv' 2>/dev/null || true
      exit 0
    fi
    value="$(printf '%s' "${body}" | jq -r '.values[0][0] // 0')"
    # Integer compare only - bash has no floats. Truncate.
    if [[ "${value%%.*}" =~ ^-?[0-9]+$ ]] && [[ "${value%%.*}" -ge "${min_value}" ]]; then
      log_ok "${label}: ${value} (wanted >= ${min_value}) after ${attempt} attempt(s)."
      exit 0
    fi
  fi

  if [[ "$(date +%s)" -ge "${deadline}" ]]; then
    log_fail "${label}: did not reach the threshold within ${timeout_s}s."
    printf '      rows=%s min_rows=%s min_value=%s\n' "${rows}" "${min_rows}" "${min_value:-n/a}" >&2
    printf '%s\n' "${body}" | head -30 >&2
    log_hint "Check remote write health:"
    log_hint "  curl -s '${PROM_URL}/api/v1/query?query=prometheus_remote_storage_samples_failed_total'"
    log_hint "  kubectl -n ${PROM_NAMESPACE} logs deploy/prometheus --tail=50"
    exit 1
  fi
  sleep 5
done
