# CLAUDE.md — home-ops Repository Guide

## Project Overview

GitOps home-lab repository managing a Talos Linux Kubernetes cluster with ArgoCD and SOPS encryption.

- **Hardware**: 3x Lenovo M720q (mc1/mc2/mc3) as control plane nodes at 192.168.48.2-4
- **OS**: Talos Linux (managed via `talhelper` + `talconfig.yaml`)
- **GitOps**: ArgoCD with ApplicationSet pattern + KSOPS plugin for secret decryption
- **Secrets**: SOPS (Age encryption) + Bitwarden Secrets Manager (BWS) for env vars
- **DNS/Tunnel**: Cloudflare managed via Terraform

## Repository Structure

```
cluster/                        # All Kubernetes manifests (ArgoCD managed)
  bootstrap-application.yaml   # Root app-of-apps entry point
  projects/                    # ArgoCD AppProject definitions (5 categories)
  appsets/                     # ArgoCD ApplicationSets (scan app-config.yaml files)
  apps/                        # Applications organized by category
    core/                      #   cilium, argocd, rook-ceph
    system/                    #   traefik, cert-manager, monitoring, keycloak, external-secrets...
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
├── secret.sec.yaml      # SOPS-encrypted secrets (optional)
└── templates/           # Additional K8s manifests (ingress, certificates...)
```

Alternatively, Kustomize-based apps use `kustomization.yaml` instead of `Chart.yaml`.

Multi-component apps (e.g., `rook-ceph`, `intel`) use `appSubfolder` in `app-config.yaml` to deploy from subdirectories.

### app-config.yaml Key Fields

```yaml
- enabled: "true"                          # Toggle deployment
  namespace: my-namespace
  appSubfolder: subfolder-name             # Optional: for multi-component apps
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:                                  # Optional: SOPS decryption
    env:
      - name: SOPS_SECRET_FILE
        value: secret.sec.yaml
```

## Secrets Management

- **SOPS** with Age encryption. Config in `.sops.yaml`.
- `*.sec.yaml` files: encrypts only `data`/`stringData` fields (used for Kubernetes Secrets)
- `*.sops.yaml` files: fully encrypted
- ArgoCD decrypts via KSOPS plugin (`cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`)
- **Never commit unencrypted secret files** — pre-commit hook (gitleaks) checks for this
- Environment secrets (BWS): loaded via `.envrc` using `bws secret list`

## Core Infrastructure

| Component | Purpose |
|-----------|---------|
| **Cilium** | CNI, kube-proxy replacement, L2 announcements for LoadBalancer IPs |
| **Traefik** | Ingress controller |
| **cert-manager** | TLS certificates via Cloudflare DNS01 |
| **Rook-Ceph** | Primary persistent storage |
| **NFS subdir provisioner** | Cold storage on QNAP NAS |
| **Keycloak** | OIDC identity provider (configured in Talos kube-apiserver) |
| **External Secrets Operator** | Kubernetes secret sync from Bitwarden |
| **kube-prometheus-stack** | Prometheus + Grafana monitoring |
| **CloudNative-PG** | PostgreSQL operator |
| **VolSync** | PVC backup/restore |
| **Cloudflared** | Cloudflare Tunnel client |

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

# Cluster bootstrap
task bootstrap:kubernetes             # Full cluster bootstrap

# ArgoCD
task argocd:login                     # Login to ArgoCD with SSO
task argocd:sync                      # Sync ArgoCD applications

# Terraform
task terraform:plan:cloudflare        # Preview Cloudflare DNS changes
task terraform:apply:cloudflare       # Apply Cloudflare DNS changes

