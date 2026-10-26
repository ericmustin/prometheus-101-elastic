# Chapter 05: the collector is another scrape target.
if ! kubectl -n infra get deploy otel-collector >/dev/null 2>&1; then
  fail "the EDOT collector is deployed" "run: make collector"
else
  pass "the EDOT collector is deployed"

  # A pull reader gives the collector a Prometheus endpoint for its own
  # metrics, and chapter 03's rules find it by its annotations.
  wait_for_healthy_targets kubernetes-pods 3 180 || true
  coll="$(prom_targets | jq -r \
    '[.data.activeTargets[] | select(.labels.service == "otel-collector" and .health == "up")] | length' 2>/dev/null || echo 0)"
  assert_ge "${coll}" 1 \
    "the collector was discovered by the SAME annotation rules, with no config change"

  span_metrics_present() { [[ "$(prom_count 'otelcol_process_uptime')" -ge 1 ]]; }
  retry_until 240 "otelcol_* self-telemetry is being scraped" span_metrics_present

  # The four that tell you where telemetry is being lost. Note the last one is
  # created lazily - it does not exist until something actually fails, which
  # is itself worth knowing.
  assert_ge "$(prom_count 'otelcol_receiver_accepted_metric_points')" 1 \
    "receiver: otelcol_receiver_accepted_metric_points"
  assert_ge "$(prom_count 'otelcol_exporter_sent_metric_points')" 1 \
    "exporter: otelcol_exporter_sent_metric_points"
  assert_ge "$(prom_count 'otelcol_process_memory_rss')" 1 \
    "process: otelcol_process_memory_rss"

  # It is not just up - it is moving data.
  accepted="$(prom_count_scalar 'sum(otelcol_receiver_accepted_metric_points)')"
  assert_ge "${accepted}" 1 "the collector is actually accepting metric points (${accepted%%.*})"
fi
