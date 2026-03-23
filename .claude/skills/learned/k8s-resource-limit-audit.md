# Kubernetes Container Resource Limit Audit via JSON

**Extracted:** 2026-03-23
**Context:** Auditing all pod resource requests/limits across the cluster

## Problem
Prometheus metric joins between `kube_pod_container_resource_limits` and
`container_cpu_usage_seconds_total` frequently return empty results due to
label cardinality differences (extra labels like `cpu`, `uid`, `node` cause
the vector match to fail silently).

## Solution
Parse `kubectl get pods -A -o json` directly in Python. This gives complete,
accurate data for every container without metric join issues:

```bash
kubectl get pods -A -o json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data['items']:
    if item.get('status',{}).get('phase') not in ('Running','Pending'): continue
    ns = item['metadata']['namespace']
    for c in item['spec'].get('containers',[]):
        lims = c.get('resources',{}).get('limits',{})
        reqs = c.get('resources',{}).get('requests',{})
        cpu_lim = lims.get('cpu','-')
        mem_lim = lims.get('memory','-')
        print(ns, c['name'], reqs.get('cpu','-'), cpu_lim, reqs.get('memory','-'), mem_lim)
"
```

Cross-reference with `kubectl top pods -A --containers` for actual usage.

## When to Use
Resource audits, capacity planning, finding containers without limits set.
Always prefer this over Prometheus label joins for limit data.
