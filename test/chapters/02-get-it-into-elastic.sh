# Chapter 02: metrics leave the cluster for Elastic, on superdemo's endpoint.
if ! es_available; then
  log_warn "Skipping chapter 02 - ELASTIC_ES_URL / ELASTIC_API_KEY / DATA_STREAM not all set."
else

assert_contains "$(prom_running_config)" 'remote_write' \
  "the running config has a remote_write block"
# superdemo inlines the key as `credentials:`. This config becomes a ConfigMap,
# and a ConfigMap is plaintext to anyone who can run kubectl.
assert_contains "$(prom_running_config)" 'credentials_file' \
  "the API key is read from a file, not pasted into the config"

# Delivery. Both questions, because each failure mode hides from the other's
# metric - see the table in test/lib/prom.sh, measured on this stack.
if retry_until 240 "remote write is delivering (nothing failing, nothing retrying, sent recently)" remote_write_delivering; then
  rw_ok=1
else
  rw_ok=0
  log_hint "$(remote_write_diagnosis)"
fi

# No point spending another eight minutes polling Elastic for data that
# provably is not being sent. Say so now, with the reason.
if [[ "${rw_ok}" -eq 0 ]]; then
  fail "data is queryable in ${DATA_STREAM}" "skipped - remote write is not delivering"
  fail "documents carry labels.cluster from external_labels" "skipped - remote write is not delivering"
else

# 2 minutes, not 5: a wider window still holds data written before you came
# back to this chapter, so it would pass with remote write switched off.
if wait_for_docs "metrics.up" 1 "now-2m" 300; then
  pass "data is queryable in ${DATA_STREAM}"
else
  fail "data is queryable in ${DATA_STREAM}" \
       "nothing arrived within 5 minutes - check the endpoint path and API key"
fi

# superdemo sets no external_labels at all, so everything it ships is
# anonymous once it lands. This is the assertion that says yours is not.
rows="$(wait_for_esql_rows "FROM ${DATA_STREAM} | WHERE @timestamp > NOW() - 2 minutes AND \`labels.cluster\` == \"prometheus-101\" | LIMIT 1")"
assert_ge "${rows}" 1 "documents carry labels.cluster from external_labels"

fi   # rw_ok

fi   # es_available
