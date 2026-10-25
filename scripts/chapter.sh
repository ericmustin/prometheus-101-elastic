#!/usr/bin/env bash
# Chapter navigation. No branches - everything lives on one branch, and the
# chapter you are on is a number in .chapter (gitignored).
#
#   make chapter 3    start chapter 3
#   make status       which chapter am I on?
#   make hint         what is still different from the solution?
#   make answer       the change this chapter is asking for
#
# solutions/NN/ holds the state you START chapter NN in, which is the same
# thing as the SOLUTION to chapter NN-1. There are seven chapters and eight
# solution directories: 08 is the finished pipeline, so that chapter 07 has
# something to be compared against.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd .. && pwd)"
# shellcheck source=lib/env.sh
source "${ROOT_DIR}/scripts/lib/env.sh"

CONFIG="prometheus/prometheus.yml"
STATE="${ROOT_DIR}/.chapter"
LAST_CHAPTER=07

pad() { printf '%02d' "$((10#${1}))"; }

current_chapter() {
  [[ -f "${STATE}" ]] || return 1
  local n; n="$(tr -dc '0-9' < "${STATE}")"
  [[ -n "${n}" ]] || return 1
  pad "${n}"
}

solution_dir() { printf '%s/solutions/%s' "${ROOT_DIR}" "$(pad "$1")"; }

require_chapter() {
  local n
  if ! n="$(current_chapter)"; then
    log_fail "I do not know which chapter you are on."
    log_hint "  make chapter 1"
    exit 2
  fi
  printf '%s' "${n}"
}

show_status() {
  local n
  if n="$(current_chapter)"; then
    local doc; doc="$(ls "${ROOT_DIR}/chapters/${n}-"*.md 2>/dev/null | head -1 || true)"
    log_info "Chapter ${n} of ${LAST_CHAPTER}"
    [[ -n "${doc}" ]] && log_info "Read: ${doc#"${ROOT_DIR}"/}"
    log_hint "Edit ${CONFIG}, then: make apply && make test"
  else
    log_warn "No chapter started yet."
    log_hint "  make chapter 1"
  fi
}

# Put the working tree into chapter N's STARTING state.
start_chapter() {
  local n; n="$(pad "$1")"
  local dir; dir="$(solution_dir "${n}")"
  [[ -d "${dir}" ]] || die "No solutions/${n}. Chapters are 01-${LAST_CHAPTER}."

  if [[ "$((10#${n}))" -gt "$((10#${LAST_CHAPTER}))" ]]; then
    die "There are ${LAST_CHAPTER} chapters."
  fi

  # Overwriting the learner's file is the whole job of this command, but doing
  # it silently to unsaved work is not. Only ask when it would actually lose
  # something - a fresh start, or a re-run of the chapter you are already on,
  # is not a surprise.
  if [[ -f "${ROOT_DIR}/${CONFIG}" ]] && ! diff -q "${dir}/prometheus.yml" "${ROOT_DIR}/${CONFIG}" >/dev/null 2>&1; then
    local cur; cur="$(current_chapter || true)"
    if [[ -n "${cur}" && "${cur}" != "${n}" ]]; then
      cp "${ROOT_DIR}/${CONFIG}" "${TMP_DIR}/prometheus.chapter-${cur}.yml"
      log_info "Your chapter ${cur} config saved to .tmp/prometheus.chapter-${cur}.yml"
    fi
  fi

  cp "${dir}/prometheus.yml" "${ROOT_DIR}/${CONFIG}"

  # From chapter 04 the starting state also includes the scrape annotation
  # chapter 03 had you add to the router manifest.
  if [[ -d "${dir}/overlay" ]]; then
    cp -R "${dir}/overlay/." "${ROOT_DIR}/"
  else
    git -C "${ROOT_DIR}" checkout -- k8s/router.yaml 2>/dev/null || true
  fi

  printf '%s\n' "${n}" > "${STATE}"
  log_ok "Chapter ${n}. ${CONFIG} is at its starting state."
  show_status
}

# What is still different between your file and the solution?
# Comments are ignored: grading is behavioural, so a learner who writes a
# working config without copying the prose should not be told they are wrong.
show_hint() {
  local n; n="$(require_chapter)"
  local nxt; nxt="$(pad "$((10#${n} + 1))")"
  local sol; sol="$(solution_dir "${nxt}")/prometheus.yml"
  [[ -f "${sol}" ]] || { log_info "Chapter ${n} is the last one."; return 0; }

  # Ignore comments, trailing whitespace, and a missing final newline. A
  # learner who typed a working config should not be told they are wrong
  # because of two trailing spaces - `awk 1` normalises the last line.
  strip() {
    sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$1" | awk 1
  }
  strip "${ROOT_DIR}/${CONFIG}" > "${TMP_DIR}/hint-yours.yml"
  strip "${sol}"               > "${TMP_DIR}/hint-solution.yml"

  if diff -u "${TMP_DIR}/hint-yours.yml" "${TMP_DIR}/hint-solution.yml" > "${TMP_DIR}/hint.diff"; then
    log_ok "Your configuration matches the chapter ${n} solution."
  else
    log_info "Still different (yours on the left, solution on the right):"
    sed -e "s|--- .*|--- yours|" -e "s|+++ .*|+++ solution|" "${TMP_DIR}/hint.diff"
  fi
}

show_answer() {
  local n; n="$(require_chapter)"
  local nxt; nxt="$(pad "$((10#${n} + 1))")"
  local from; from="$(solution_dir "${n}")"
  local to;   to="$(solution_dir "${nxt}")"
  [[ -d "${to}" ]] || { log_info "Chapter ${n} is the last one."; return 0; }

  # `diff` exits 1 when files differ, which is the case we are here for. With
  # `set -o pipefail` that kills the script mid-answer, so every diff below is
  # explicitly tolerated.
  show_diff() {
    diff -u "$1" "$2" | sed -e "s|--- .*|--- before|" -e "s|+++ .*|+++ after|" || true
  }

  local shown=0
  if ! diff -q "${from}/prometheus.yml" "${to}/prometheus.yml" >/dev/null 2>&1; then
    log_info "The change chapter ${n} is asking for, in ${CONFIG}:"
    show_diff "${from}/prometheus.yml" "${to}/prometheus.yml"
    shown=1
  fi

  # Chapter 03 is a two-file edit; showing only the config shows half an answer.
  if [[ -f "${to}/overlay/k8s/router.yaml" && ! -f "${from}/overlay/k8s/router.yaml" ]]; then
    log_info "...and in k8s/router.yaml:"
    show_diff "${ROOT_DIR}/k8s/router.yaml" "${to}/overlay/k8s/router.yaml"
    shown=1
  fi

  if [[ "${shown}" -eq 0 ]]; then
    log_info "Chapter ${n} changes no file in this repo - that is the point."
    case "${n}" in
      05) log_hint "The collector is found by the rules you wrote in chapter 03."
          log_hint "Deploy it and it appears:  make collector" ;;
      07) log_hint "Grafana's two datasources are provisioned by build.sh:  make grafana" ;;
    esac
  fi
}

case "${1:-status}" in
  status)  show_status ;;
  hint)    show_hint ;;
  answer)  show_answer ;;
  [0-9]|[0-9][0-9]) start_chapter "$1" ;;
  *) die "Usage: $(basename "$0") [status|hint|answer|<chapter-number>]" ;;
esac
