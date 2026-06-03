# Daytona Installation Design

**Date:** 2026-06-02
**Status:** Approved

## Goal

Deploy Daytona (sandbox provider for AI agents) on the home-ops Kubernetes cluster to:
1. Provide isolated sandboxed environments with pre-installed tools for Hermes agent profiles
2. Replace devcontainers as the personal development environment, accessed via SSH

## Approach: Harbor as Separate App (Approach B)

Two new ArgoCD apps deployed in order: Harbor first, then Daytona. Harbor is a standalone app rather than a Daytona subchart so both can upgrade independently via Renovate and Harbor can be reused by other cluster apps.

---

## Section 1: Architecture

### Components

```
cluster/apps/default/harbor/     ← private OCI registry for sandbox snapshots
cluster/apps/ai/daytona/         ← sandbox platform
```

### Dependency graph

```
Keycloak (existing)      ─── OIDC ──────────────────────────────┐
CNPG operator (existing) ─── PostgreSQL (harbordb + daytonadb) ──┤
Ceph (existing, 1TB)     ─── RBD PVCs ──────► Harbor registry ───┤
                                                                   ▼
                                              Daytona API / Proxy / Runner
Ceph                     ─── RBD PVCs (sandbox working dirs) ────►
Cilium daytona-pool      ─── LoadBalancer IP (.51–.70) ──────────► SSH Gateway
Envoy-internal (.21)     ─── HTTPRoutes ─────────────────────────►
```

### Network topology

| Service | Access | Hostname / Address |
|---|---|---|
| Daytona dashboard/API | Internal (AdGuard) | `daytona.<private-domain>` |
| Sandbox proxy | Internal (AdGuard) | `*.daytona.<private-domain>` |
| SSH Gateway | Internal (Cilium LB) | IP from pool 192.168.48.51–.70, port 2222 |
| Harbor UI | Internal (AdGuard) | `harbor.<private-domain>` |

### IP pool separation

A dedicated `CiliumLoadBalancerIPPool` named `daytona-pool` (192.168.48.51–192.168.48.70) is added to `cluster/apps/core/cilium/templates/config.yaml` alongside the existing cluster pool (192.168.48.20–.50). The SSH Gateway `Service` is annotated `io.cilium/lb-ipam-pool: daytona-pool`. A `CiliumL2AnnouncementPolicy` covers the new range.

---

## Section 2: Harbor App

**Location:** `cluster/apps/default/harbor/`

### Chart structure

```
harbor/
├── app-config.yaml
├── Chart.yaml          # harbor/harbor + pgsql-cnpg
├── values.yaml
└── templates/
    ├── httproute.yaml
    └── externalsecret.yaml
```

### Dependencies

| Dependency | Source |
|---|---|
| `harbor/harbor` | `https://helm.goharbor.io` |
| `pgsql-cnpg` | `file://../../../../charts/pgsql-cnpg/` |

### Subcharts

| Subchart | Decision | Reason |
|---|---|---|
| `postgresql` (Harbor built-in) | disabled | CNPG cluster `harbordb-cnpg` |
| `redis` (Harbor built-in) | enabled | Isolated, low overhead |
| `trivy` | disabled | Vulnerability scanning not needed |
| `notary` | disabled | Overkill for home lab |

### Storage (Ceph RBD PVCs)

| PVC | Size | Purpose |
|---|---|---|
| registry | 200 GB | Sandbox snapshot OCI images |
| jobservice | 5 GB | Job logs |

### Networking

- `expose.type: clusterIP` — Harbor's built-in ingress disabled
- `externalURL: https://harbor.<secret:private-domain>` — required for Harbor redirect generation
- HTTPRoute: `harbor.<secret:private-domain>` → Harbor core service → `envoy-internal`

### Secrets (Bitwarden ExternalSecret)

- `HARBOR_ADMIN_PASSWORD` — Harbor admin account

CNPG generates `harbordb-cnpg-app` automatically; referenced via `database.external.existingSecret`.

### Post-Harbor steps

1. Create Harbor project `daytona` for sandbox snapshot images
2. Create Harbor robot account (push/pull on `daytona` project) → store credentials in Bitwarden
3. *(Post-initial-deploy)* Configure Keycloak OIDC client for Harbor SSO

---

## Section 3: Daytona App

**Location:** `cluster/apps/ai/daytona/`

### Chart structure

```
daytona/
├── app-config.yaml
├── Chart.yaml          # daytona/daytona + pgsql-cnpg
├── values.yaml
└── templates/
    ├── httproute-api.yaml      # daytona.<private-domain>
    ├── httproute-proxy.yaml    # *.daytona.<private-domain>
    └── externalsecret.yaml
```

### Subcharts

