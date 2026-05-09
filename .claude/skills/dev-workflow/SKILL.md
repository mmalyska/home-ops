---
name: dev-workflow
description: >
  Task commands, bootstrap sequence, CI/CD, branch/PR workflow, linting, and
  devcontainer setup for the home-ops repository.
when_to_use: >
  Trigger phrases: "task command", "task list", "bootstrap", "lint", "format",
  "CI", "PR workflow", "branch name", "devcontainer", "direnv", "pre-commit",
  "renovate update", "argocd login", "terraform apply".
---

# Dev Workflow Reference

## Key Tasks

```sh
task --list                           # Full task list

# Talos
task talos:generate                   # Regenerate Talos machine configs
task talos:apply NODE=<ip>            # Apply config to a node
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

# Lint / Format
task lint:all
task format:all
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

## Branch & PR Workflow

- **Main branch**: `main` — all PRs target this branch
- **Branch naming**: `feat/`, `fix/`, `chore/` prefixes
- **CI on PRs**: MegaLinter (yamllint, markdownlint, prettier, kubeval, secretlint, actionlint, terraform fmt)
- **Labels required**: PRs must have a label — `meta-enforce-labels` blocks merge without one