# Maintenance
task kubernetes:delete-failed-pods    # Clean up failed/evicted pods
task lint:all                         # Run all linters
task format:all                       # Format YAML and markdown files
```

## Development Environment

Uses a devcontainer (`ghcr.io/mmalyska/home-ops-devcontainer:main`). On container start:
1. `.envrc` is sourced via direnv (sets `KUBECONFIG`, `TALOSCONFIG`, BWS secrets)
2. Pre-commit hooks are initialized
3. Task subtasks are initialized

Required secrets for devcontainer: `SOPS_AGE_KEY`, `TERRAFORM_TOKEN`

## CI/CD

- **Renovate**: Automated dependency updates (Helm charts, container images, Talos/K8s versions)
- **GitHub Actions**: lint, YAML diff on PR, devcontainer publish, GitHub Pages publish
- **Pre-commit**: yamllint, helmlint, gitleaks, prettier, sops-check

## Adding a New Application

1. Create directory `cluster/apps/{category}/{app-name}/`
2. Create `app-config.yaml` with `enabled: "true"`, namespace, and sync policy
3. Add `Chart.yaml` with Helm chart dependency (or `kustomization.yaml`)
4. Add `values.yaml` with customizations
5. If secrets needed: create `secret.sec.yaml`, encrypt with `sops -e -i secret.sec.yaml`, add plugin config to `app-config.yaml`
6. Add any extra manifests in `templates/`
7. Commit — ArgoCD ApplicationSet will auto-discover the new app

## Network Topology

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
| `192.168.50.1` | Router/gateway |
| `192.168.50.8` | QNAP NAS (NFS + S3 storage) |
| `192.168.50.9` | RPI — AdGuard Home DNS + Home Assistant proxy target |

**Known assigned LoadBalancer IPs** (set via `io.cilium/lb-ipam-ips` annotation):

| IP | Service |
|----|---------|
| `192.168.48.20` | Envoy Gateway |
| `192.168.48.21` | Traefik ingress |
| `192.168.48.23` | Minecraft Bedrock |
| `192.168.48.27` | Home automation services (Ollama, Whisper, Piper, OpenWakeWord) |
| `192.168.48.28` | Vintage Story |

When adding a new `LoadBalancer` service, pick an unused IP from the `192.168.48.20–50` pool and annotate with:
```yaml
annotations:
  io.cilium/lb-ipam-ips: "192.168.48.XX"
```

## Editing Encrypted Secrets

The `SOPS_AGE_KEY` environment variable must be set (loaded automatically in the devcontainer from the `SOPS_AGE_KEY` devcontainer secret).

```sh
# Edit a secret interactively (decrypts → opens $EDITOR → re-encrypts on save)
sops cluster/apps/system/traefik/secret.sec.yaml

# Decrypt to stdout (for inspection only — do not commit decrypted output)
sops -d cluster/apps/system/traefik/secret.sec.yaml

# Encrypt a newly created plaintext file in-place
sops -e -i cluster/apps/my-app/secret.sec.yaml
```

**Creating a new secret file:**
1. Write a standard Kubernetes Secret manifest to `secret.sec.yaml` (plaintext)
2. Run `sops -e -i secret.sec.yaml` — encrypts only `data`/`stringData` fields per `.sops.yaml`
3. Add the plugin block to `app-config.yaml` so ArgoCD decrypts it at sync time
4. Verify the file is encrypted before committing (`sops -d` should show decrypted content)

**Never** leave a plaintext secret file on disk — gitleaks pre-commit hook will catch it, but encryption is the real protection.

## Common Template Patterns

Templates in `templates/` are plain Kubernetes YAML (when using Helm chart wrappers they may use Go templating).

### Secret injection via KSOPS replacer

The ArgoCD KSOPS plugin replaces `<secret:key>` tokens at sync time using values from the app's `secret.sec.yaml`:

```yaml
# Plain string (e.g. in values.yaml or an Ingress host)
host: myapp.<secret:private-domain>

# Base64-encoded value (required for Kubernetes Secret `data` fields)
data:
  MY_KEY: <secret:my_key|base64>
```

**Checksum annotation** — add this to a Deployment/StatefulSet to force pod restart when secrets change:
```yaml
annotations:
  checksum/secrets: {{ .Files.Get "secret.sec.yaml" | sha256sum }}
```

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

### Standard Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  tls:
    - hosts:
        - myapp.<secret:private-domain>
      secretName: myapp-cert
  rules:
    - host: myapp.<secret:private-domain>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp
                port:
                  name: http
```

### Traefik IngressRoute (alternative to Ingress)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: myapp
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`myapp.<secret:private-domain>`)
      kind: Rule
      services:
        - name: myapp
          port: 80
  tls:
    secretName: myapp-cert
```

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
