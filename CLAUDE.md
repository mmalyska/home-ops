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

## Linting & Formatting

```sh
task lint:yaml        # yamllint
task lint:markdown    # markdownlint
task format:yaml      # prettier (YAML)
task format:markdown  # prettier (Markdown)
```

Linter configs: `.github/linters/` (`.yamllint.yaml`, `.markdownlint.yaml`, `.prettierrc.yaml`)
