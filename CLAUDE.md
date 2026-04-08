# CLAUDE.md — home-ops Repository Guide

## Project Overview

GitOps home-lab repository managing a Talos Linux Kubernetes cluster with ArgoCD and Bitwarden-based secret management.

- **Hardware**: 3x Lenovo M720q (mc1/mc2/mc3) as control plane nodes at 192.168.48.2-4
- **OS**: Talos Linux (managed via `talhelper` + `talconfig.yaml`)
- **GitOps**: ArgoCD with ApplicationSet pattern + `argocd-secret-replacer` CMP plugin for token substitution
- **Secrets**: Bitwarden Secrets Manager (via ESO `ClusterSecretStore`) + BWS env vars via `.envrc`
- **DNS/Tunnel**: Cloudflare managed via Terraform

## Repository Structure

```
cluster/                        # All Kubernetes manifests (ArgoCD managed)
  bootstrap-application.yaml   # Root app-of-apps entry point
  projects/                    # ArgoCD AppProject definitions (5 categories)
  appsets/                     # ArgoCD ApplicationSets (scan app-config.yaml files)
  apps/                        # Applications organized by category
    core/                      #   cilium, argocd, rook-ceph
    system/                    #   cert-manager, monitoring, keycloak, external-secrets...
    default/                   #   jellyfin, gitea, n8n, open-webui, gethomepage...
    games/                     #   minecraft-bedrock, vintagestory
    home-automation/           #   vernemq, ollama, whisper, piper, openwakeword
  .tools/                      # Utility K8s manifests (wipe-rook, etc.)
provision/
  talos/                       # Talos config (talconfig.yaml, talsecret.yaml, clusterconfig/)
  terraform/cloudflare/        # Cloudflare DNS, tunnels, firewall rules
charts/                        # Local Helm charts (app-of-apps, pgsql-cnpg, volsync)
docs/                          # MkDocs documentation (src/)
.taskfiles/                    # Task automation modules
.github/                       # CI/CD workflows, Renovate config, linting rules
```

## Application Pattern

Each app lives at `cluster/apps/{category}/{app-name}/`:

```
app-name/
├── app-config.yaml      # ArgoCD ApplicationSet config (enabled: "true|false")
├── Chart.yaml           # Helm chart + external dependencies
├── values.yaml          # Helm values customization
└── templates/           # Additional K8s manifests (ingress, certificates, ExternalSecrets...)
```

Alternatively, Kustomize-based apps use `kustomization.yaml` instead of `Chart.yaml`.

Multi-component apps (e.g., `rook-ceph`, `intel`) use `appSubfolder` in `app-config.yaml` to deploy from subdirectories.

### app-config.yaml Key Fields

```yaml
- enabled: "true"                          # Toggle deployment
  namespace: my-namespace
  appSubfolder: subfolder-name             # Optional: for multi-component apps
  syncWave: "-5"                           # Optional: ArgoCD sync-wave (string). Lower = deploys first.
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:                                  # Optional: token substitution from cluster-secrets
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

The `syncWave` field controls the `argocd.argoproj.io/sync-wave` annotation on the generated
Application. Use it when an app must deploy before others (e.g. External Secrets Operator at
`"-5"` so it is ready before any ExternalSecret resources are processed).

## Secrets Management

Two mechanisms, choose based on where the secret value is used:

1. **`cluster-secrets` mount** — for `<secret:key>` tokens in non-injectable fields (hostnames,
   cert dnsNames, ConfigMap values, `values.yaml` strings, etc.). The `cluster-secrets` K8s Secret
   lives in the `argocd` namespace (sourced from Bitwarden via ESO) and is mounted into ArgoCD
   repo-server sidecars. Set `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml` to enable.
   - ExternalSecret: `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`

2. **Per-app `ExternalSecret`** — for credentials that end up in K8s `Secret` `data`/`stringData`
   fields, consumed via `secretKeyRef` or ESO template rendering. Use `ClusterSecretStore` named
   `bitwarden`. Create in `templates/` (Helm) or `resources/` (Kustomize).

**The rule**: token in `Secret data/stringData` → ExternalSecret. Token in any other field →
`cluster-secrets` + plugin.

- **Never commit secret values** to any file — gitleaks pre-commit hook checks for this
- Environment secrets (BWS): loaded via `.envrc` using `bws secret list`

### Working with Bitwarden Secrets Manager

```sh
# View secrets in the devcontainer
bws secret list

