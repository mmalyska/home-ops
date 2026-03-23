# Prometheus Historical Point-in-Time Queries

**Extracted:** 2026-03-23
**Context:** Comparing current metrics to a past snapshot in Prometheus

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
