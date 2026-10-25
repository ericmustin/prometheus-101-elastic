#!/usr/bin/env bash
# Grade your work.
#
#   make test          - grade the chapter you are on (from the branch name)
#   CHAPTER=05 make test
#   test/run.sh --all  - grade everything, chapter 01 through 07
#
# Every chapter re-runs all the earlier chapters' assertions, so the course's
# dependency chain is mechanical rather than just narrative: you cannot pass
# chapter 05 with a broken chapter 03.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"
# shellcheck source=lib/assert.sh
source "${ROOT_DIR}/test/lib/assert.sh"
# shellcheck source=lib/prom.sh
source "${ROOT_DIR}/test/lib/prom.sh"
# shellcheck source=lib/elastic.sh
source "${ROOT_DIR}/test/lib/elastic.sh"

detect_chapter() {
  [[ -n "${CHAPTER:-}" ]] && { printf '%02d' "$((10#${CHAPTER}))"; return 0; }
  local n
  [[ -f "${ROOT_DIR}/.chapter" ]] || return 1
  n="$(tr -dc '0-9' < "${ROOT_DIR}/.chapter")"
  [[ -n "${n}" ]] || return 1
  printf '%02d' "$((10#${n}))"
}

target=""
if [[ "${1:-}" == "--all" ]]; then
  target="07"
elif ! target="$(detect_chapter)"; then
  log_fail "Cannot tell which chapter to grade."
  log_hint "Start one:            make chapter 1"
  log_hint "Or say so explicitly: CHAPTER=01 make test"
  exit 2
fi

# solutions/08 is the finished pipeline, not a chapter with its own
# assertions. Without this clamp, grading there runs no tests at all and
# cheerfully reports "0 passed" - which looks like success.
[[ "${target}" > "07" ]] && target="07"

if ! prom_up; then
  log_fail "Prometheus is not answering at ${PROM_URL}"
  log_hint "  make setup     (first time)"
  log_hint "  kubectl -n ${PROM_NAMESPACE} get pods"
  exit 2
fi

printf '\nGrading chapter %s (cumulative: 01 through %s)\n' "${target}" "${target}"
printf 'Prometheus: %s\n' "${PROM_URL}"
if es_available; then
  printf 'Elastic:    %s\n' "${DATA_STREAM}"
else
  printf 'Elastic:    not configured (chapter 02 onward will fail)\n'
fi

for n in 01 02 03 04 05 06 07; do
  [[ "${n}" > "${target}" ]] && break
  file="$(ls "${ROOT_DIR}/test/chapters/${n}-"*.sh 2>/dev/null | head -1)"
  if [[ -z "${file}" ]]; then
    continue
  fi
  printf '\n%s-- chapter %s %s%s\n' "${C_DIM}" "${n}" "$(basename "${file}" .sh | cut -d- -f2- | tr '-' ' ')" "${C_OFF}"
  # shellcheck source=/dev/null
  source "${file}"
done

summarise