# Add a new secret via Bitwarden web UI or CLI, note the UUID for ExternalSecret remoteRef.key
```

### Adding a new global token (non-injectable field)

1. Add the secret to Bitwarden Secrets Manager, note its UUID
2. Add an entry to `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`
3. Use `<secret:key>` token in the template/values file
4. Set `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`

### Adding a per-app credential (K8s Secret data field)

1. Add the secret to Bitwarden Secrets Manager, note its UUID
2. Create `templates/credentials-externalsecret.yaml` (or similar) with the ExternalSecret
3. Reference the created Secret via `secretKeyRef` or ESO template expressions

## Core Infrastructure

| Component | Purpose |
|-----------|---------|
| **Cilium** | CNI, kube-proxy replacement, L2 announcements for LoadBalancer IPs |
| **Envoy Gateway** | Kubernetes Gateway API — `envoy-external` (.20, internet via Cloudflare Tunnel) and `envoy-internal` (.21, home network only) |
| **Cloudflared** | Cloudflare Tunnel client — routes internet traffic into `envoy-external` |
| **external-dns (cloudflare)** | Publishes `controller: external` DNSEndpoints and `controller: dns-controller` HTTPRoutes on `envoy-external` to Cloudflare DNS |
| **external-dns (adguard)** | Publishes `controller: internal` DNSEndpoints and `controller: dns-controller` HTTPRoutes on `envoy-internal` to AdGuard Home |
| **cert-manager** | TLS certificates via Cloudflare DNS01; wildcard `cert-production` used by both gateways |
| **Rook-Ceph** | Primary persistent storage |
| **NFS subdir provisioner** | Cold storage on QNAP NAS |
| **Keycloak** | OIDC identity provider (configured in Talos kube-apiserver) |
| **External Secrets Operator** | Kubernetes secret sync from Bitwarden |
| **kube-prometheus-stack** | Prometheus + Grafana monitoring |
| **CloudNative-PG** | PostgreSQL operator |
| **VolSync** | PVC backup/restore |

## Debugging Envoy Gateway with egctl

`egctl` is the Envoy Gateway CLI (`brew install egctl`). Use it to inspect live gateway state.

```sh
# Gateway and route status
egctl x status gateway -A
egctl x status httproute -A
egctl x status httproute -A --verbose   # full condition history
egctl x status httproute -A --quiet     # latest condition only

# xDS config (what Envoy actually has programmed)
egctl config envoy-proxy route -A       # all routes
egctl config envoy-proxy cluster -A     # all backends
egctl config envoy-proxy listener -A    # all listeners

# Open Envoy admin dashboard (port-forwards to localhost:19000)
egctl x dashboard envoy-proxy -n envoy-gateway <pod-name>

# Debug: translate a Gateway API manifest to xDS or IR
egctl x translate --from gateway-api --to xds -f my-httproute.yaml
egctl x translate --from gateway-api --to ir  -f my-httproute.yaml
```

The two gateway instances in this cluster:
- `envoy-external` (namespace: `envoy-gateway`) — internet-facing via Cloudflare Tunnel
- `envoy-internal` (namespace: `envoy-gateway`) — internal network only

## Talos Configuration

- Managed with `talhelper` from `provision/talos/talconfig.yaml`
- Current versions: Talos v1.11.3, Kubernetes v1.34.5 (updated by Renovate)
- 3 control plane nodes (scheduling enabled on control plane, no dedicated workers)
- Custom extensions: `siderolabs/i915`, `siderolabs/intel-ucode`, `siderolabs/nut-client`
- OIDC on kube-apiserver pointing to Keycloak

## Key Tasks

```sh
task --list                           # List all available tasks
task init                             # Install workstation dependencies (Homebrew)
task precommit:init                   # Install pre-commit hooks

