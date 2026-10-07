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

- Rendered from `talosctl gen config` plus the layered patch files in `provision/talos/patches/` (see `provision/talos/README.md`)
- Node index: `provision/talos/nodes.yaml`; generate: `task talos:generate`
- Current versions: Talos v1.14.x, Kubernetes v1.35.x (updated by Renovate)
- 3 control plane nodes (scheduling enabled on control plane, no dedicated workers)
- Custom extensions: `siderolabs/i915`, `siderolabs/intel-ucode`, `siderolabs/nut-client`
- kube-apiserver: no OIDC (kubectl uses the Talos-generated kubeconfig); authentication, authorizers (node, rbac), admission and audit are config documents in provision/talos/patches/controlplane/ (files 20 to 26)
- **To make config changes**: use the `talos-config-editing` skill — it has the edit decision map, patch semantics, and how to add new config documents.

### Talos upgrades

- `TALOS_VERSION` in `.taskfiles/talos/Taskfile.yaml` is tracked by Renovate via `github-releases siderolabs/talos`. Talos 1.14 stopped publishing `ghcr.io/siderolabs/installer`; the install image is the Image Factory schematic (`factory.talos.dev/metal-installer/<id>:${TALOS_VERSION}`) in `patches/controlplane/05-install-image.yaml.tpl` (worker: `patches/worker/`). Kubernetes is held at `<=1.35` in `.github/renovate/allowedVersions.json5`.
- Roll out one node at a time, control plane first (`mc1` -> `mc2` -> `mc3`), then `nv1`: `task talos:upgrade N=mc1`. It gates on `wait_for_health` (jobs, Ceph `HEALTH_OK`, **every** CNPG cluster Ready) and now fails if the node boots a different version than expected.
- `talosctl reboot` is blocked for Claude by permissions. Ask the user to run it with `!`.
- A drain stuck on a CNPG primary (PDB, 0 disruptions allowed) means a replica is unhealthy. Fix the replica first. Do not force the drain. `kubectl uncordon <node>` restores evicted Ceph mon/OSD pods; Ceph recovers on its own.
- CNPG `Expected empty archive` (barman) means the S3 path holds a previous cluster's objects. Point the ObjectStore at a fresh path (`home-assistant-v2`); do not wipe the old one without checking it.
- The Rook `CephCluster` status lags the real Ceph health by about a minute, and `talos:upgrade` waits on it.
- `nv1` runs our own build of the custom Jetson installer (fork `mmalyska/talos-jetson-orin`), published to `ghcr.io/mmalyska/custom-installer` (must stay public, nv1 pulls anonymously). After an upgrade it can boot the old UKI. The fix and the checks are in `provision/talos/README.md` ("nv1 boots the wrong UKI after an upgrade").
- Talos 1.14 sets `net.ipv4.conf.{all,default}.send_redirects=0` (was 1). No impact seen: Cilium runs in VXLAN tunnel mode.
- etcd HTTP endpoints move from port 2379 to 2383 (client mTLS) in 1.14. Prometheus scrapes etcd through `cluster.etcd.extraArgs.listen-metrics-urls: http://127.0.0.1:2381` plus `kube-system/metrics-proxy` and `kubeEtcd.endpoints` (the three control-plane IPs) in the prometheus-stack values.
- Kubernetes upgrade: `task talos:upgrade:k8s` runs `talosctl upgrade-k8s`, which changes the live config outside the repo. Bump `KUBERNETES_VERSION` in `.taskfiles/talos/Taskfile.yaml` first (the kubelet, kube-apiserver, kube-controller-manager and kube-scheduler documents take their image tag from it), run the task, then `task talos:generate` and `task talos:diff`: the diff must show no differences. Only a same-version `--dry-run` has been tried; try a real minor or patch bump on one control plane first and record the result.
- Changing `cluster.etcd.extraArgs` is stored by `task talos:apply` but etcd is **not** restarted, and `talosctl service etcd restart` is refused ("doesn't support restart operation via API"). It only takes effect after a node reboot: apply, cordon + drain, reboot (user runs it), uncordon, wait for the gate; one control-plane node at a time.

## Network Topology

Node subnet: `192.168.48.0/24` (VLAN 48, gateway `192.168.48.254`) · Pod network: `10.244.0.0/16` · Service network: `10.96.0.0/12`
LB IP pool: `192.168.48.20–50` (annotate new services with `lbipam.cilium.io/ips: "192.168.48.XX"`)

> VLAN 48's gateway is `.254`, not `.1` — `192.168.48.1` is the Talos control-plane VIP.
> DHCP is disabled on VLAN 48; all node addresses are static in `provision/talos/patches/node/`.

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
