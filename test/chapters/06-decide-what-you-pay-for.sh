# Chapter 06: two mechanisms, two different reasons.
if ! es_available; then
  log_warn "Skipping chapter 06 - Elastic is not configured."
else

# (a) Scrape-time allow list on kube-state-metrics. About 1,300 series on a
# 14-pod cluster, and it grows with the CLUSTER, not with your app.
if kubectl -n kube-system get deploy kube-state-metrics >/dev/null 2>&1; then
  budget=200
  if total="$(wait_for_count_le 'count(last_over_time({__name__=~"kube_.*"}[1m]))' "${budget}" 180)"; then
    pass "kube-state-metrics was trimmed (${total%%.*} live series, from about 1,300)"
  else
    fail "kube-state-metrics was trimmed" \
         "still ${total%%.*} live series after 3 minutes, wanted <= ${budget}"
  fi
  assert_ge "$(prom_count 'kube_pod_status_phase')" 1 \
    "...but the families you kept still answer questions"
fi

# (b) Write-boundary drops on the router's runtime internals. Still here
# locally - at 3am you want the last fifteen minutes of Node heap - and no
# longer paid for downstream.
assert_ge "$(prom_count 'nodejs_heap_size_total_bytes')" 1 \
  "nodejs_* is STILL in Prometheus (dropped at the sink, not the scrape)"

nodejs_gone() {
  local n; n="$(es_count_field 'metrics.nodejs_heap_size_total_bytes' 'now-60s')"
  [[ "${n}" =~ ^[0-9]+$ ]] && [[ "${n}" -eq 0 ]]
}
retry_until 240 "nodejs_* has STOPPED reaching Elastic" nodejs_gone

# Guards against an over-broad regex that drops everything.
assert_ge "$(es_count_field 'metrics.http_requests_total' 'now-90s')" 1 \
  "the application's own metrics are still landing"

fi
