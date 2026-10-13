---
name: prometheus-portforward-session
description: >
  Protocol for managing kubectl port-forward to Prometheus across multiple
  Bash tool calls in Claude Code. Use pkill -f instead of kill %1 — job
  control does not work across separate shell invocations.
when_to_use: >
  Use whenever running kubectl port-forward to Prometheus and making multiple
  Bash tool calls in the same session.
user-invocable: false
---

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
- **`pkill -f` can kill its own shell.** The pattern also matches the Bash tool's own command line, so
  `pkill -f "port-forward.*prometheus"` inside a longer script terminates the script (exit 144) before the
  commands after it run. Either run the `pkill` in its own Bash call, or use a bracket pattern that does not
  match its own text: `pkill -f "[p]ort-forward.*prometheus"`
- Start the forward with `> /dev/null 2>&1 &` then `disown`, so the call returns immediately and the process
  survives the shell. Check readiness with `curl -s localhost:9090/-/ready` instead of a blind `sleep`

## What NOT to do

```bash
# WRONG — kill %1 has no jobs in a new shell
kill %1 2>/dev/null   # silently fails, port stays bound
```

## When to Use

Any Claude Code session querying Prometheus via port-forward across multiple Bash tool calls.
