---
name: loki-log-queries
description: >
  Pattern for querying Grafana Loki via port-forward + the LogQL HTTP API —
  cross-namespace error sweeps, aggregate-first querying to avoid gRPC
  message-size limits, and known false-positive traps in this cluster's logs.
when_to_use: >
  Trigger phrases: "check logs", "check error logs", "any errors in the
  logs", "log audit", "logql", "loki query", "search logs across
  namespaces", "new problems not visible without logs".
---

# Loki Log Queries

**Extracted:** 2026-07-28
**Context:** First cross-cluster log audit after deploying centralized
logging (Loki + Grafana Alloy) — found a real bug (CNPG metrics-exporter
permission error, invisible for who knows how long) and several
false-positive traps worth recording so future audits don't re-walk them.

## Port-Forward Lifecycle

Same rule as `prometheus-portforward-session`: each Bash tool call is a
separate shell, so `kill %1` silently does nothing in a later call. Use
`pkill -f`.

```bash
kubectl -n monitoring port-forward svc/loki 3100:3100 > /tmp/loki-pf.log 2>&1 &
disown
sleep 2
curl -s http://localhost:3100/ready   # expect: ready

# ... queries ...

pkill -f "port-forward.*loki"; true   # exits 144 — normal, not an error
```

## Discover What's There First

```bash
curl -s "http://localhost:3100/loki/api/v1/label/namespace/values" | python3 -m json.tool
```

## Aggregate First, Then Drill Down — Never Start With Raw Lines

A broad line-filter query that returns raw matching lines across many
namespaces can blow the gRPC message-size limit:

```
rpc error: code = ResourceExhausted desc = trying to send message larger than max (5892943 vs. 4194304)
```

This is especially easy to hit in this cluster because rook-ceph's `mgr`
container emits huge (100s of KB) DEBUG-level lines (see
`docs/superpowers/specs/2026-07-27-logging-design.md` / `fix/loki-max-line-size-ceph-mgr`
— `max_line_size` was raised to 1MB specifically because of these).

**Step 1 — count matches per namespace/container, not raw lines:**

```bash
curl -s "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum by (namespace) (count_over_time({namespace=~".+"} |~ "(?i)panic|fatal|exception|traceback|refused|timeout|unauthorized|forbidden" [3h]))' \
  --data-urlencode 'time='$(date +%s) \
  | python3 -c "
import json,sys
d = json.load(sys.stdin)
for r in sorted(d['data']['result'], key=lambda x: -int(x['value'][1])):
    print(r['metric'], r['value'][1])
"
```

**Step 2 — for any namespace that's a clear outlier, narrow by container**
before pulling any raw text, same `count_over_time` pattern with
`sum by (container)`.

**Step 3 — only then pull a handful of raw sample lines**, with a short
time window (minutes, not hours) and a small `limit`:

```bash
curl -s -G "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="NS", container="C"} |~ "(?i)PATTERN"' \
  --data-urlencode "start=$(( $(date +%s) - 120 ))000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=5' \
  --data-urlencode 'direction=backward'
```

## Known False-Positive Traps

Confirmed while auditing this cluster — check the actual sample lines
before reporting a namespace as having a "problem," not just the count:

| Symptom | Reality |
|---|---|
| `rook-ceph` / `mgr` container has a high match count for "timeout" | Ceph mgr's Kubernetes-orchestrator module dumps huge DEBUG-level `PodList` JSON blobs; "timeout" matches a substring inside pod-spec JSON (e.g. `timeoutSeconds`), not an actual timeout event. |
| `monitoring` namespace matches your own search keywords | Loki logs its own query execution (`msg="executing query" query="..."`), so a broad sweep re-matches its own prior query text. Self-referential, not a real finding. |
| A namespace's count drops to ~0 once you remove "timeout" from the pattern | That namespace's whole "problem" was benign operational timeout chatter, not errors — always re-check with a narrower keyword set before concluding something is broken. |

## Structured (JSON) Logs

Fields like `.msg`/`.err`/`.level` are **not** usable in `line_format`
until you parse the line first:

```logql
{namespace="nextcloud", container="postgres"} | json | line_format "{{.msg}}: {{.error}}"
```

Without the `| json` stage, `{{.msg}}` renders empty even though the line
is valid JSON.

## Grafana Explore Equivalent

Everything above has a UI equivalent in Grafana → Explore → Loki
datasource, using the same LogQL. Prefer the API/curl approach in an
agent session (scriptable, no manual navigation); point the user at
Explore when they want to look themselves.

## When to Use

Any time you need to sweep cluster logs for problems, investigate a
specific namespace/pod's error history, or verify a fix actually stopped
an error from recurring. Also load before/during `cluster-audit` (see
that skill's Query Sequence for where this slots in).
