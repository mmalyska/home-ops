#!/usr/bin/env bash
# wait-jobs.sh
# Part of the talos:wait_for_health gate: wait until no Job in the cluster is running (status.active is absent or 0),
# so a running backup still holds the gate. A Job that already failed (a CronJob keeps one failed Job) or is suspended
# does not: it can never become Complete, and waiting for it burned the whole timeout. Failed Jobs are listed as a
# warning. Same semantics as tuppr's "Jobs idle" check (docs/src/k8s/tuppr.md). Exit 1 when Jobs are still running
# after WAIT_JOBS_TIMEOUT seconds (default 300), or when the Jobs cannot be listed (an unreachable cluster is not "idle").
# Needs kubectl and jq. WAIT_JOBS_INTERVAL (default 10) is the poll interval in seconds.
set -euo pipefail

timeout="${WAIT_JOBS_TIMEOUT:-300}"
interval="${WAIT_JOBS_INTERVAL:-10}"
names='"\(.metadata.namespace)/\(.metadata.name)"'
deadline=$((SECONDS + timeout))
warned=0

while :; do
  jobs_json="$(kubectl get jobs --all-namespaces -o json)"
  if [ "$warned" -eq 0 ]; then
    failed="$(jq -r ".items[] | select(any(.status.conditions[]?; .type == \"Failed\" and .status == \"True\")) | $names" <<<"$jobs_json" | paste -sd' ' -)"
    [ -z "$failed" ] || echo "warning: failed Jobs are ignored by the gate: $failed" >&2
    warned=1
  fi
  running="$(jq -r ".items[] | select((.status.active // 0) > 0) | $names" <<<"$jobs_json" | paste -sd' ' -)"
  if [ -z "$running" ]; then
    echo "no Job is running"
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "error: Jobs still running after ${timeout}s: $running" >&2
    exit 1
  fi
  echo "waiting for running Jobs: $running"
  sleep "$interval"
done
