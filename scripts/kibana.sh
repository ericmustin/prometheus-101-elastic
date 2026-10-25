#!/usr/bin/env bash
# Chapter 07 helper (and used from chapter 02 onward).
#
#   scripts/kibana.sh links [file]   - print each query ready to paste, plus a
#                                      link that opens it already typed
#   scripts/kibana.sh import         - import superdemo's own saved search
#                                      (assets/objects/metrics_esql.ndjson)
#
# The queries in queries/esql/*.esql contain ${DATA_STREAM}, which Kibana does
# not expand. Everything printed here has it substituted, so it can be pasted
# straight into the ES|QL editor.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

# superdemo is a sibling checkout, not a dependency of this repo. If it is not
# there, say where to get the file rather than failing with a path.
SUPERDEMO_OBJECTS="${SUPERDEMO_OBJECTS:-${ROOT_DIR}/../superdemo/assets/objects/metrics_esql.ndjson}"

# Strip // comments and substitute ${DATA_STREAM}. This is what you paste.
render_query() {
  sed -e 's|^//.*$||' -e '/^[[:space:]]*$/d' "$1" \
    | sed -e "s|\${DATA_STREAM}|${DATA_STREAM}|g"
}

# Kibana's _a parameter is RISON, not JSON and not a plain string. A value
# containing spaces, parentheses or commas - which is every ES|QL query - has
# to be single-quoted inside the rison, with ! and ' escaped, BEFORE being
# percent-encoded. Skip that and Kibana cannot parse _a, silently discards the
# whole parameter, and opens an empty editor. That is not an error you can see
# from the outside, which is why this function exists instead of a jq @uri.
rison_url() {
  python3 -c '
import sys, urllib.parse
q = sys.stdin.read().strip()
rison = "'"'"'" + q.replace("!", "!!").replace("'"'"'", "!'"'"'") + "'"'"'"
print(urllib.parse.quote(rison, safe=""))
'
}

links() {
  [[ -n "${KIBANA_URL:-}" ]] || die "KIBANA_URL must be set in .env."
  [[ -n "${DATA_STREAM}" ]] || die "DATA_STREAM is not set."

  local files=()
  if [[ -n "${1:-}" ]]; then
    [[ -f "$1" ]] || die "No such query file: $1"
    files=("$1")
  else
    files=("${ROOT_DIR}"/queries/esql/*.esql)
  fi

  local file name query encoded
  for file in "${files[@]}"; do
    [[ -f "${file}" ]] || continue
    name="$(basename "${file}" .esql)"
    query="$(render_query "${file}")"
    encoded="$(printf '%s' "${query}" | rison_url)"

    printf '\n%s── %s %s\n' "${C_DIM}" "${name}" "${C_OFF}"
    printf '%s\n' "${query}"
    printf '\n  open: %s/app/discover#/?_a=(query:(esql:%s))&_g=(time:(from:now-1h,to:now))\n' \
      "${KIBANA_URL%/}" "${encoded}"
  done

  printf '\nPaste the query, or follow the link - both give you the same thing.\n'
}

import_saved_objects() {
  [[ -n "${KIBANA_URL:-}" && -n "${KIBANA_API_KEY:-}" ]] \
    || die "KIBANA_URL and KIBANA_API_KEY must be set in .env for chapter 07."

  if [[ ! -f "${SUPERDEMO_OBJECTS}" ]]; then
    log_fail "Not found: ${SUPERDEMO_OBJECTS}"
    log_hint "This is superdemo's own assets/objects/metrics_esql.ndjson."
    log_hint "Clone superdemo next to this repo, or point at it:"
    log_hint "  SUPERDEMO_OBJECTS=/path/to/metrics_esql.ndjson make import"
    exit 1
  fi

  log_info "Importing ${SUPERDEMO_OBJECTS##*/} unmodified"

  # createNewCopies avoids a conflict if you have imported it before. The point
  # of the chapter is that the file needs no editing, so the only thing we are
  # allowed to change is whether it collides with itself.
  local response
  response="$(curl -sS --max-time 60 \
    -H "Authorization: ApiKey ${KIBANA_API_KEY}" -H 'kbn-xsrf: true' \
    -X POST "${KIBANA_URL%/}/api/saved_objects/_import?createNewCopies=true" \
    -F "file=@${SUPERDEMO_OBJECTS}")"

  if [[ "$(jq -r '.success // false' <<<"${response}")" == "true" ]]; then
    log_ok "Imported $(jq -r '.successCount' <<<"${response}") saved object(s)."
    jq -r '.successResults[]? | "       \(.type)  \(.meta.title // "")"' <<<"${response}"
    # A link to the copy just made: every import is a new copy, so after a
    # second import "the saved search named Prometheus" is ambiguous.
    jq -r --arg kb "${KIBANA_URL%/}" '.successResults[]? | select(.type == "search")
      | "\n  open: \($kb)/app/discover#/view/\(.destinationId // .id)"' <<<"${response}"
  else
    log_fail "Import failed."
    jq '.' <<<"${response}"
    exit 1
  fi
}

case "${1:-links}" in
  links)  shift || true; links "${1:-}" ;;
  import) import_saved_objects ;;
  *) die "Usage: $(basename "$0") [links [file]|import]" ;;
esac
