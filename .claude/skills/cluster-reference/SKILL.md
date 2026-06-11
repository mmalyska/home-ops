---
name: cluster-reference
description: >
  Reference for cluster infrastructure components, Talos configuration, network
  topology, and auto-managed files. Use when querying component roles, versions,
  IPs, or understanding what files must not be manually edited.
when_to_use: >
  Trigger phrases: "talos", "upgrade", "which version", "infrastructure", "what does X do",
  "network", "IP pool", "LB IP", "egctl", "renovate", "extensions", "do not edit",
  "clusterconfig", "component", "shutdown node", "power off node", "bring node back", "node maintenance".
---

# Cluster Reference

## Core Infrastructure

| Component | Purpose |
| --- | --- |
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
- **To make config changes**: use the `talos-config-editing` skill — it has the edit decision map, patch semantics, and how to add new config documents.

## Network Topology

Node subnet: `192.168.48.0/22` · Pod network: `10.244.0.0/16` · Service network: `10.96.0.0/12`
LB IP pool: `192.168.48.20–50` (annotate new services with `lbipam.cilium.io/ips: "192.168.48.XX"`)

Full IP allocation and gateway architecture: `@docs/src/general/network.md`.

## Node Maintenance — Shutdown

To cleanly shut down a node (e.g. mc3 at `192.168.48.4`):

```sh
# 1. Cordon — prevent new pods scheduling
kubectl cordon <node-name>

# 2. Drain — evict running pods
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 3. Pause Ceph rebalancing (prevents unnecessary data movement during downtime)
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd set noout

# 4. Verify Ceph is healthy before proceeding
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# 5. Shut down via talosctl
TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig \
  talosctl shutdown --nodes <node-ip>
```

Node IPs: mc1=`192.168.48.2`, mc2=`192.168.48.3`, mc3=`192.168.48.4`

## Node Maintenance — Power On / Bring Back

```sh
# 1. Power on the machine physically (or WoL)

# 2. Wait for node to become Ready
kubectl get node <node-name> -w

# 3. Uncordon FIRST — Rook OSD pods need to schedule before Ceph can see the OSD back
kubectl uncordon <node-name>

# 4. Wait for OSD pod to start and Ceph to register it
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# 5. Once OSDs are back up, unset noout
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd unset noout

# 6. Verify HEALTH_OK
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

> **Order matters**: uncordon before unsetting `noout` — the OSD pod must be running on the node before Ceph can mark it `up`.

## Do Not Edit (Generated/Auto-managed Files)

| File/Directory | Managed By | How to Update |
| --- | --- | --- |
| `provision/talos/clusterconfig/` | `talosctl` + `envsubst` | `task talos:generate` |
| Lines prefixed `# renovate: datasource=...` | Renovate bot | Do not manually bump |
| `.terraform.lock.hcl` | Terraform | `task terraform:init:cloudflare` |
