---
name: grafana-no-anonymous-access
description: "Grafana must always require login — no anonymous/unauthenticated access, even LAN-only"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 5b71e0e2-3330-48c4-a372-f1226cef1e5a
  modified: 2026-08-14T15:30:05.447Z
---

Grafana (`cluster/apps/system/prometheus-stack/values.yaml`) must have `auth.anonymous.enabled: false`. Never re-enable anonymous Viewer access, even though the Grafana route only resolves via `envoy-internal` (LAN-only, not internet-facing via Cloudflare tunnel — see [[reference_gateway_dns_architecture]]).

**Why:** Discovered 2026-08-14 that anonymous access had been enabled (`org_role: Viewer`), letting anyone on the home network view all dashboards without login, and likely run ad-hoc PromQL/LogQL via Grafana Explore (Viewer role has Explore access by default) against every configured datasource. User's explicit call: "It should be all private behind login and password" — no exception for LAN-only reachability.

**How to apply:** If asked to add convenience features (kiosk display, dashboard TV mode, phone widget, etc.) that seem to need anonymous access, don't re-enable `auth.anonymous`. Propose an alternative instead (e.g. a scoped API key / service account token embedded in the kiosk client, or a signed public dashboard link for the single dashboard needed) and confirm with the user before implementing.

Admin login credentials already exist in the auto-generated `prometheus-stack-grafana` Secret (created by the kube-prometheus-stack Grafana subchart) — no new secret was needed when anonymous access was disabled.
