#!/usr/bin/env bash
# Talking to the running Prometheus.
#
# Design note, learned the hard way during course validation: the TSDB is on a
# PersistentVolume, so it survives the restart that `make apply` performs. That
# is good for the learner (chapter 03 can still see chapter 02's graph) and a
# trap for a grader: an instant query returns the last sample for EVERY series
# within the 5 minute staleness window, including series produced by an earlier
# chapter's config.
#
# So: assert structure against /api/v1/targets, which is always current state,
# and use queries for behaviour ("is a number moving") rather than for
# "does a badly-labelled series exist anywhere".

prom_up() {
  curl -sS --max-time 5 -o /dev/null "${PROM_URL}/-/ready" 2>/dev/null
}

prom_query() {
  curl -sS --max-time 15 --get --data-urlencode "query=$1" "${PROM_URL}/api/v1/query" 2>/dev/null
}

# First scalar value of a query, or "" if there is no result.
prom_scalar() {
  prom_query "$1" | jq -r '.data.result[0].value[1] // ""' 2>/dev/null
}

# Scalar value of a count()-style query, with an empty result read as zero.
#
# PromQL count() over a vector that matches nothing returns NO result rather
# than 0, so a bare prom_scalar gives you "" exactly when the answer is zero -
# which is usually the case you are asserting on.
prom_count_scalar() {
  local v; v="$(prom_scalar "$1")"
  if [[ -z "${v}" || "${v}" == "NaN" ]]; then printf '0'; else printf '%s' "${v}"; fi
}

# Number of series a query returns.
prom_count() {
  prom_query "$1" | jq -r '.data.result | length' 2>/dev/null || echo 0
}

prom_targets() {
  curl -sS --max-time 15 "${PROM_URL}/api/v1/targets" 2>/dev/null
}

# Active targets belonging to one job, as compact JSON lines.
prom_targets_for() {
  prom_targets | jq -c --arg job "$1" '.data.activeTargets[] | select(.labels.job == $job)' 2>/dev/null
}

# Only the FINAL label set of a job's targets - what actually ends up on the
# series. Distinct from prom_targets_for, whose output also contains
# discoveredLabels: every raw __meta_ label service discovery produced,
# including ones the relabel rules deliberately threw away. Asserting against
# the raw blob would make "you did not import pod_template_hash" impossible to
# ever satisfy, because __meta_kubernetes_pod_label_pod_template_hash is
# always in there.
prom_target_labels() {
  prom_targets | jq -c --arg job "$1" \
    '.data.activeTargets[] | select(.labels.job == $job) | .labels' 2>/dev/null
}

prom_target_count() {
  prom_targets | jq -r --arg job "$1" '[.data.activeTargets[] | select(.labels.job == $job)] | length' 2>/dev/null || echo 0
}

prom_healthy_target_count() {
  prom_targets | jq -r --arg job "$1" \
    '[.data.activeTargets[] | select(.labels.job == $job and .health == "up")] | length' 2>/dev/null || echo 0
}

# The config Prometheus is actually running, not the file on disk.
prom_running_config() {
  curl -sS --max-time 15 "${PROM_URL}/api/v1/status/config" 2>/dev/null | jq -r '.data.yaml // ""'
}

# Like prom_scalar, but waits for the query to actually have an answer.
#
# `make apply` restarts Prometheus, which resets its in-memory series. A
# rate() over a 2 minute window has nothing to compute from until two minutes
# of samples exist, and returns empty rather than zero. A learner running
# `make test` straight after `make apply` would otherwise see a spurious
# failure with no explanation.
prom_scalar_ready() {
  local query="$1" timeout="${2:-180}"
  local deadline=$(( $(date +%s) + timeout ))
  local v
  while :; do
    v="$(prom_scalar "${query}")"
    if [[ -n "${v}" && "${v}" != "NaN" ]]; then
      printf '%s' "${v}"
      return 0
    fi
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      printf ''
      return 1
    fi
    sleep 10
  done
}

# Poll a count()-style query until it drops to or below <max>.
#
# `make apply` restarts Prometheus, but series scraped under the OLD config
# stay inside the staleness window for a few minutes, so any "is it smaller
# now" assertion sampled once right after an edit sees old + new added
# together. Every such assertion in this suite polls instead.
wait_for_count_le() {
  local query="$1" max="$2" timeout="${3:-180}"
  local deadline=$(( $(date +%s) + timeout ))
  local v
  while :; do
    v="$(prom_count_scalar "${query}")"
    [[ "${v%%.*}" -le "${max}" ]] && { printf '%s' "${v}"; return 0; }
    [[ "$(date +%s)" -ge "${deadline}" ]] && { printf '%s' "${v}"; return 1; }
    sleep 10
  done
}