# Talos
task talos:generate                   # Regenerate Talos machine configs
task talos:apply                      # Apply config to nodes (NODE= env var)
task talos:upgrade:all                # Upgrade Talos OS on all nodes
task talos:upgrade:k8s                # Upgrade Kubernetes version

# Cluster bootstrap (run in order on a fresh cluster)
task bootstrap:kubernetes             # Full automated bootstrap: etcd → kubeconfig → Cilium →
                                      #   ESO secret injection → Rook wipe → ArgoCD install
task bootstrap:rook-sync              # Post-bootstrap: sync Rook Ceph operator then cluster
                                      #   (manual gate — run after 'task argocd:login')

# ArgoCD
task argocd:login                     # Login to ArgoCD (uses --sso; requires Keycloak to be running)
                                      # On first bootstrap use local admin credentials instead
task argocd:sync                      # Sync ArgoCD applications

# Terraform
task terraform:plan:cloudflare        # Preview Cloudflare DNS changes
task terraform:apply:cloudflare       # Apply Cloudflare DNS changes

# Maintenance
task kubernetes:delete-failed-pods    # Clean up failed/evicted pods
task lint:all                         # Run all linters
task format:all                       # Format YAML and markdown files
```

## Bootstrap Process

`task bootstrap:kubernetes` automates a fresh cluster from etcd to ArgoCD in one command.
It handles the chicken-and-egg problems in the right order:

| Phase | Task | What it does |
|-------|------|--------------|
| 1 | `etcd` | Bootstraps the etcd leader; retries until the node accepts |
| 2 | `kubeconfig` | Fetches kubeconfig from Talos |
| 3 | `apps` | Helmfile: Cilium CNI + `kubelet-csr-approver`; waits for all nodes `Ready` |
| 4 | `eso-bootstrap` | Creates `external-secrets` namespace + `bitwarden-access-token` Secret from `$BWS_TOKEN` |
| 5 | `rook` | Wipes `/var/lib/rook` and raw disk partition tables on each node (destructive) |
| 6 | `argocd` | Pre-creates empty `cluster-secrets` Secret; applies ArgoCD kustomize + `bootstrap-application.yaml`; waits for server Available |

**Post-bootstrap manual steps** (must be done after the task completes):
1. `task argocd:login` — use local admin (SSO not available until Keycloak deploys)
2. `task bootstrap:rook-sync` — syncs Rook operator → waits ready → syncs Rook cluster
3. Once Keycloak is running and configured, re-run `task argocd:login` for SSO

**Key design decisions:**
- Empty `cluster-secrets` Secret is pre-created so ArgoCD repo-server CMP sidecar can mount
  it and start. ESO (sync-wave `"-5"`) populates it with real Bitwarden values once it deploys.
  Kubernetes automatically updates running volume mounts — no restart needed.
- `bitwarden-access-token` is injected from `$BWS_TOKEN` (already in `.envrc`) — no manual
  `kubectl create secret` step required.
- Rook Ceph operator and cluster keep `syncPolicy.enabled: false` — storage is never auto-synced
  to prevent accidental disk claims on unexpected re-syncs. `task bootstrap:rook-sync` is the
  intentional gate.

See `docs/src/k8s/bootstrap.md` for the full reference including re-bootstrap instructions.

## Development Environment

Uses a devcontainer (`ghcr.io/mmalyska/home-ops-devcontainer:main`). On container start:
1. `.envrc` is sourced via direnv (sets `KUBECONFIG`, `TALOSCONFIG`, BWS secrets)
2. Pre-commit hooks are initialized
3. Task subtasks are initialized

Required secrets for devcontainer: `TERRAFORM_TOKEN`

## CI/CD

- **Renovate**: Automated dependency updates (Helm charts, container images, Talos/K8s versions)
- **GitHub Actions**: lint, YAML diff on PR, devcontainer publish, GitHub Pages publish
- **Pre-commit**: yamllint, helmlint, gitleaks, prettier

## Adding a New Application

1. Create directory `cluster/apps/{category}/{app-name}/`
2. Create `app-config.yaml` with `enabled: "true"`, namespace, and sync policy
3. Add `Chart.yaml` with Helm chart dependency (or `kustomization.yaml`)
4. Add `values.yaml` with customizations
5. If secrets needed: create `templates/credentials-externalsecret.yaml` for K8s Secret data fields (Bitwarden ExternalSecret), or add `SECRET_PROVIDER: cluster-secrets` plugin block for `<secret:key>` tokens in non-injectable fields
6. Add any extra manifests in `templates/`
7. Commit — ArgoCD ApplicationSet will auto-discover the new app

## Network Topology

**Physical path**: ISP fiber → ONT (1 GbE WAN) → ASUS RT-AX58U (Asuswrt-Merlin) → LAN

| Range / Address | Purpose |
|----------------|---------|
| `10.244.0.0/16` | Pod network (clusterPodNets) |
| `10.96.0.0/12` | Service network (clusterSvcNets) |
| `192.168.48.0/22` | Node subnet (gateway: 192.168.50.1) |
| `192.168.48.1` | Cluster VIP (`TALHELPER_CLUSTERENDPOINTIP`) — kube-apiserver endpoint |
| `192.168.48.2` | mc1 (control plane) |
| `192.168.48.3` | mc2 (control plane) |
| `192.168.48.4` | mc3 (control plane) |
| `192.168.48.20–50` | Cilium LB IP pool (for LoadBalancer services) |
| `192.168.50.1` | Router/gateway — ASUS RT-AX58U (Asuswrt-Merlin firmware) |
| `192.168.50.8` | QNAP TS-251D NAS (8 GB RAM, QM2-2P10G1TA PCIe card) — NFS + S3 storage |
| `192.168.50.9` | Raspberry Pi — Home Assistant OS (HAOS); AdGuard Home runs as HA addon |

**Known assigned LoadBalancer IPs** (set via `lbipam.cilium.io/ips` annotation):

| IP | Service |
|----|---------|
| `192.168.48.20` | `envoy-external` — internet-facing gateway (via Cloudflare Tunnel) |
| `192.168.48.21` | `envoy-internal` — internal network gateway (AdGuard DNS) |
| `192.168.48.22` | Jellyfin |
| `192.168.48.23` | Minecraft Bedrock |
| `192.168.48.27` | Home automation services (Ollama, Whisper, Piper, OpenWakeWord) |
| `192.168.48.28` | Vintage Story |

When adding a new `LoadBalancer` service, pick an unused IP from the `192.168.48.20–50` pool and annotate with:
```yaml
annotations:
  lbipam.cilium.io/ips: "192.168.48.XX"
