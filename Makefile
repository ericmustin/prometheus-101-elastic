.DEFAULT_GOAL := help
SHELL := /bin/bash

# `make chapter 3` and `make catchup 3` take a bare number. Swallow it so make
# does not try to build "3" as a target of its own.
ifneq (,$(filter chapter catchup,$(firstword $(MAKECMDGOALS))))
  CHAPTER_ARG := $(wordlist 2,2,$(MAKECMDGOALS))
  $(eval $(CHAPTER_ARG):;@:)
endif

.PHONY: help setup check apply test goals hint answer chapter catchup status \
        ksm collector grafana links import \
        esql logs clean

help:
	@echo "Prometheus 101 - seven chapters"
	@echo
	@echo "  make setup          build the cluster, the trading app, and Prometheus"
	@echo "  make check          is this machine ready? (Gate 0)"
	@echo
	@echo "  make apply          push your prometheus.yml into the cluster"
	@echo "  make goals          what this chapter asks of you (checks once, no waiting)"
	@echo "  make test           grade the chapter you are on"
	@echo "  make hint           what is still different from the solution"
	@echo "  make answer         the change this chapter is asking for"
	@echo
	@echo "  make chapter 3      start chapter 3"
	@echo "  make catchup 4      behind? start chapter 4 with the cluster caught up"
	@echo "  make status         which chapter am I on? am I ready for the session?"
	@echo
	@echo "  make ksm            chapter 04: install kube-state-metrics"
	@echo "  make collector      chapter 05: deploy the EDOT collector"
	@echo "  make grafana        chapter 07: add Grafana's Elastic datasource"
	@echo "  make links          chapter 02+: this chapter's queries, ready to paste in Kibana"
	@echo "  make links ALL=1    ...every chapter's"
	@echo "  make import         chapter 07: import superdemo's saved search"
	@echo
	@echo "  make esql Q=queries/esql/03-requests-by-region.esql"
	@echo "  make logs           Prometheus pod logs"
	@echo "  make clean          delete the cluster"

setup:      ; @scripts/setup.sh
check:      ; @scripts/check-env.sh
apply:      ; @scripts/apply-config.sh
test:       ; @test/run.sh
goals:      ; @GRADE_QUICK=1 test/run.sh || true
hint:       ; @scripts/chapter.sh hint
answer:     ; @scripts/chapter.sh answer
status:     ; @scripts/chapter.sh status
chapter:    ; @scripts/chapter.sh $(CHAPTER_ARG)
catchup:    ; @scripts/chapter.sh catchup $(CHAPTER_ARG)

ksm:        ; @utils/ksm/ksm.sh
collector:  ; @./build.sh -o local
grafana:    ; @./build.sh -g elastic
links:      ; @ALL="$(ALL)" scripts/kibana.sh links
import:     ; @scripts/kibana.sh import

esql:
	@test -n "$(Q)" || { echo "Usage: make esql Q=queries/esql/<file>.esql"; exit 1; }
	@scripts/esql.sh $(Q)

logs:       ; @kubectl -n infra logs deploy/prometheus --tail=80
clean:      ; @scripts/teardown.sh
