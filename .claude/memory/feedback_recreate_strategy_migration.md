---
name: Recreate strategy migration requires live object patch
description: When changing Deployment strategy from RollingUpdate to Recreate, manually remove rollingUpdate from the live object before ArgoCD sync
type: feedback
---

When changing a Deployment's `strategy.type` from `RollingUpdate` to `Recreate`, ArgoCD's server-side apply dry-run will fail with:

> `spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy 'type' is 'Recreate'`

This happens because the live object still has `rollingUpdate.maxSurge`/`maxUnavailable` fields from the previous strategy. SSA validates before it can clean up the old fields. Setting `rollingUpdate: null` in Helm values does not help — Kubernetes treats null as "specified".

**Fix:** manually patch the live Deployment to remove `rollingUpdate` first:

```sh
kubectl patch deployment <name> -n <namespace> --type=json \
  -p='[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
```

Then ArgoCD sync proceeds cleanly.

**Why:** Kubernetes validates the merged SSA payload before processing null removals. The live `rollingUpdate` fields must be explicitly removed via JSON patch before the strategy type change is applied.

**How to apply:** Any time a Deployment strategy is changed from RollingUpdate to Recreate in this repo, run the kubectl patch command against the live cluster before expecting ArgoCD to sync successfully.
