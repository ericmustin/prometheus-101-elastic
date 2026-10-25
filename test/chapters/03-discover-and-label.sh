# Chapter 03: superdemo's hardcoded hostnames become annotation discovery.
regions="$(echo "${REGION}" | tr ',' ' ')"
want_routers="$(echo "${regions}" | wc -w | tr -d ' ')"

wait_for_healthy_targets kubernetes-pods "${want_routers}" 180 || true

# The routers. superdemo's k8s/router.yaml has no prometheus.io/scrape
# annotation, so half of this chapter is adding it - the platform team cannot
# discover what the workload owner has not declared.
routers="$(prom_targets | jq -r \
  '[.data.activeTargets[] | select(.labels.service == "router" and .health == "up")] | length' 2>/dev/null || echo 0)"
assert_ge "${routers}" "${want_routers}" \
  "one healthy router target per region (${want_routers})"

assert_contains "$(prom_targets_for kubernetes-pods)" '__meta_kubernetes_pod_name' \
  "targets carry Kubernetes discovery metadata"

if kubectl get clusterrolebinding prometheus-101 >/dev/null 2>&1; then
  pass "the ClusterRoleBinding exists, so Prometheus may list pods"
else
  fail "the ClusterRoleBinding exists, so Prometheus may list pods" \
       "kubectl apply -f utils/prometheus-grafana/rbac.yml"
fi

down="$(prom_targets | jq -r '[.data.activeTargets[] | select(.health == "down")] | length' 2>/dev/null || echo 0)"
assert_eq "${down}" "0" "no target is down"

# THE assertion of this chapter. superdemo stamps labels: {namespace: 'infra'}
# on all three of its static targets, and two of them are not in infra. Real
# discovery gets it right per target.
ns_correct="$(prom_targets | jq -r \
  '[.data.activeTargets[] | select(.labels.service == "router")
    | select(.labels.namespace | startswith("trading-"))] | length' 2>/dev/null || echo 0)"
assert_ge "${ns_correct}" "${want_routers}" \
  "each router is labelled with its OWN namespace (superdemo labels all three 'infra')"

# The redis_exporter sidecar. Its annotations have been in superdemo's
# utils/redis/redis.yml since day one, doing nothing, because superdemo
# scrapes by hostname. Here they are what finds it - no extra config.
assert_ge "$(prom_count 'redis_up')" 1 \
  "the redis_exporter sidecar was found by the same rules, with no extra config"

# An absence check over nothing passes for the wrong reason, so establish that
# there ARE labels to look at before asserting what is not among them.
labels="$(prom_target_labels kubernetes-pods)"
if [[ -z "${labels}" ]]; then
  fail "pod_template_hash was NOT imported onto the series" \
    "the kubernetes-pods job has no targets, so there is nothing to check"
else
  assert_not_contains "${labels}" 'pod_template_hash' \
    "pod_template_hash was NOT imported onto the series"
fi

# superdemo's own metric names, in Prometheus.
assert_ge "$(prom_count 'transactions')"  1 "transactions is being collected"
assert_ge "$(prom_count 'shares_traded')" 1 "shares_traded is being collected"

if es_available; then
  # Two minutes, not ten. A ten-minute window still holds the finished
  # pipeline's data after you go back a chapter, so it passed at the chapter-02 state -
  # when no relabel rule had been written and nothing had ever set
  # labels.service. Narrow window, and poll for delivery.
  rows="$(wait_for_esql_rows "FROM ${DATA_STREAM} | WHERE @timestamp > NOW() - 2 minutes AND \`labels.service\` == \"router\" AND \`labels.namespace\` IS NOT NULL | LIMIT 1")"
  assert_ge "${rows}" 1 "Kubernetes context reached Elastic (labels.service, labels.namespace)"
fi
