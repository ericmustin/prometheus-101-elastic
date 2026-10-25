#!/usr/bin/env bash
# Run an ES|QL query file (or a query on stdin) and print the result as a table.
#
#   scripts/esql.sh queries/esql/03-router-rate-by-region.esql
#   echo 'TS ${DATA_STREAM} | METRICS_INFO | LIMIT 20' | scripts/esql.sh
#
# ${DATA_STREAM} is substituted for you.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
require_elastic

if [[ -n "${1:-}" ]]; then
  [[ -f "$1" ]] || die "No such query file: $1"
  raw="$(cat "$1")"
else
  raw="$(cat)"
fi

query="$(printf '%s' "${raw}" | sed -e "s|\${DATA_STREAM}|${DATA_STREAM}|g")"

printf '%s\n' "--- query ---" >&2
printf '%s\n' "${query}" >&2
printf '%s\n' "-------------" >&2

es_curl POST "_query?format=txt" -d "$(printf '%s' "${query}" | jq -Rs '{query: .}')"
