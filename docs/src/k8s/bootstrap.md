# Cluster Bootstrap

This page documents how to bootstrap a fresh cluster from scratch.
The process is mostly automated via `task bootstrap:kubernetes`, with a small number
of deliberate manual gates for destructive or interactive operations.

## Prerequisites

Before running bootstrap:

- Talos machine configs generated: `task talos:init` (runs `talhelper genconfig`)
- `.envrc` sourced via `direnv` — the following env vars must be set:
  - `BWS_TOKEN` — Bitwarden Secrets Manager machine account token
  - `KUBECONFIG` — path to the kubeconfig file
  - `TALOSCONFIG` — path to `provision/talos/clusterconfig/talosconfig`
- All secrets stored in Bitwarden Secrets Manager with their UUIDs referenced in
  `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`
- Configuration committed and pushed to the `main` branch (ArgoCD reads from git)
- AdGuard Home has a manual DNS rewrite: `k8s.<private-domain> → 192.168.48.1`
  (the cluster VIP). This is required before phase 3 (`apps`) where `kubectl` first
  connects to `https://k8s.<private-domain>:6443`. External-dns will take over
  maintaining this entry once deployed, but it does not exist yet during bootstrap.

## Bootstrap sequence

### 1. Apply Talos config to nodes (manual)

```sh
talosctl apply-config --nodes 192.168.48.2 --insecure -f provision/talos/clusterconfig/home-mc1.yaml
talosctl apply-config --nodes 192.168.48.3 --insecure -f provision/talos/clusterconfig/home-mc2.yaml
talosctl apply-config --nodes 192.168.48.4 --insecure -f provision/talos/clusterconfig/home-mc3.yaml
```

Use `--insecure` on first boot before the cluster PKI is established.
On subsequent re-applies (e.g. config changes), omit `--insecure`.

### 2. Run the automated bootstrap

```sh
task bootstrap:kubernetes
```

This single command runs the following phases in sequence:

| Phase | Task | What happens |
| ----- | ---- | ------------ |
| 1 | `etcd` | Bootstraps the etcd leader; retries until the first control-plane node accepts the bootstrap call |
| 2 | `kubeconfig` | Fetches kubeconfig from Talos into `$KUBECONFIG` |
| 3 | `apps` | Runs helmfile to install Cilium CNI and `kubelet-csr-approver`; waits for all nodes `Ready` |
| 4 | `eso-bootstrap` | Creates the `external-secrets` namespace and injects `bitwarden-access-token` K8s Secret from `$BWS_TOKEN` |
| 5 | `rook` | Wipes Rook data directories (`/var/lib/rook`) and raw disk partition tables on every node |
| 6 | `argocd` | Creates an empty `cluster-secrets` placeholder Secret, applies the ArgoCD kustomize, applies the root `bootstrap-application.yaml`, and waits for `argocd-server` Available |

### 3. Sync Rook Ceph storage (manual gate)

Rook Ceph operator and cluster have `syncPolicy.enabled: false` intentionally — auto-sync could
claim disks on an unexpected re-sync. After the bootstrap task completes and ArgoCD has had a
moment to discover and deploy the appsets, run:

```sh
task argocd:login      # log in with local admin (see below)
task bootstrap:rook-sync
```

`rook-sync` syncs the operator first, waits for its deployment to be Available, then syncs the
cluster. The CephCluster resource will then reconcile and format the clean disks.

### 4. Log in to ArgoCD (local admin)

On first bootstrap OIDC is unavailable because Keycloak has not deployed yet.
A local `mmalyska` account is configured with admin rights as a fallback:

```sh
task argocd:login
# Select local credentials when prompted (not SSO)
```

Once Keycloak is deployed and its realm/client are configured, re-run `task argocd:login`
to switch to SSO login.

## Chicken-and-egg problems and how they are resolved

### Cilium before pods

Cilium is deployed as a DaemonSet before pod networking exists. Cilium pods start via
kubelet directly, configure the CNI plugin on each node's filesystem, and only then
does general pod networking become available. The `apps` phase waits for all nodes `Ready`
before proceeding.

### Bitwarden secrets before External Secrets Operator

ESO is an ArgoCD-managed system app and cannot run until ArgoCD is deployed. But ArgoCD's
repo-server CMP sidecar mounts the `cluster-secrets` K8s Secret as a required volume —
it won't start without it. This is resolved in two steps:

1. **`eso-bootstrap`** injects the `bitwarden-access-token` into `external-secrets` namespace
   so that ESO can authenticate with Bitwarden the moment it starts.
2. **`argocd`** pre-creates an empty `cluster-secrets` K8s Secret so the repo-server sidecar
   can mount it and start. Once ESO deploys (sync-wave `-5`, first among system apps) and
   processes the `cluster-secrets` ExternalSecret, the K8s Secret is populated with real values
   and Kubernetes automatically updates the running volume mount — no restart needed.

### Keycloak OIDC

ArgoCD is configured to use Keycloak for OIDC, but Keycloak itself is deployed by ArgoCD as
a system app. On first bootstrap, ArgoCD starts with OIDC failing (Keycloak not reachable).
The local `mmalyska` admin account works as a fallback until Keycloak is ready.

### k8s endpoint DNS before external-dns

`kubectl` connects to `https://k8s.<private-domain>:6443` (the cluster VIP at `192.168.48.1`)
starting at phase 3. The `DNSEndpoint` that registers this name in AdGuard lives in the
`adguard-dns` app, which is deployed by ArgoCD — which itself isn't running yet.
This is resolved by adding a **manual static rewrite** in AdGuard Home
(`k8s.<private-domain> → 192.168.48.1`) before bootstrap. Once external-dns deploys and
reconciles the `DNSEndpoint`, it takes ownership of the entry and the manual rewrite becomes
redundant.

### Rook Ceph disk initialization

Rook Ceph requires completely clean disks (no partition table, no filesystem metadata). The
`rook` phase runs wipe Jobs on every node before ArgoCD deploys the Rook operator, ensuring
disks are ready when the CephCluster resource is first reconciled.

## Post-bootstrap checklist

- [ ] `kubectl get nodes` — all 3 nodes `Ready`
- [ ] `task argocd:login` — ArgoCD accessible with local admin
- [ ] `task bootstrap:rook-sync` — Rook Ceph operator + cluster synced
- [ ] `kubectl -n rook-ceph get cephcluster` — CephCluster status `HEALTH_OK`
- [ ] Keycloak deployed and realm/client configured
- [ ] `task argocd:login` — SSO login works
- [ ] All ArgoCD apps `Synced` / `Healthy`

## Re-bootstrapping an existing cluster

If wiping and re-bootstrapping a cluster that previously had data:

1. Ensure Talos nodes are re-imaged or reset: `talosctl reset --nodes <ip> --graceful=false`
2. Re-apply Talos configs (step 1 above)
3. Run `task bootstrap:kubernetes` — all phases are idempotent except the rook wipe
   (which is intentionally destructive; it will wipe whatever is on the disks)
