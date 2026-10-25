# Chapter 01: Prometheus scrapes itself.
wait_for_healthy_targets prometheus 1 90 || true
assert_ge "$(prom_target_count prometheus)"         1 "a job named 'prometheus' has a target"
assert_ge "$(prom_healthy_target_count prometheus)" 1 "that target is healthy (up)"
# A config can parse and a target can be listed without a sample ever being
# stored. This is the assertion that says collection is real.
assert_ge "$(prom_count 'prometheus_build_info')"   1 "samples are landing in the local TSDB"
