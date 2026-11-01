---
name: prometheus-historical-queries
description: >
  Pattern for Prometheus point-in-time historical queries using the instant
  query endpoint with ?time=<epoch>. Use when comparing metrics now vs N days
  ago, or when avg_over_time / subquery approaches fail.
when_to_use: >
  Trigger phrases: "prometheus", "metrics comparison", "7 days ago",
  "historical query", "now vs last week", "promql over time".
---

# Prometheus Historical Point-in-Time Queries

**Extracted:** 2026-03-23
**Context:** Comparing current metrics to a past snapshot in Prometheus

## Prerequisite: Port-Forward

This assumes a port-forward to Prometheus is already up. Use the correct
service name — `prometheus-stack-kube-prom-prometheus`, not the more
guessable `kube-prometheus-stack-prometheus` — and see
`prometheus-portforward-session` for the correct lifecycle across multiple
Bash tool calls (`pkill -f`, not `kill %1`).

```bash
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
sleep 3
```

## Problem
`avg_over_time(metric[7d])` often returns errors or misleading values
(e.g., when exporters have gaps, counters reset, or subquery syntax is rejected
by the Prometheus version in use).

## Solution
Use the instant query endpoint with a `?time=<epoch>` parameter to snapshot
metric values at a specific past moment:

```bash
WEEK_AGO=$(date -d '7 days ago' +%s)
curl -s "http://localhost:9090/api/v1/query?time=${WEEK_AGO}" \
  --data-urlencode 'query=<your_promql>'
```

Then compare that snapshot against the current instant query (no `?time=`).

## When to Use
Any time you need "now vs N days ago" comparisons in Prometheus.
Prefer this over range functions when the metric has resets or sparse coverage.

## Gotcha: group by a stable label, expect gaps in instant samples

- Series identity is the full label set. `instance` (pod IP:port) and `pod` change when an exporter pod restarts, so the same
  disk appears as several series. Group by a label that survives restarts: `max by (node, device) (...)` for the smartctl
  exporter (`node` comes from the ServiceMonitor relabeling).
- An instant `?time=` sample can land exactly in a scrape gap (a short hole existed on 2026-10-09 for every node) and return
  nothing for some series. If a node is missing, retry at a few hours either side or use `query_range` (`step=3600`) before
  concluding there is no history.
- cAdvisor `container_*` counters (`container_fs_writes_bytes_total`, `container_network_*`) also have a pod-level series with
  `container=""` that equals the sum of the containers. Select `container!=""` or one `container="..."` for per-workload
  rates, or the result is exactly 2x (seen 2026-10-23: Prometheus 0.17 against the real 0.086 MB/s).
- Per-node deltas over days: `query_range` of `max by (node, device) (metric)` and subtract the first value from the last.