```

## ExternalSecret Pattern (Bitwarden)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
    - secretKey: MY_KEY
      remoteRef:
        key: "<bitwarden-uuid>" #gitleaks:allow #MY_KEY_NAME
```

Mark UUID lines with `#gitleaks:allow #KEY_NAME` to suppress secret scanning false positives.

**ESO template expressions inside Helm `templates/`** — Helm processes the file first, so wrap
`{{ }}` in Go raw string literals to pass them through untouched:

```yaml
MY_VALUE: "{{ `{{ .MY_KEY }}` }}"
```

## Common Template Patterns

Templates in `templates/` are plain Kubernetes YAML (when using Helm chart wrappers they may use Go templating).

### Secret injection via argocd-secret-replacer

The `secret-replacer` CMP plugin replaces `<secret:key>` tokens at sync time using values from the
mounted `cluster-secrets` K8s Secret. Requires `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`.

```yaml
# Plain string (e.g. in values.yaml or an Ingress host)
host: myapp.<secret:private-domain>
```

Note: `<secret:key|base64>` tokens are no longer used — K8s Secret data fields are handled by
per-app ExternalSecrets instead.

### TLS Certificate (cert-manager)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-cert
  annotations:
    argocd.argoproj.io/sync-wave: "-2"   # create cert before the app
spec:
  secretName: myapp-cert
  issuerRef:
    name: lets-encrypt-dns01-production-cf
    kind: ClusterIssuer
  commonName: "myapp.<secret:private-domain>"
  dnsNames:
    - "myapp.<secret:private-domain>"
