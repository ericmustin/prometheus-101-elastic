#!/usr/bin/env bash
# Shared output helpers. Sourced, never executed.
#
# Output vocabulary:
#   OK:   the thing we wanted is true
#   WARN: not fatal, but you should look
#   FAIL: fatal, we are stopping
#   INFO: context, no judgement

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_OFF=""
fi

log_ok()   { printf '%sOK:%s   %s\n' "${C_OK}" "${C_OFF}" "$*"; }
log_warn() { printf '%sWARN:%s %s\n' "${C_WARN}" "${C_OFF}" "$*"; }
log_fail() { printf '%sFAIL:%s %s\n' "${C_FAIL}" "${C_OFF}" "$*" >&2; }
log_info() { printf 'INFO: %s\n' "$*"; }
log_hint() { printf '%sHINT: %s%s\n' "${C_DIM}" "$*" "${C_OFF}" >&2; }
log_step() { printf '\n== %s\n' "$*"; }

die() { log_fail "$*"; exit 1; }
