#!/usr/bin/env bash
# Count documents in the course data stream that have a given field set,
# inside a time window, and assert the count is within bounds.
#
# Why this exists as well as assert-esql-rows.sh: ES|QL raises
# "Unknown column" when a field is absent from the mapping. That makes it the
# wrong tool for proving ABSENCE - a learner who adds the chapter 06 drop rule
# without ever enabling the noisy metric would get a 400 instead of a clean
# zero. A plain _count with an `exists` filter returns 0 for unmapped fields
# without erroring, which is exactly the semantics we want.
#
# Usage:
#   scripts/assert-es-count.sh --field metrics.http_requests_total \
#                              --since now-3m --max 0
#   scripts/assert-es-count.sh --field metrics.transactions \
#                              --since now-3m --min 1
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
require_elastic

field=""
since="now-5m"
min_count=""
max_count=""
timeout_s=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --field)   field="$2";      shift 2 ;;
    --since)   since="$2";      shift 2 ;;
    --min)     min_count="$2";  shift 2 ;;
    --max)     max_count="$2";  shift 2 ;;
    --timeout) timeout_s="$2";  shift 2 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

[[ -n "${field}" ]] || die "--field is required"
[[ -n "${min_count}${max_count}" ]] || die "one of --min or --max is required"

query="$(jq -n --arg field "${field}" --arg since "${since}" '{
  query: { bool: { filter: [
    { range: { "@timestamp": { gte: $since } } },
    { exists: { field: $field } }
  ] } }
}')"

count_docs() {
  local body
  body="$(es_curl POST "${DATA_STREAM}/_count" -d "${query}" || true)"
  case "${body}" in
    *index_not_found_exception*) printf '0' ;;
    *) printf '%s' "${body}" | jq -r '.count // "ERR"' 2>/dev/null || printf 'ERR' ;;
  esac
}

# A --min assertion is waiting for data to arrive, so it polls.
# A --max assertion (usually "prove it is gone") is checked once after a
# settle, because polling would just wait for a number that should stay put.
if [[ -n "${min_count}" ]]; then
  deadline=$(( $(date +%s) + timeout_s ))
  while :; do
    count="$(count_docs)"
    if [[ "${count}" =~ ^[0-9]+$ ]] && [[ "${count}" -ge "${min_count}" ]]; then
      log_ok "${field}: ${count} doc(s) since ${since} (wanted >= ${min_count})."
      break
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      log_fail "${field}: ${count} doc(s) since ${since}, wanted >= ${min_count}."
      exit 1
    fi
    sleep 5
  done
fi

if [[ -n "${max_count}" ]]; then
  count="$(count_docs)"
  if [[ "${count}" =~ ^[0-9]+$ ]] && [[ "${count}" -le "${max_count}" ]]; then
    log_ok "${field}: ${count} doc(s) since ${since} (wanted <= ${max_count})."
  else
    log_fail "${field}: ${count} doc(s) since ${since}, wanted <= ${max_count}."
    log_hint "Dropping does not delete documents already ingested - it only stops new ones."
    log_hint "Wait for the window to roll past your change, then re-run."
    exit 1
  fi
fi
