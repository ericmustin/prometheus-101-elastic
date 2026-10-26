# Chapter 04: kube-state-metrics, the cluster's state as metrics, in a job of its own.
if ! kubectl -n kube-system get deploy kube-state-metrics >/dev/null 2>&1; then
  fail "kube-state-metrics is installed" "run: make ksm"
else
  pass "kube-state-metrics is installed"

  # The chart annotates the SERVICE, not the pod - verified against
  # prometheus-community/kube-state-metrics. So chapter 03's annotation rules
  # cannot find it, and it needs a job of its own. That is the whole lesson.
  ksm_pod_annotated="$(kubectl -n kube-system get pod -l app.kubernetes.io/name=kube-state-metrics \
    -o json 2>/dev/null | jq -r '[.items[0].metadata.annotations // {} | keys[] | select(test("prometheus"))] | length' 2>/dev/null || echo 0)"
  assert_eq "${ksm_pod_annotated}" "0" \
    "the KSM pod carries no scrape annotation, which is why it needs naming"

  wait_for_healthy_targets kube-state-metrics 1 180 || true
  assert_ge "$(prom_healthy_target_count kube-state-metrics)" 1 \
    "the kube-state-metrics job has a healthy target"

  assert_ge "$(prom_count 'kube_pod_status_phase')"   1 "kube_pod_status_phase is collected"
  assert_ge "$(prom_count 'kube_deployment_status_replicas')" 1 "deployment replica state is collected"

  # It can answer a real question about the cluster, not just exist.
  running="$(prom_count_scalar 'sum(kube_pod_status_phase{phase="Running"})')"
  assert_ge "${running}" 1 "it can count running pods (${running%%.*})"

  if es_available; then
    if wait_for_docs "metrics.kube_pod_status_phase" 1 "now-2m" 300; then
      pass "cluster-state metrics reached Elastic alongside the application's"
    else
      fail "cluster-state metrics reached Elastic" "check remote write health"
    fi
  fi
fi
