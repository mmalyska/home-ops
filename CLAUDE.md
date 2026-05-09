## Core Principles

**Skills-first**: Every request — load relevant skills before gathering context or executing.

**Framework improvement**: Update a skill when a workaround was needed or a better approach was found. Create a new skill when the same domain context is needed across 2+ sessions. Prompt user: "This pattern seems reusable — should I update [skill] or create a new one?"

**Routing**: Direct for trivial/single-file. Sub-agent for complex/multi-phase. Orchestrator for ambiguous or architectural. Sub-agents: read all relevant files and load skills — unused context is wasted capacity.

**Complexity**: Trivial → execute. Moderate → brief plan then execute. Complex → research first. Priority: Correctness > Maintainability > Performance > Brevity.

## Project Overview

GitOps home-lab: Talos Linux Kubernetes cluster managed via ArgoCD and Bitwarden secrets.

- **Hardware**: 3x Lenovo M720q (mc1/mc2/mc3) control plane nodes at 192.168.48.2-4
- **GitOps**: ArgoCD ApplicationSet pattern + `argocd-secret-replacer` CMP plugin for token substitution
- **Secrets**: Bitwarden Secrets Manager (ESO `ClusterSecretStore`) + BWS env vars via `.envrc`
- **DNS/Tunnel**: Cloudflare via Terraform

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

Never commit secret values — gitleaks pre-commit hook checks for this.

For step-by-step instructions and YAML templates, use the **add-app skill**.

## Security

Never store secrets, credentials, tokens, or API keys in any committed file — use GitHub Secrets for Actions workflows.
