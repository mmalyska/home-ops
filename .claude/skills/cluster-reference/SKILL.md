---
name: cluster-reference
description: >
  Reference for cluster infrastructure components, Talos configuration, network
  topology, and auto-managed files. Use when querying component roles, versions,
  IPs, or understanding what files must not be manually edited.
when_to_use: >
  Trigger phrases: "talos", "upgrade", "which version", "infrastructure", "what does X do",
  "network", "IP pool", "LB IP", "egctl", "renovate", "extensions", "do not edit",
  "clusterconfig", "component".
---

# Cluster Reference

## Core Infrastructure

| Component | Purpose |
|-----------|---------|
| **Cilium** | CNI, kube-proxy replacement, L2 announcements for LoadBalancer IPs |
| **Envoy Gateway** | Kubernetes Gateway API — `envoy-external` (.20, internet via Cloudflare Tunnel) and `envoy-internal` (.21, home network only) |
| **Cloudflared** | Cloudflare Tunnel client |
| **external-dns (cloudflare)** | Publishes `controller: external` DNSEndpoints and `dns-controller` HTTPRoutes on `envoy-external` |
| **external-dns (adguard)** | Publishes `controller: internal` DNSEndpoints and `dns-controller` HTTPRoutes on `envoy-internal` |
| **cert-manager** | TLS via Cloudflare DNS01; wildcard `cert-production` used by both gateways |
| **Rook-Ceph** | Primary persistent storage |
| **NFS subdir provisioner** | Cold storage on QNAP NAS |
| **Keycloak** | OIDC identity provider |
| **External Secrets Operator** | K8s secret sync from Bitwarden |
| **kube-prometheus-stack** | Prometheus + Grafana |
| **CloudNative-PG** | PostgreSQL operator |
| **VolSync** | PVC backup/restore |

For egctl debugging commands, see `@docs/src/k8s/egctl.md`.

## Talos Configuration

- Managed with `talosctl` + `envsubst` from `provision/talos/templates/` and `provision/talos/nodes/`
- Node index: `provision/talos/nodes.yaml`; generate: `task talos:generate`
- Current versions: Talos v1.12.7, Kubernetes v1.35.5 (updated by Renovate)
- 3 control plane nodes (scheduling enabled on control plane, no dedicated workers)
- Custom extensions: `siderolabs/i915`, `siderolabs/intel-ucode`, `siderolabs/nut-client`
- OIDC on kube-apiserver pointing to Keycloak

## Network Topology

Node subnet: `192.168.48.0/22` · Pod network: `10.244.0.0/16` · Service network: `10.96.0.0/12`
LB IP pool: `192.168.48.20–50` (annotate new services with `lbipam.cilium.io/ips: "192.168.48.XX"`)

Full IP allocation and gateway architecture: `@docs/src/general/network.md`.

## Do Not Edit (Generated/Auto-managed Files)

| File/Directory | Managed By | How to Update |
|----------------|-----------|---------------|
| `provision/talos/clusterconfig/` | `talosctl` + `envsubst` | `task talos:generate` |
| Lines prefixed `# renovate: datasource=...` | Renovate bot | Do not manually bump |
| `.terraform.lock.hcl` | Terraform | `task terraform:init:cloudflare` |
