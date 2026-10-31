#!/usr/bin/env bash
# Assertion primitives. Sourced by test/run.sh.

PASSED=0
FAILED=0
FAILURES=""

pass() {
  PASSED=$(( PASSED + 1 ))
  printf '%sOK:%s   %s\n' "${C_OK}" "${C_OFF}" "$*"
}

fail() {
  FAILED=$(( FAILED + 1 ))
  FAILURES="${FAILURES}
  - $1"
  if [[ "${GRADE_QUICK:-}" == 1 ]]; then
    printf '%sTODO:%s %s\n' "${C_WARN:-${C_FAIL}}" "${C_OFF}" "$1"
  else
    printf '%sFAIL:%s %s\n' "${C_FAIL}" "${C_OFF}" "$1"
  fi
  [[ -n "${2:-}" ]] && printf '        %s\n' "$2"
}

# assert_eq <actual> <expected> <description>
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    pass "$3"
  else
    fail "$3" "got '$1', wanted '$2'"
  fi
}

# assert_ge <actual> <minimum> <description>
assert_ge() {
  local a="${1%%.*}"
  if [[ "${a}" =~ ^-?[0-9]+$ ]] && [[ "${a}" -ge "$2" ]]; then
    pass "$3"
  else
    fail "$3" "got '$1', wanted >= $2"
  fi
}

# assert_le <actual> <maximum> <description>
assert_le() {
  local a="${1%%.*}"
  if [[ "${a}" =~ ^-?[0-9]+$ ]] && [[ "${a}" -le "$2" ]]; then
    pass "$3"
  else
    fail "$3" "got '$1', wanted <= $2"
  fi
}

# assert_contains <haystack> <needle> <description>
assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3" "did not find '$2'" ;;
  esac
}

# assert_not_contains <haystack> <needle> <description>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3" "found '$2' and should not have" ;;
    *) pass "$3" ;;
  esac
}

# `make goals` runs every check once and waits for nothing: at the start of a
# chapter the checks describe the goal, and most cannot pass yet, so polling
# them only costs minutes. Every helper that waits asks this for its budget.
wait_budget() {
  if [[ "${GRADE_QUICK:-}" == 1 ]]; then echo 0; else echo "$1"; fi
}

# retry_until <timeout-seconds> <description> <command...>
# Runs the command until it exits 0. Used wherever the thing being asserted is
# eventually-consistent: a scrape that has not happened yet, a remote write
# batch still in flight.
retry_until() {
  local timeout desc="$2"; timeout="$(wait_budget "$1")"; shift 2
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    if "$@"; then
      pass "${desc}"
      return 0
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      fail "${desc}" "still false after ${timeout}s"
      return 1
    fi
    sleep 5
  done
}

summarise() {
  echo
  if [[ "${GRADE_QUICK:-}" == 1 && "${FAILED}" -gt 0 ]]; then
    printf '%s%s passed, %s to do.%s\n' "${C_OK}" "${PASSED}" "${FAILED}" "${C_OFF}"
    printf 'Your goals for this chapter:%s\n' "${FAILURES}"
    printf '\nOne pass, no waiting. Once you have made the change, run make test:\nit waits for data to arrive before it decides.\n'
    return 1
  fi
  if [[ "${FAILED}" -eq 0 ]]; then
    printf '%s%s passed, 0 failed.%s\n' "${C_OK}" "${PASSED}" "${C_OFF}"
    return 0
  fi
  printf '%s%s passed, %s failed.%s\n' "${C_FAIL}" "${PASSED}" "${FAILED}" "${C_OFF}"
  printf 'Still wrong:%s\n' "${FAILURES}"
  return 1
}
