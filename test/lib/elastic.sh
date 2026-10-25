#!/usr/bin/env bash
# Talking to Elastic.
#
# Two design notes from validating this course against a live project:
#
# 1. Grading queries use plain `FROM ... | STATS COUNT(field)`, not the
#    `TS` / `METRICS_INFO` / `RATE` time-series surface. The TS surface is the
#    right thing to SHOW a learner and the wrong thing to GRADE with, because
#    its availability and syntax move between 9.x releases. (`COUNT(*)` is
#    also rejected under `TS` - it wants a field.) The chapters teach TS; the
#    tests quietly use FROM.
#
# 2. Absence is asserted with _count + an `exists` filter, never with ES|QL.
#    ES|QL raises "Unknown column" for a field that is not in the mapping, so
#    a learner who never enabled the noisy metric would get a 400 instead of
#    the clean zero the assertion wants.

es_available() {
  [[ -n "${ELASTIC_ES_URL:-}" && -n "${ELASTIC_API_KEY:-}" && -n "${DATA_STREAM:-}" ]]
}

# Run a raw ES|QL string, return the JSON body.
esql() {
  es_curl POST "_query?format=json" -d "$(printf '%s' "$1" | jq -Rs '{query: .}')"
}

# Number of rows an ES|QL query returned. Errors count as -1 so callers can
# tell "query failed" apart from "query returned nothing".
#
# Detect errors with jq on the top-level `error` key, NOT by grepping the body
# for the string "error". A bare `FROM` returns every column in the data
# stream, and this course has a metric called node_filesystem_device_error -
# so a substring check reports failure on a perfectly good result.
esql_rows() {
  local body; body="$(esql "$1")"
  printf '%s' "${body}" | jq -r 'if has("error") then -1 else ((.values // []) | length) end' 2>/dev/null || echo -1
}

# First cell of the first row.
esql_value() {
  esql "$1" | jq -r '.values[0][0] // ""' 2>/dev/null
}

# Documents in the course data stream that have <field> set, since <window>.
es_count_field() {
  local field="$1" since="${2:-now-5m}"
  local body
  body="$(es_curl POST "${DATA_STREAM}/_count" -d "$(jq -n --arg f "${field}" --arg s "${since}" '{
    query: { bool: { filter: [
      { range: { "@timestamp": { gte: $s } } },
      { exists: { field: $f } }
    ] } } }')")"
  # A data stream that does not exist yet legitimately means zero.
  printf '%s' "${body}" | jq -r '
    if (.error.type? // "") == "index_not_found_exception" then 0
    elif has("error") then -1
    else (.count // -1) end' 2>/dev/null || echo -1
}

# Poll an ES|QL query until it returns at least one row, then report the count.
#
# Use this instead of a bare esql_rows whenever the query has a time window in
# it. A window wide enough to be reliable is also wide enough to still contain
# the PREVIOUS chapter's data - or, if you went back a chapter, the later
# chapter's data - so a wide window turns the assertion into
# something that passes when the learner has done nothing. Narrow the window
# and poll for delivery instead of widening it and hoping.
wait_for_esql_rows() {
  local query="$1" timeout="${2:-180}"
  local deadline=$(( $(date +%s) + timeout )) n
  while :; do
    n="$(esql_rows "${query}")"
    [[ "${n}" =~ ^[0-9]+$ ]] && [[ "${n}" -ge 1 ]] && { printf '%s' "${n}"; return 0; }
    [[ "$(date +%s)" -ge "${deadline}" ]] && { printf '%s' "${n:-0}"; return 1; }
    sleep 10
  done
}

# Poll until at least <min> documents with <field> have arrived.
wait_for_docs() {
  local field="$1" min="${2:-1}" window="${3:-now-5m}" timeout="${4:-240}"
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    local n; n="$(es_count_field "${field}" "${window}")"
    [[ "${n}" =~ ^[0-9]+$ ]] && [[ "${n}" -ge "${min}" ]] && return 0
    [[ "$(date +%s)" -ge "${deadline}" ]] && return 1
    sleep 10
  done
}

kibana_available() {
  [[ -n "${KIBANA_URL:-}" && -n "${KIBANA_API_KEY:-}" ]]
}

kibana_curl() {
  local method="$1" path="$2"; shift 2
  curl -sS --max-time 30 -X "${method}" \
    -H "Authorization: ApiKey ${KIBANA_API_KEY}" \
    -H "kbn-xsrf: true" \
    -H "Content-Type: application/json" \
    "${KIBANA_URL%/}/${path#/}" "$@"
}