```

The ClusterIssuer `lets-encrypt-dns01-production-cf` is created by cert-manager in the `system` category.

### HTTPRoute — Internal (AdGuard DNS, home network only)

Attach to `envoy-internal` (192.168.48.21). AdGuard Home resolves the hostname internally.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

### HTTPRoute — External (Cloudflare DNS + Tunnel, internet-facing)

Attach to `envoy-external` (192.168.48.20). Traffic enters via Cloudflare Tunnel; Cloudflare DNS is updated automatically.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-external
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

### HTTPRoute — Both internal and external

Attach to both gateways. Each external-dns instance only processes routes for its own gateway
(`--gateway-name` filter), so `dns-controller` is the correct annotation for both.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-external
      namespace: envoy-gateway
      sectionName: https
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

> **DNS routing summary — two-tier annotation system**
>
> **HTTPRoutes** always use `controller: dns-controller` (required by the external-dns
> `gateway-httproute` source internally). Which DNS backend processes the route is determined
> by which gateway it attaches to — `envoy-internal` → AdGuard, `envoy-external` → Cloudflare.
>
> **DNSEndpoints** (static records) use `controller: internal` or `controller: external` to
> target a specific external-dns instance directly.
>
> | Annotation value | Processed by | Used on |
> |-----------------|-------------|---------|
> | `dns-controller` | adguard-dns (envoy-internal routes) or cloudflare-dns (envoy-external routes) | HTTPRoutes |
> | `internal` | adguard-dns only | DNSEndpoints |
> | `external` | cloudflare-dns only | DNSEndpoints |

TLS is terminated at the gateway using the wildcard `cert-production` secret — no per-app Certificate resource needed.

## Do Not Edit (Generated/Auto-managed Files)

| File/Directory | Managed By | How to Update |
|----------------|-----------|---------------|
| `provision/talos/clusterconfig/` | `talhelper` | Run `task talos:generate` after editing `talconfig.yaml` |
| `provision/talos/clusterconfig/talosconfig` | `talhelper` | Same as above |
| Lines prefixed `# renovate: datasource=...` in any file | Renovate bot | Do not manually bump — Renovate opens PRs automatically |
| `.terraform.lock.hcl` | Terraform | Run `task terraform:init:cloudflare` or `task terraform:upgrade:cloudflare` |

The Renovate comment pattern marks the **line immediately below** as an auto-managed version string:

```yaml
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
talosVersion: v1.11.3   # ← do not change manually
```

## Branch & PR Workflow

- **Main branch**: `main` — all PRs target this branch
- **Branch naming convention**: `feat/`, `fix/`, `chore/` prefixes (e.g. `chore/overhaul`, `feat/add-app`)
- **CI on PRs**: MegaLinter runs (yamllint, markdownlint, prettier, kubeval, secretlint, actionlint, terraform fmt)
- **Labels required**: PRs must have a label applied — `meta-enforce-labels` workflow blocks merge without one
- **CODEOWNERS**: All files owned by `@mmalyska` — review is required

### Renovate auto-merge rules

| Condition | Auto-merge |
|-----------|-----------|
| Pre-commit hook minor/patch updates | Yes (direct branch merge) |
| Devcontainer digest updates | Yes (direct branch merge) |
| Cluster app patch/digest updates (outside `cluster/core/`) | Yes (via PR after CI passes) |
| `cluster/core/` changes, major updates | No — manual review required |

When Renovate opens a PR you don't need to update versions manually — just review and merge (or let auto-merge handle it).

## Linting & Formatting

```sh
task lint:yaml        # yamllint
task lint:markdown    # markdownlint
task format:yaml      # prettier (YAML)
task format:markdown  # prettier (Markdown)
```

Linter configs: `.github/linters/` (`.yamllint.yaml`, `.markdownlint.yaml`, `.prettierrc.yaml`)

## Security

**Never store secrets, credentials, tokens, API keys, or other sensitive data in:**
- This file (`CLAUDE.md`)
- Memory files (`.claude/MEMORY.md`)
- Any committed file in this repository
- GitHub Actions workflow files (use GitHub Secrets instead)

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
