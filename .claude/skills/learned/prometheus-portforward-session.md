# Prometheus Port-Forward: Correct Lifecycle Across Bash Tool Calls

**Extracted:** 2026-03-23
**Context:** Running Prometheus port-forwards across multiple Bash tool calls in Claude Code

## Root Cause

Each Bash tool call runs in a **separate shell process**. Job control (`kill %1`) only works within the same shell that started the job. When `kill %1` runs in a subsequent Bash call, it has no jobs — it silently fails, leaving the port-forward process alive and the port bound.

This is why we thought port reuse was impossible — the port was actually never released.

## Solution

Use `pkill -f` to kill by process name, which works across shell invocations:

```bash
# Start port-forward (any Bash call)
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=<promql>'

# Kill in same OR different Bash call — pkill works across shells
pkill -f "port-forward.*prometheus"
sleep 1
```

Port 9090 **can be reused** immediately after `pkill` + 1s wait. No need to increment ports.

## Notes

- `pkill` exits with code 144 (SIGTERM sent) — this is normal, not an error
- Don't use `&&` after `pkill` — the non-zero exit will break the chain. Use separate Bash calls or `; true`
- `sleep 1` after pkill is enough for the port to be released

## What NOT to do

```bash
# WRONG — kill %1 has no jobs in a new shell
kill %1 2>/dev/null   # silently fails, port stays bound
```

## When to Use

Any Claude Code session querying Prometheus via port-forward across multiple Bash tool calls.
