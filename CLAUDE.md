# Claude Code Instructions

## Core Principles

**Skills-first**: Every request — load relevant skills before gathering context or executing.

**Framework improvement**: Update a skill when a workaround was needed or a better approach was found. Create a new skill when the same domain context is needed across
2+ sessions. Prompt user: "This pattern seems reusable — should I update [skill] or create a new one?"

## Project Overview

Personal home-lab running self-hosted services (media, home automation, observability, AI tools) on a Talos Linux Kubernetes cluster, managed declaratively via GitOps with ArgoCD and Bitwarden secrets.

- **Hardware**: 3x Lenovo M720q (mc1/mc2/mc3) control plane nodes at 192.168.48.2-4
- **GitOps**: ArgoCD ApplicationSet pattern + `argocd-secret-replacer` CMP plugin for token substitution
- **Secrets**: Bitwarden Secrets Manager (ESO `ClusterSecretStore`) + BWS env vars via `.envrc`
- **DNS/Tunnel**: Cloudflare via Terraform

## Repository Structure

```text
cluster/
  bootstrap-application.yaml   # Root app-of-apps entry point
  projects/                    # ArgoCD AppProject definitions
  appsets/                     # ArgoCD ApplicationSets
  apps/                        # Applications by category: core, system, default, games, home-automation
provision/
  talos/                       # templates/, nodes/, nodes.yaml, clusterconfig/
  terraform/cloudflare/        # Cloudflare DNS, tunnels, firewall rules
charts/                        # Local Helm charts
docs/                          # MkDocs documentation
.taskfiles/                    # Task automation modules
```

## Application Pattern

Each app lives at `cluster/apps/{category}/{app-name}/`:

```text
app-name/
├── app-config.yaml      # ArgoCD ApplicationSet config (enabled: "true|false")
├── Chart.yaml           # Helm chart + external dependencies
├── values.yaml          # Helm values customization
└── templates/           # Additional K8s manifests
```

Kustomize-based apps use `kustomization.yaml` instead of `Chart.yaml`. Multi-component apps use `appSubfolder` in `app-config.yaml`.

Key `app-config.yaml` fields: `enabled`, `namespace`, `appSubfolder` (multi-component), `syncWave` (lower deploys first), `syncPolicy` (selfHeal/prune),
and `plugin.env` with `SECRET_PROVIDER: cluster-secrets` to enable `<secret:key>` token substitution. For full YAML templates use the **add-app skill**.

## Secrets Management

Two mechanisms — choose based on where the secret value is used:

1. **`cluster-secrets` mount** — for `<secret:key>` tokens in non-injectable fields (hostnames, cert dnsNames, ConfigMap values, `values.yaml` strings). Set `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`.
2. **Per-app `ExternalSecret`** — for credentials that end up in K8s `Secret` `data`/`stringData` fields. Use `ClusterSecretStore` named `bitwarden`.

**The rule**: token in `Secret data/stringData` → ExternalSecret. Token in any other field → `cluster-secrets` + plugin.

Never commit secret values — gitleaks pre-commit hook enforces this.

For step-by-step instructions and full YAML templates, use the **add-app skill**.

## Verification

After any manifest or values change, render before committing:

```sh
helm template <release> . -f values.yaml        # Helm-based apps
kubectl kustomize .                              # Kustomize-based apps
task lint:all                                   # yamllint, helmlint, prettier
```

For task command reference and CI/PR workflow, use the **dev-workflow skill**.

## Plans

Project plans are tracked in `.plans/{plan-name}/` (committed to git):

- `plan.md` — goal, context, key decisions, architecture, current status. Must have enough detail for a new session to continue without this conversation.
- `tasks.md` — self-contained checkbox list. Each item must be executable without reading `plan.md`.
- `.plans/list.md` — one-line entry per active plan.
- `.archive/.plans/` — completed plans moved here verbatim; `.archive/.plans/list.md` is the completed index.
- `.plans/TODO.md` — Claude's scratchpad for out-of-scope ideas worth doing later; never modified by the plan workflow.

**When starting a plan**: create `.plans/{name}/plan.md` and `tasks.md`, add entry to `.plans/list.md`.  
**When completing a plan**: move subfolder to `.archive/.plans/{name}/`, update both `list.md` files.

## Hard Rules

- **Never commit secrets** — no credentials, tokens, or API keys in any tracked file; gitleaks will block the commit.
- **Never mutate cluster state** (kubectl apply/delete, ArgoCD sync, Talos apply) without explicit user confirmation — ask first.
- **Never push to `main` directly** — all changes via PR; branch naming: `feat/`, `fix/`, `chore/` prefixes.
