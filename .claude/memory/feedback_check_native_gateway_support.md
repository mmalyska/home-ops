---
name: Check native Gateway API support before adding manual HTTPRoute
description: Always inspect the upstream Helm chart for native Gateway API / HTTPRoute support before creating a manual templates/httproute.yaml
type: feedback
---

Before creating a manual `templates/httproute.yaml` for any app migration, always check whether the upstream Helm chart already supports Gateway API natively.

**Why:** Several charts (rook-ceph-cluster v1.19.2, app-template v4+) have a `route:` or `routes:` values key that generates HTTPRoutes natively. Using the chart's native support is always cleaner than a manual template and avoids drift.

**How to apply:** When starting any app migration, run:
```sh
# Pull the chart and inspect values + templates
helm show values <repo>/<chart> --version <ver> | grep -A20 "^route\|^routes\|gateway\|HTTPRoute"
find /tmp/<chart>/templates -name "*.yaml" | xargs grep -l -i "httproute\|gateway"
```
Check BEFORE writing any manual template. If native support exists, use `route:` / `routes:` in `values.yaml` instead.

**Known charts with native Gateway API support:**
- `rook-ceph-cluster` (v1.19.2+) — `route.dashboard` key
- `bjw-s app-template` (v4+) — `route:` key per controller