| Subchart | Decision | Reason |
|---|---|---|
| `postgresql` | disabled | CNPG cluster `daytonadb-cnpg` |
| `harbor` | disabled | External → Harbor app in `default` ns |
| `dex` | disabled | Keycloak as OIDC provider |
| `minio` | disabled | S3 not needed for initial deploy; add QNAP QuObjects or Ceph RGW later |
| `pgadmin` | disabled | Not needed |
| `redis` | enabled | Bundled Bitnami Redis, isolated |

### Key values

- `baseDomain: daytona.<secret:private-domain>` — sandboxes appear at `{id}.daytona.<private-domain>`
- Harbor: in-cluster URL `https://harbor.default.svc.cluster.local`
- OIDC: `dex.enabled: false`; Daytona OIDC config points to `https://keycloak.<private-domain>/realms/<realm>`

### Networking

| Route | Target | Gateway |
|---|---|---|
| `daytona.<secret:private-domain>` | Daytona API service | `envoy-internal` |
| `*.daytona.<secret:private-domain>` | Daytona Proxy service | `envoy-internal` (wildcard hostname) |
| SSH Gateway `Service: LoadBalancer` | Port 2222 | Cilium `daytona-pool` annotation |

DNS: two AdGuard entries — `daytona.<private-domain>` and `*.daytona.<private-domain>` both point to envoy-internal (192.168.48.21).

### Secrets (Bitwarden ExternalSecret)

- Daytona admin API key
- SSH Gateway keypair (public + private)
- Keycloak OIDC client secret
- Harbor robot account credentials (push/pull on `daytona` project)

---

## Section 4: Runner and Node Configuration

### Node labeling

Add `daytona-sandbox-c: "true"` to `machine.nodeLabels` in `provision/talos/templates/controlplane.yaml`. One change covers all 3 control-plane nodes (mc1/mc2/mc3). Applied via `talosctl apply-config` (rolling, non-disruptive).

`nv1` worker node (192.168.48.5) is excluded — it has a `nv: :NoSchedule` taint and different hardware.

### No new taint

`sandbox=true:NoSchedule` is **not** added — control-plane nodes are shared and must continue running other workloads. Daytona runner uses `nodeSelector: { daytona-sandbox-c: "true" }` to target nodes without exclusivity.

### Sandbox resource limits

| Resource | Limit | Notes |
|---|---|---|
| CPU | 2 cores | Per sandbox |
| Memory | 4 Gi | Per sandbox |
| Concurrent sandboxes | ~3 initial | One per node; tune after observing load |

### Storage

Ceph RBD `StorageClass` (already deployed) used for sandbox working-directory PVCs.

### Future migration path

When dedicated worker nodes are purchased:
1. Add `daytona-sandbox-c: "true"` + `sandbox=true:NoSchedule` to new worker Talos node configs
2. Remove `daytona-sandbox-c: "true"` from `provision/talos/templates/controlplane.yaml`
3. Apply Talos config — runners shift to dedicated nodes automatically, no Daytona values change needed

*(Also tracked in `.plans/TODO.md`)*

---

## Section 5: Deployment Order & Post-Install Steps

### Deployment sequence

```
1. Cilium pool update    → add daytona-pool to cluster/apps/core/cilium/templates/config.yaml
2. Node labels           → add daytona-sandbox-c to provision/talos/templates/controlplane.yaml
                           apply via talosctl apply-config on mc1/mc2/mc3
3. Harbor                → deploy cluster/apps/default/harbor/
                           wait for registry healthy
                           create Harbor project + robot account → store in Bitwarden
4. Daytona               → deploy cluster/apps/ai/daytona/
```

### Post-Daytona steps

- Generate Daytona admin API key → store in Bitwarden
- Configure Keycloak OIDC client `daytona` (redirect URLs for dashboard hostname)
- Register Daytona runner using admin API key
- Validate SSH Gateway: `ssh -p 2222 <cilium-daytona-pool-ip>` from home network
- Create first agent profile snapshot: start sandbox from base image, install tools, snapshot → push to Harbor `daytona` project
- Wire Hermes to Daytona API endpoint for sandbox provisioning

### Renovate / upgrades

Both Harbor and Daytona charts are tracked by Renovate independently. Neither upgrade blocks the other.

---

## Constraints and Known Limitations

- **Disk per node**: ~61–134 GB free on NVMe `/var`; far below Daytona's 1TB recommendation. Ceph RBD PVCs handle sandbox working directories, reducing pressure on node-local disk. Cap concurrent sandboxes conservatively.
- **No NGINX ingress**: Envoy Gateway handles all routing via HTTPRoutes. Daytona chart ingress is fully disabled; all exposure is via manual HTTPRoutes.
- **S3 not wired**: MinIO subchart disabled. Workspace backup/archival not available on day one. Future: use QNAP QuObjects (Go SDK, no boto3 checksum issue) or enable Ceph RGW as a separate initiative.
- **Keycloak OIDC for Harbor**: deferred post-initial-deploy.
