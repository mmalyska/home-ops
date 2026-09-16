# Coder OSS Sandbox Platform — Design Spec

**Date:** 2026-06-03  
**Status:** Approved  

## Problem

Hermes AI agent profiles (`devops`, `dotnet-dev`, `node-dev`, `mobile-dev`, `researcher`) require isolated sandbox environments with SSH access for their `terminal`/`file` tools. Daytona was attempted but its runner requires a DaemonSet with host Docker and writes to immutable host paths (`/etc/daytona/ssh`) — fundamentally incompatible with Talos Linux.

A secondary use case is devcontainer replacement: SSH + VS Code Remote access to persistent development environments.

## Goals

1. SSH-accessible sandbox pods for Hermes SSH backend — one per worker profile, fixed IP, always-on
2. VS Code / Cursor SSH Remote connectivity to the same pods (devcontainer replacement)
3. Web UI for workspace management with Keycloak SSO
4. Fully Talos-compatible — no host Docker, no hostPath writes, pure K8s-native

## Non-Goals

- Ephemeral/on-demand workspace creation (persistent pods only)
- GPU access in sandbox pods
- Renovate digest pinning for workspace images (deferred)
- CI pipeline for image builds (deferred — manual push initially)

## Architecture

```
User (browser / VS Code)
         │ HTTPS
         ▼
Envoy HTTPRoute — coder.<private-domain>
         │
         ▼
  ┌─────────────────────────────────────┐
  │   Coder Server (coder namespace)    │
  │   Helm: helm.coder.com/v2           │
  └──────────┬──────────────────────────┘
             │ OIDC                 │ K8s API
             ▼                      ▼
       Keycloak (home realm)   CNPG PostgreSQL (coderdb)
                                    │
                      ┌─────────────┘
                      ▼
  ┌───────────────────────────────────────────────────────┐
  │               coder namespace (workspace pods)        │
  │                                                       │
  │  ws-devops      ── LoadBalancer 192.168.48.51 :22   │
  │  ws-dotnet-dev  ── LoadBalancer 192.168.48.52 :22   │
  │  ws-node-dev    ── LoadBalancer 192.168.48.53 :22   │
  │  ws-mobile-dev  ── LoadBalancer 192.168.48.54 :22   │
  │  ws-researcher  ── LoadBalancer 192.168.48.55 :22   │
  │                                                       │
  │  Each pod: workspace image + Coder agent + SSH :22   │
  │            + PVC 20Gi Ceph RBD (/home/coder)         │
  └───────────────────────────────────────────────────────┘
             │
  Harbor (harbor.<private-domain>)
  Project: sandbox — 5 custom workspace images
```

### Two SSH paths (co-existing)

| Path | How | Used by |
|------|-----|---------|
| `coder ssh ws-devops` | WebSocket proxy through Coder server | VS Code `coder config-ssh` entries |
| Direct `ssh coder@192.168.48.51` | LoadBalancer Service → SSH server in pod | Hermes SSH backend config |

The two paths are independent — Coder server downtime does not break active direct SSH sessions or Hermes tool execution.

## Component Details

### 1. Coder Server

**Location:** `cluster/apps/ai/coder/`  
**Helm chart:** `helm.coder.com/v2`, release `coder`, namespace `coder`  
**Resources:** `requests: 200m CPU / 512Mi RAM`, `limits: 500m / 1Gi`

**Key environment variables (from ExternalSecret → K8s Secret):**

<!-- secretlint-disable -->
```
CODER_ACCESS_URL          = https://coder.<private-domain>
CODER_PG_CONNECTION_URL   = postgres://app:<pw>@coderdb-cnpg-rw/app?sslmode=require
CODER_OIDC_ISSUER_URL     = https://keycloak.<private-domain>/realms/home
CODER_OIDC_CLIENT_ID      = coder
CODER_OIDC_CLIENT_SECRET  = <from Bitwarden>
CODER_OIDC_EMAIL_DOMAIN   = gmail.com
```
<!-- secretlint-enable -->

**HTTPRoute:** `coder.<private-domain>` → Coder service port 80, private Envoy Gateway. No `oauth2-proxy` wrapper — Coder handles its own auth.

### 2. PostgreSQL (CNPG)

`Cluster` CR `coderdb` in `templates/cnpg.yaml` — same pattern as `harbordb`.

- ExternalSecret pulls app password from Bitwarden
- Coder connects via `coderdb-cnpg-rw:5432`
- Scheduled backup to QNAP QuObjects S3 (barman-cloud)
- **Critical:** `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` on ObjectStore env (boto3 ≥1.34 checksum fix)

### 3. Workspace Template (Terraform)

One template covers all 5 workspaces. Per-workspace parameters: `workspace_image`, `lb_ip`.

**Template storage:** Terraform files live at `cluster/apps/ai/coder/workspace-template/` in git and are pushed to the running Coder server via `coder templates push` as a one-time setup step (or on template updates).

**Resources created per workspace by the template:**

| Resource | Detail |
|----------|--------|
| `Deployment` | 1 replica, workspace image, Coder agent injected via init container, SSH server started in startup script |
| `PersistentVolumeClaim` | 20Gi, `ceph-block` StorageClass, mounted at `/home/coder` |
| `Service` (LoadBalancer) | Port 22, annotated `lbipam.cilium.io/ips: 192.168.48.5X` — fixed IP from `coder-pool` |

