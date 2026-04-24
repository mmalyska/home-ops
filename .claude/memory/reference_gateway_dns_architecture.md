---
name: Gateway and DNS architecture
description: Two Envoy Gateway instances and annotation rules for external-dns
type: reference
---

Two Envoy Gateway instances:
- `envoy-external` (.20, internet via Cloudflare Tunnel)
- `envoy-internal` (.21, AdGuard Home)

**Annotation rule for `external-dns.alpha.kubernetes.io/controller`:**
- HTTPRoutes MUST use `dns-controller` (hardcoded check in gateway-httproute source v0.20.0 — using `internal`/`external` on HTTPRoutes causes silent skip)
- DNSEndpoints use `internal` (adguard) or `external` (cloudflare)

**Key files:**
- `cluster/apps/system/envoy-gateweay/` (note: typo in dir name)
- `cluster/apps/system/cloudflare-dns/`
- `cluster/apps/system/adguard-dns/`
