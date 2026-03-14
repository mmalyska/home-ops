---
name: Gateway and DNS architecture gotchas
description: Two-tier external-dns annotation system and the dns-controller hardcoded requirement for HTTPRoutes
type: project
---

Two Envoy Gateway instances: `envoy-external` (.20, internet via Cloudflare Tunnel), `envoy-internal` (.21, AdGuard Home).

**Annotation rule** (`external-dns.alpha.kubernetes.io/controller`):

| Value | Used on | Processed by |
|-------|---------|-------------|
| `dns-controller` | HTTPRoutes | adguard or cloudflare — determined by which gateway the route attaches to |
| `internal` | DNSEndpoints only | adguard-dns |
| `external` | DNSEndpoints only | cloudflare-dns |

**Critical gotcha**: external-dns `gateway-httproute` source (v0.20.0) has a hardcoded check requiring `controller: dns-controller` on HTTPRoutes. Using `internal` or `external` on HTTPRoutes causes them to be silently skipped.

**Annotation filters on the external-dns deployments:**
- `adguard-dns`: `controller in (internal,dns-controller)`
- `cloudflare-dns`: `controller in (external,dns-controller)`

**Static DNSEndpoints** in `cluster/apps/system/adguard-dns/templates/dnsendpoints.yaml`:
- `k8s.` → 192.168.48.1, `qnap.` → 192.168.50.8
- `argocd.` → 192.168.48.50 (temporary, Traefik — remove after ArgoCD migrated to envoy)
- `l.` → 192.168.48.50 (temporary, Keycloak — remove after Keycloak migrated to envoy)

**Key files:**
- `cluster/apps/system/envoy-gateweay/` (typo in dir name) — GatewayClass, Gateways, policies
- `cluster/apps/system/cloudflare-dns/` and `cluster/apps/system/adguard-dns/`
