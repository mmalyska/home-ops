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
task argocd:sync                      # Sync ArgoCD applications          # See local file:// chart gotcha below

# Terraform
task terraform:plan:cloudflare
task terraform:apply:cloudflare          # Local/manual only -- see note below

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

### HCP Terraform (Cloudflare workspace)

The `provision/terraform/cloudflare` workspace is VCS-connected to this repo in HCP Terraform (app.terraform.io) with **auto-apply enabled** — merging a PR that touches `provision/terraform/cloudflare/**` to `main` triggers the apply automatically. `task terraform:apply:cloudflare` is only needed for local/manual runs (e.g. testing before opening a PR); don't run it after merging, HCP Terraform already handles it.

To run `task terraform:plan:cloudflare` (or any local terraform command) against this workspace, the CLI needs a token even though `TERRAFORM_TOKEN` is already set as an env var — export it under the name Terraform's credential lookup expects:
```sh
export TF_TOKEN_app_terraform_io="$TERRAFORM_TOKEN"
```
Without this, `terraform init` fails with "Required token could not be found."

**Gotcha:** `.terraform.lock.hcl` is gitignored (local-only) and its init state is per-directory — each git worktree has its own, independent of the main checkout. If `main.tf`'s provider version constraint was bumped (e.g. by a Renovate PR) since you last ran `terraform init` *in that specific working directory*, you'll get "locked provider ... does not match configured version constraint" on both local and remote (CLI-driven) runs. Fix: `TF_TOKEN_app_terraform_io="$TERRAFORM_TOKEN" terraform init -upgrade` from `provision/terraform/cloudflare/` in the worktree you're actually working in.

### Local `file://` Helm chart dependencies (ArgoCD stale-cache gotcha)

Several apps depend on local charts via `repository: file://../../.../charts/<name>/` (`pgsql-cnpg`, `anytype`, `onlyoffice-documentserver`, etc.). ArgoCD's repo-server caches these by `name@version` from `Chart.yaml`. **Editing a local chart's `values.yaml` or templates without bumping its `Chart.yaml` `version` field will not actually take effect through ArgoCD** — the repo-server keeps serving a stale packaged copy from before your edit, even though `git diff`, `helm template` locally, and ArgoCD's own "Synced" status all look correct. This was hit twice in a row while tuning `onlyoffice-documentserver`'s memory limits: the live Deployment kept the old values from an earlier PR despite a newer PR merging and syncing cleanly.

**Rule:** any change to a local `file://` chart's content requires bumping its `Chart.yaml` `version` *and* the matching `version:` in every parent chart's `dependencies:` entry that references it, or the change silently won't apply in the cluster. Always verify with `kubectl get deployment <name> -o jsonpath='{.spec.template.spec.containers[0].resources}'` (or the relevant field) after a sync that should have changed a local-chart-sourced value — don't trust ArgoCD's Synced/Healthy status alone for these.

## CI/CD

- **Renovate**: Automated dependency updates (Helm charts, container images, Talos/K8s versions)
- **GitHub Actions**: lint, YAML diff on PR, devcontainer publish, GitHub Pages publish
- **Pre-commit**: yamllint, helmlint, gitleaks, prettier

## Branch & PR Workflow

- **Main branch**: `main` — all PRs target this branch
- **Branch naming**: `feat/`, `fix/`, `chore/` prefixes
- **CI on PRs**: MegaLinter (yamllint, markdownlint, prettier, kubeval, secretlint, actionlint, terraform fmt)
- **Labels required**: PRs must have a label — `meta-enforce-labels` blocks merge without one
