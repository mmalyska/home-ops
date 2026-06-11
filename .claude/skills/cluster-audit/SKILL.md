---
name: cluster-audit
description: Use when performing a periodic operational audit of the home Kubernetes cluster — health check, app-by-app resource review, PVC usage, deployment issues, or generating an audit report for history.
---

# Home Cluster Operational Audit

## Overview

Comprehensive audit using Prometheus + kubectl. Produces a per-app summary with resource sizing flags and action items, saved to `docs/src/audits/YYYY-MM-DD.md`.

**REQUIRED SUB-SKILLS:** Load these before starting:
- `prometheus-portforward-session` — port-forward lifecycle across Bash calls
- `prometheus-historical-queries` — point-in-time snapshots for trend comparison
- `node-disk-health` — disk topology, raw block device trap, and disk-specific queries

## Query Sequence

Run in this order (each informs the next):

### 1. Start Port-Forward

```bash
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
sleep 3
```

### 2. Active Alerts (read first — shapes focus areas)

```bash
curl -s 'http://localhost:9090/api/v1/alerts' | python3 -c "
import sys, json
d = json.load(sys.stdin)
alerts = d['data']['alerts']
for a in [x for x in alerts if x['state'] == 'firing']:
    print(f\"[{a['labels'].get('severity','?').upper()}] {a['labels'].get('alertname','')} ({a['labels'].get('namespace','')}) - {a.get('annotations',{}).get('summary','')}\")
"
```

> **Known false positive:** `KubeProxyDown` always fires on Talos+Cilium (no kube-proxy). Ignore it.

### 3. Node Health

```bash
# CPU utilization %
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)'

# Memory utilization %
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100'

# Network packet drops (flag if > 0)
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=irate(node_network_receive_drop_total{device!~"lo|veth.+|docker.+|flannel.+|cali.+|cilium.+|lxc.+"}[5m]) > 0'
```

### 4. Ceph Health

```bash
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=ceph_health_status'
# 0=OK, 1=WARN, 2=ERR
curl -s 'http://localhost:9090/api/v1/query' --data-urlencode 'query=ceph_osd_up'
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=ceph_cluster_total_used_bytes / ceph_cluster_total_bytes * 100'
```

### 5. PVC Usage (sort descending)

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes * 100' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = sorted([(float(r['value'][1]), r['metric'].get('namespace',''), r['metric'].get('persistentvolumeclaim','')) for r in d['data']['result']], reverse=True)
for pct, ns, pvc in rows:
    flag = ' *** CRITICAL' if pct > 90 else (' ** WARNING' if pct > 75 else (' (watch)' if pct > 50 else ''))
    print(f'{pct:5.1f}%  {ns}/{pvc}{flag}')
"
```

### 6. CPU Usage vs Requests Ratio (key signal for sizing)

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[10m])) / sum by (namespace) (kube_pod_container_resource_requests{resource="cpu", unit="core"})' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = sorted([(float(r['value'][1]), r['metric'].get('namespace','')) for r in d['data']['result']], reverse=True)
for v, ns in rows:
    flag = ' *** OVER REQUEST' if v > 1.0 else (' ** >50%' if v > 0.5 else ('  (idle)' if v < 0.05 else ''))
    print(f'{v*100:6.1f}%  {ns}{flag}')
"
```

> **Trap:** `kube-system` memory ratio can read 800%+ because apiserver/cilium have no limits set. This is expected — don't flag it.

### 7. Memory Usage vs Limits Ratio

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (namespace) (container_memory_working_set_bytes{container!="",container!="POD"}) / sum by (namespace) (kube_pod_container_resource_limits{resource="memory", unit="byte"})' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = sorted([(float(r['value'][1]), r['metric'].get('namespace','')) for r in d['data']['result']], reverse=True)
for v, ns in rows:
    flag = ' *** NEAR LIMIT' if v > 0.85 else (' ** >70%' if v > 0.7 else '')
    print(f'{v*100:6.1f}%  {ns}{flag}')
"
```

### 8. Historical Comparison (spikes vs trends)

For any namespace flagged in steps 6–7, compare to 7 days ago:

```bash
WEEK_AGO=$(date -d '7 days ago' +%s)
curl -s "http://localhost:9090/api/v1/query?time=${WEEK_AGO}" \
  --data-urlencode 'query=sum(rate(container_cpu_usage_seconds_total{namespace="TARGET_NS",container!=""}[10m])) * 1000'
```

A value near zero 7 days ago + high value now = spike (investigate). Consistent high = sizing issue.

### 9. Deployment Health (catch scaled-to-zero or unavailable)

```bash
# Deployments not at desired replicas
kubectl get deployments -A --no-headers | awk '$3 != $4 {print $1, $2, "desired="$3, "ready="$4}'

# Pods in non-Running state
kubectl get pods -A --no-headers | grep -v Running | grep -v Completed
```

> **Trap:** A namespace may have only database/cache pods (e.g. valkey, cnpg) while the app deployment is scaled to 0. Prometheus won't flag this — only kubectl will.

### 10. Top Consumers (for pod-level details)

```bash
# CPU top 20
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[10m])) * 1000'

# Memory top 20
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by (namespace, pod) (container_memory_working_set_bytes{container!=""}) / 1024 / 1024'
```

### 11. Cleanup

```bash
pkill -f "port-forward.*prometheus"; true
```

## Output Structure

Save to `docs/src/audits/YYYY-MM-DD.md` (use today's date). Structure:

```markdown
# Cluster Operational Audit — YYYY-MM-DD

## Cluster Health Overview
| Dimension | Status |
...

## Critical & Warning Issues
### 🔴 CRITICAL
### ⚠️ WARNING

## Per-App Summary
(grouped by category: Core Infrastructure / Monitoring / Storage / AI+HA / Default Apps / Games / Identity)

## Resource Sizing Recommendations
| App | Issue | Recommendation |

## Action Items
1. 🔴 ...
2. ⚠️ ...
3. ℹ️ ...
```

## Thresholds Reference

| Metric | Watch | Warning | Critical |
|--------|-------|---------|----------|
| PVC usage | >50% | >75% | >90% |
| CPU usage/request ratio | >50% | >100% (over request) | — |
| Memory usage/limit ratio | >70% | >85% | — |
| Node CPU | >50% | >75% | >90% |
| Node memory | >70% | >85% | >95% |
| Ceph cluster used | >60% | >75% | >85% |

## Common Traps

| Situation | Reality |
|-----------|---------|
| `kube-system` memory at 800%+ | Expected — apiserver/cilium have no memory limits. Not a problem. |
| `KubeProxyDown` alert firing | Expected on Talos+Cilium. Should be silenced. |
| CPU ratio missing for a namespace | Namespace has no CPU requests set — check with `kube_pod_container_resource_requests` |
| PVC not appearing | Volume provisioner not exposing kubelet stats; check with `kubectl get pvc -A` instead |
| hermes-agent CPU spikes | Check for PID collision in s6-supervise; compare to 7d ago value |
| App looks healthy in Prometheus | Deployment may be scaled to 0 — Prometheus has no data for absent pods. Always run step 9. |