# Is remote write actually delivering right now?
#
# NOT prometheus_remote_storage_samples_failed_total. Measured during the
# superdemo retarget: with the credentials file missing, that counter stayed
# at 0 through 150,573 retries, because a retryable error never increments it.
# The signals that move are samples_retried_total and, most directly,
# queue_highest_sent_timestamp_seconds - the newest sample timestamp sent.
# It also advances when a batch is rejected (chapter 02's 401 case), so pair it
# with the failure counter: `time() - that` plus the failure rate is the alert
# to run in production.
remote_write_lag_seconds() {
  prom_count_scalar 'time() - max(prometheus_remote_storage_queue_highest_sent_timestamp_seconds)'
}

# Name the failure mode instead of making the learner wait out every timeout.
#
# Both modes are diagnosable in one scrape interval, so there is no reason a
# broken pipeline should take twelve minutes of polling to report - and the
# diagnosis IS chapter 02's lesson, so printing it is teaching, not just
# tooling.
remote_write_diagnosis() {
  local failed retried lag
  failed="$(prom_count_scalar 'sum(rate(prometheus_remote_storage_samples_failed_total[1m]))')"
  retried="$(prom_count_scalar 'sum(rate(prometheus_remote_storage_samples_retried_total[1m]))')"
  lag="$(remote_write_lag_seconds)"

  if [[ "${failed%%.*}" =~ ^[0-9]+$ ]] && [[ "${failed%%.*}" -ge 1 ]]; then
    printf 'samples are being REJECTED (non-recoverable, e.g. 401/400). Note that\n       queue_highest_sent_timestamp still advances - check the logs:\n       kubectl -n %s logs deploy/prometheus | grep -i non-recoverable' "${PROM_NAMESPACE}"
    return 0
  fi
  if [[ "${retried%%.*}" =~ ^[0-9]+$ ]] && [[ "${retried%%.*}" -ge 1 ]]; then
    printf 'stuck in a RETRY loop (retryable error - missing credentials file, DNS,\n       503). samples_failed_total stays 0 for this, which is the trap.'
    return 0
  fi
  if [[ "${lag%%.*}" =~ ^-?[0-9]+$ ]] && [[ "${lag%%.*}" -ge 120 ]]; then
    printf 'nothing has been delivered for %ss.' "${lag%%.*}"
    return 0
  fi
  printf 'no remote_write activity at all - is the block present and applied?'
}

# Remote write is delivering only if BOTH questions agree, because the two
# failure modes are exactly complementary and each one leaves the other's
# metric looking healthy. Measured, on this course's own stack:
#
#                                  no auth block   credentials_file missing
#   Elasticsearch says             401             (request never completes)
#   Prometheus classifies it       non-recoverable retryable
#   samples_failed_total           2512            0          <- looks healthy
#   samples_retried_total          0               11860
#   queue_highest_sent_timestamp   advancing       0
#                                  ^ looks healthy
#
# Checking the timestamp alone passes with 100% of samples being rejected.
# Checking failures alone passes with nothing ever sent. Ask both.
remote_write_delivering() {
  local lag; lag="$(remote_write_lag_seconds)"
  [[ "${lag%%.*}" =~ ^-?[0-9]+$ ]] || return 1
  [[ "${lag%%.*}" -lt 120 ]] || return 1

  local bad
  bad="$(prom_count_scalar 'sum(rate(prometheus_remote_storage_samples_failed_total[1m])) + sum(rate(prometheus_remote_storage_samples_retried_total[1m]))')"
  # Grade the RATE, not the total: a retried batch can produce a one-time
  # burst of TSDS version conflicts, and the total stays raised afterwards.
  [[ "${bad%%.*}" =~ ^-?[0-9]+$ ]] || return 0
  [[ "${bad%%.*}" -lt 1 ]]
}

# Wait until a job has at least N healthy targets. Scrapes are on a 15s
# interval and a freshly restarted Prometheus reports health "unknown" until
# the first one lands, so every target assertion needs this.
wait_for_healthy_targets() {
  local job="$1" want="$2" timeout="${3:-90}"
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    [[ "$(prom_healthy_target_count "${job}")" -ge "${want}" ]] && return 0
    [[ "$(date +%s)" -ge "${deadline}" ]] && return 1
    sleep 5
  done
}