**Workspace pod resources:** `requests: 500m CPU / 1Gi RAM`, `limits: 1000m / 2Gi`

**SSH server:** started via workspace startup script (`/usr/sbin/sshd -D &`). The startup script also writes the workspace's public key (embedded as a Terraform variable in the template — safe to commit) into `/home/coder/.ssh/authorized_keys`.

### 4. Workspace PVC Backups (VolSync)

Each of the 5 workspace PVCs gets a VolSync `ReplicationSource`:
- Restic backend → QNAP QuObjects S3
- Schedule: every 6 hours (matching `hermes-agent-data` cadence)
- Retention: 7 daily, 4 weekly
- `ReplicationDestination` defined with `restore.bootstrap: false` (enabled on-demand for recovery)

### 5. Cilium LB Pool

The existing `CiliumLoadBalancerIPPool` named `daytona-pool` is **renamed to `coder-pool`** in `cluster/apps/core/cilium/templates/config.yaml`. IP range `.51–.70` unchanged.

### 6. Harbor — Workspace Images

Harbor is **re-enabled** (`enabled: "true"` in `app-config.yaml`). New project `sandbox` (private) created in Harbor UI.

**Image hierarchy:**

```
images/sandbox/
├── base/Dockerfile      # Ubuntu 24.04 + openssh-server + common CLI tools + Coder agent bootstrap
├── devops/Dockerfile    # FROM base + kubectl, helm, talosctl, terraform, k9s, age, flux
├── dotnet/Dockerfile    # FROM base + .NET SDK 9, dotnet-ef, dotnet-format
├── node/Dockerfile      # FROM base + Node.js LTS, pnpm, Expo CLI, React Native tools
└── python/Dockerfile    # FROM base + Python 3.12, pip, uv, jupyter
```

**Push target:** `harbor.<private-domain>/sandbox/<name>:latest`

**Pull secret:** Harbor robot account credentials in Bitwarden → ExternalSecret → `imagePullSecret` referenced in workspace template.

### 7. Workspace-to-Profile Mapping

| Workspace | Fixed IP | Image | Hermes profile |
|-----------|----------|-------|----------------|
| `ws-devops` | `192.168.48.51` | `sandbox/devops` | `devops` |
| `ws-dotnet-dev` | `192.168.48.52` | `sandbox/dotnet` | `dotnet-dev` |
| `ws-node-dev` | `192.168.48.53` | `sandbox/node` | `node-dev` |
| `ws-mobile-dev` | `192.168.48.54` | `sandbox/node` | `mobile-dev` |
| `ws-researcher` | `192.168.48.55` | `sandbox/python` | `researcher` |

`orchestrator` and `default` profiles do not get sandbox wiring.

### 8. Hermes SSH Backend Wiring

**SSH keypairs:** 5 ed25519 keypairs, one per workspace. Private keys stored in Bitwarden (`sandbox-devops-ssh-private-key`, etc.). Public keys committed to git inside the Coder workspace template.

**ExternalSecret extension:** The existing `hermes-agent` ExternalSecret is extended to pull all 5 private keys, mounted at `/opt/data/ssh/sandbox-<profile>.key` (mode 0600) inside the Hermes pod.

**Hermes profile config** (added to each worker profile's `config.yaml` via `config-seeder` init container, driven by the Hermes `values.yaml` ConfigMap):

```yaml
sandbox:
  provider: ssh
  host: "192.168.48.5X"
  port: 22
  user: coder
  key: /opt/data/ssh/sandbox-<profile>.key
```

## Keycloak Configuration

New OIDC client `coder` in the `home` realm:
- **Client type:** OIDC, confidential
- **Redirect URI:** `https://coder.<private-domain>/api/v2/users/oidc/callback`
- **Scopes:** `openid`, `email`, `profile`
- Client secret stored in Bitwarden, pulled via ExternalSecret

## Bitwarden Secrets Required

| Key | Used by |
|-----|---------|
| `coder-oidc-client-secret` | Coder server OIDC config |
| `coder-db-password` | CNPG coderdb app password |
| `cnpg-s3-*` keys (reuse existing) | CNPG barman-cloud backup |
| `sandbox-harbor-robot-password` | Workspace pod imagePullSecret |
| `sandbox-devops-ssh-private-key` | Hermes devops profile SSH |
| `sandbox-dotnet-dev-ssh-private-key` | Hermes dotnet-dev profile SSH |
| `sandbox-node-dev-ssh-private-key` | Hermes node-dev profile SSH |
| `sandbox-mobile-dev-ssh-private-key` | Hermes mobile-dev profile SSH |
| `sandbox-researcher-ssh-private-key` | Hermes researcher profile SSH |

VolSync S3 credentials reuse existing `volsync-s3-*` keys already in Bitwarden.

## Verification Checklist

1. `kubectl get pods -n coder` — Coder server Running, `coderdb` Running
2. `https://coder.<private-domain>` — web UI loads, Keycloak SSO redirects correctly
3. `coder login https://coder.<private-domain>` + `coder config-ssh` — SSH config entries written
4. `ssh coder@192.168.48.51` (direct) — connects to `ws-devops` pod
5. VS Code SSH Remote → `coder.ws-devops` — connects, workspace opens
6. Hermes devops profile: `terminal` tool executes a command in the sandbox
7. VolSync `ReplicationSource` status: first backup completes for all 5 PVCs
8. CNPG scheduled backup: first snapshot visible in QNAP S3
