# Chapter 07: point Grafana at Elastic and change nothing else.
if ! kubectl -n infra get deploy grafana >/dev/null 2>&1; then
  fail "Grafana is deployed" "run: make grafana"
else
  pass "Grafana is deployed"

  ds="$(curl -sS --max-time 20 "${GRAFANA_URL}/api/datasources" 2>/dev/null || echo '[]')"
  n="$(printf '%s' "${ds}" | jq -r 'length' 2>/dev/null || echo 0)"
  assert_ge "${n}" 2 "Grafana has two datasources, as superdemo provisions"

  # Both are type: prometheus. That IS the demo - Elastic's read endpoint
  # speaks the Prometheus HTTP API, so nothing above the datasource changes.
  proms="$(printf '%s' "${ds}" | jq -r '[.[] | select(.type == "prometheus")] | length' 2>/dev/null || echo 0)"
  assert_ge "${proms}" 2 "both datasources are type: prometheus"

  elastic_ds="$(printf '%s' "${ds}" | jq -r '[.[] | select(.url | test("_prometheus"))] | length' 2>/dev/null || echo 0)"
  assert_ge "${elastic_ds}" 1 "one of them points at Elasticsearch's _prometheus read endpoint"

  # Prove it answers, rather than merely being configured. Query through
  # Grafana's proxy so this tests the whole path a dashboard would use.
  uid="$(printf '%s' "${ds}" | jq -r '.[] | select(.url | test("_prometheus")) | .uid' 2>/dev/null | head -1)"
  if [[ -n "${uid}" ]]; then
    body="$(curl -sS --max-time 30 --get \
      --data-urlencode 'query=up' \
      "${GRAFANA_URL}/api/datasources/proxy/uid/${uid}/api/v1/query" 2>/dev/null || echo '')"
    st="$(printf '%s' "${body}" | jq -r '.status // "none"' 2>/dev/null)"
    if [[ "${st}" == "success" ]]; then
      pass "the Elastic datasource answers a PromQL query through Grafana"
    else
      fail "the Elastic datasource answers a PromQL query through Grafana" \
           "got status='${st}' - check the API key header on the datasource"
    fi
  fi
fi
