---
name: Check native Gateway API support before writing manual HTTPRoute
description: Run helm show values to check for built-in HTTPRoute support before creating templates/httproute.yaml
type: feedback
---

Run `helm show values <repo>/<chart> --version <ver> | grep -A20 route\|gateway\|HTTPRoute` before creating `templates/httproute.yaml`.

Known charts with native support:
- `rook-ceph-cluster` (v1.19.2+) — `route.dashboard` key
- `bjw-s app-template` (v4+) — `route:` key per controller

**Why:** Writing manual HTTPRoute templates duplicates what the chart already provides, and may conflict with chart-managed routes.

**How to apply:** Always check chart values for gateway/route support before hand-writing an HTTPRoute manifest.
