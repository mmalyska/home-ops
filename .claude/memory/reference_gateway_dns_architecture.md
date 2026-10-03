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

**Resolver chain (2026-10-03):** clients get AdGuard `192.168.48.25` / `.31` (in-cluster, app `adguard-home`); Talos nodes use `[.25, .31, .254]` (UCG-Max last, it knows no internal names and blocks nothing). CoreDNS is self-provisioned (Talos `cluster.coreDNS.disabled`, no Corefile customisation) as the `coredns` Argo app (upstream Helm chart) with `forward ... policy sequential`; it reads node resolvers only at pod start, so restart it after changing node nameservers. Deleting the coredns Deployment before its Argo app exists deadlocks ArgoCD. AdGuard also has IPv6 ULAs `fd80:c04a:5687:48::25` / `::31` on an IPv6-only macvlan (`vlan48-v6`). See [[coredns-argo-bootstrap-deadlock]].
