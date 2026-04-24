---
name: Deployment strategy RollingUpdate→Recreate requires live object patch
description: ArgoCD SSA dry-run fails when switching strategy; must kubectl patch the live object first
type: feedback
---

ArgoCD SSA dry-run fails with `rollingUpdate: Forbidden` when switching from RollingUpdate to Recreate because the live object still has rollingUpdate fields.

Fix: `kubectl patch deployment <name> -n <ns> --type=json -p='[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'` before ArgoCD sync.

**Why:** Kubernetes validates the merged SSA payload before processing null removals, so the forbidden field is still present in the merge result.

**How to apply:** Whenever changing Deployment strategy type in values.yaml, patch the live object first, then sync.
