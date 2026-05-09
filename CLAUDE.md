## Core Principles

### Skills-First Workflow

**EVERY user request follows this sequence:**

Request → Load Skills → Gather Context → Execute

Skills contain critical workflows and protocols not in base context.
Loading them first prevents missing key instructions.

### Context Management Strategy

**Central AI should conserve context to extend pre-compaction capacity**:

- Delegate file explorations and low-lift tasks to sub-agents
- Reserve context for coordination, user communication, and strategic decisions
- For straightforward tasks with clear scope: skip heavy orchestration, execute directly

**Sub-agents should maximize context collection**:

- Sub-agent context windows are temporary
- After execution, unused capacity = wasted opportunity
- Instruct sub-agents to read all relevant files, load skills, and gather examples

### Routing Decision

**Direct Execution**:

- Simple/bounded task with clear scope
- Single-component changes
- Quick fixes and trivial modifications

**Sub-Agent Delegation**:

- Complex/multi-phase implementations
- Tasks requiring specialized domain expertise
- Work that benefits from isolated context

**Master Orchestrator**:

- Ambiguous requirements needing research
- Architectural decisions with wide impact
- Multi-day features requiring session management

## Coding Best Practices

**Priority Order** (when trade-offs arise):
Correctness > Maintainability > Performance > Brevity

### Task Complexity Assessment

Before starting, classify:

- **Trivial** (single file, obvious fix) → execute directly
- **Moderate** (2-5 files, clear scope) → brief planning then execute
- **Complex** (architectural impact, ambiguous requirements) → full research first

Match effort to complexity. Don't over-engineer trivial tasks or under-plan complex ones.

### Integration Safety

Before modifying any feature:

- Identify all downstream consumers using codebase search
- Validate changes against all consumers
- Test integration points to prevent breakage

## Project Overview

GitOps home-lab repository managing a Talos Linux Kubernetes cluster with ArgoCD and Bitwarden-based secret management.

- **Hardware**: 3x Lenovo M720q (mc1/mc2/mc3) as control plane nodes at 192.168.48.2-4
- **OS**: Talos Linux (managed via `talhelper` + `talconfig.yaml`)
- **GitOps**: ArgoCD with ApplicationSet pattern + `argocd-secret-replacer` CMP plugin for token substitution
- **Secrets**: Bitwarden Secrets Manager (via ESO `ClusterSecretStore`) + BWS env vars via `.envrc`
- **DNS/Tunnel**: Cloudflare managed via Terraform

## Repository Structure

```
cluster/
  bootstrap-application.yaml   # Root app-of-apps entry point
  projects/                    # ArgoCD AppProject definitions
  appsets/                     # ArgoCD ApplicationSets
  apps/                        # Applications by category: core, system, default, games, home-automation
provision/
  talos/                       # talconfig.yaml, talsecret.yaml, clusterconfig/
  terraform/cloudflare/        # Cloudflare DNS, tunnels, firewall rules
charts/                        # Local Helm charts
docs/                          # MkDocs documentation
.taskfiles/                    # Task automation modules
```

## Application Pattern

Each app lives at `cluster/apps/{category}/{app-name}/`:

```
app-name/
├── app-config.yaml      # ArgoCD ApplicationSet config (enabled: "true|false")
├── Chart.yaml           # Helm chart + external dependencies
├── values.yaml          # Helm values customization
└── templates/           # Additional K8s manifests
```

Kustomize-based apps use `kustomization.yaml` instead of `Chart.yaml`. Multi-component apps use `appSubfolder` in `app-config.yaml`.

### app-config.yaml Key Fields

```yaml
- enabled: "true"
  namespace: my-namespace
  appSubfolder: subfolder-name             # Optional: for multi-component apps
  syncWave: "-5"                           # Optional: lower = deploys first
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:                                  # Optional: enable <secret:key> token substitution
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

## Secrets Management

Two mechanisms — choose based on where the secret value is used:

1. **`cluster-secrets` mount** — for `<secret:key>` tokens in non-injectable fields (hostnames, cert dnsNames, ConfigMap values, `values.yaml` strings). Set `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`.
2. **Per-app `ExternalSecret`** — for credentials that end up in K8s `Secret` `data`/`stringData` fields. Use `ClusterSecretStore` named `bitwarden`.

**The rule**: token in `Secret data/stringData` → ExternalSecret. Token in any other field → `cluster-secrets` + plugin.

**Never commit secret values** to any file — gitleaks pre-commit hook checks for this.

For step-by-step instructions and YAML templates, load the **add-app skill** (`@.claude/skills/learned/add-app.md`).

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

- Managed with `talhelper` from `provision/talos/talconfig.yaml`
- Current versions: Talos v1.11.3, Kubernetes v1.34.5 (updated by Renovate)
- 3 control plane nodes (scheduling enabled on control plane, no dedicated workers)
- Custom extensions: `siderolabs/i915`, `siderolabs/intel-ucode`, `siderolabs/nut-client`
- OIDC on kube-apiserver pointing to Keycloak

## Key Tasks

```sh
task --list                           # Full task list

# Talos
task talos:generate                   # Regenerate Talos machine configs
task talos:apply                      # Apply config to nodes (NODE= env var)
task talos:upgrade:all                # Upgrade Talos OS on all nodes
task talos:upgrade:k8s                # Upgrade Kubernetes version

# Cluster bootstrap
task bootstrap:kubernetes             # Full automated bootstrap
task bootstrap:rook-sync              # Post-bootstrap: sync Rook Ceph (run after argocd:login)

# ArgoCD
task argocd:login                     # Login (--sso; use local admin on first bootstrap)
task argocd:sync                      # Sync ArgoCD applications

# Terraform
task terraform:plan:cloudflare
task terraform:apply:cloudflare
```

Bootstrap sequence and design decisions: `@docs/src/k8s/bootstrap.md`.

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

## Network Topology

Node subnet: `192.168.48.0/22` · Pod network: `10.244.0.0/16` · Service network: `10.96.0.0/12`
LB IP pool: `192.168.48.20–50` (annotate new services with `lbipam.cilium.io/ips: "192.168.48.XX"`)

Full IP allocation and gateway architecture: `@docs/src/general/network.md`.

## Do Not Edit (Generated/Auto-managed Files)

| File/Directory | Managed By | How to Update |
|----------------|-----------|---------------|
| `provision/talos/clusterconfig/` | `talhelper` | `task talos:generate` |
| Lines prefixed `# renovate: datasource=...` | Renovate bot | Do not manually bump |
| `.terraform.lock.hcl` | Terraform | `task terraform:init:cloudflare` |

## Branch & PR Workflow

- **Main branch**: `main` — all PRs target this branch
- **Branch naming**: `feat/`, `fix/`, `chore/` prefixes
- **CI on PRs**: MegaLinter (yamllint, markdownlint, prettier, kubeval, secretlint, actionlint, terraform fmt)
- **Labels required**: PRs must have a label — `meta-enforce-labels` blocks merge without one
- **CODEOWNERS**: All files owned by `@mmalyska`

## Linting & Formatting

```sh
task lint:all
task format:all
```

## Security

**Never store secrets, credentials, tokens, API keys, or other sensitive data in:**
- This file (`CLAUDE.md`)
- Memory files (`.claude/MEMORY.md`)
- Any committed file in this repository
- GitHub Actions workflow files (use GitHub Secrets instead)

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** to avoid hanging on confirmation prompts (`cp`, `mv`, `rm` may be aliased to `-i` mode).

```bash
cp -f source dest
mv -f source dest
rm -f file
rm -rf directory
cp -rf source dest
```
