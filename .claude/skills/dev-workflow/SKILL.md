---
name: dev-workflow
description: >
  Task commands, bootstrap sequence, CI/CD, branch/PR workflow, linting, and
  devcontainer setup for the home-ops repository.
when_to_use: >
  Trigger phrases: "task command", "task list", "bootstrap", "lint", "format",
  "CI", "PR workflow", "branch name", "devcontainer", "direnv", "pre-commit",
  "renovate update", "argocd login", "terraform apply", "stuck sync", "terminate-op",
  "sync waiting for healthy state".
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
task bootstrap:rook-sync              # Post-bootstrap fallback: sync Rook Ceph if its auto-sync failed (run after argocd:login)

# ArgoCD
task argocd:login                     # Login (--sso; use local admin on first bootstrap)
task argocd:sync                      # Sync ArgoCD applications          # See local file:// chart gotcha below

# Terraform
task terraform:init:cloudflare           # Once per worktree (backend + providers)
task terraform:fmt:cloudflare            # fmt -check -diff, writes nothing
task terraform:format:cloudflare         # fmt, writes files
task terraform:validate:cloudflare
task terraform:plan:cloudflare
task terraform:apply:cloudflare          # Local/manual only -- see note below

# Lint / Format (advisory: always exits 0, read the output; CI is the gate)
task lint:all
task lint:manifests -- [app ...]         # render like ArgoCD, kubeconform, promtool (about 1 min)
task lint:api-versions                   # refresh the cluster API list the renders use (reads the cluster)
task format:all
```

Bootstrap sequence and design decisions: `@docs/src/k8s/bootstrap.md`.

## Development Environment

Uses a devcontainer on the shared `dev-workstation` image (`ghcr.io/mmalyska/dev-workstation`, pinned by digest in `.devcontainer/devcontainer.json`, built in `mmalyska/containers`; tools are pinned with mise in that repository). The image has no Homebrew and no sudo. On container start:
1. `.envrc` is sourced via direnv (sets `KUBECONFIG`, `TALOSCONFIG`, BWS secrets)
2. Pre-commit hooks are initialized
3. Task subtasks are initialized

Required secrets for devcontainer: `TERRAFORM_TOKEN`

### HCP Terraform (Cloudflare workspace)

The `provision/terraform/cloudflare` workspace is VCS-connected to this repo in HCP Terraform (app.terraform.io) with **auto-apply enabled** — merging a PR that touches `provision/terraform/cloudflare/**` to `main` triggers the apply automatically. `task terraform:apply:cloudflare` is only needed for local/manual runs (e.g. testing before opening a PR); don't run it after merging, HCP Terraform already handles it.

Terraform looks up the HCP token as `TF_TOKEN_app_terraform_io`, but the devcontainer provides it as `TERRAFORM_TOKEN`. The `terraform:*` tasks map one to the other (`.taskfiles/terraform.yml`), so prefer them. A raw `terraform` command needs the mapping inline, or `terraform init` fails with "Required token could not be found":
```sh
TF_TOKEN_app_terraform_io="$TERRAFORM_TOKEN" terraform <command>
```
Never echo or print the token.

MegaLinter runs `terraform fmt` only on the files a PR changes, so an unformatted file nobody touches stays unformatted. Run `task terraform:fmt:cloudflare` over the whole folder before a Terraform PR.

**Gotcha:** `.terraform.lock.hcl` is gitignored (local-only) and its init state is per-directory — each git worktree has its own, independent of the main checkout. If `main.tf`'s provider version constraint was bumped (e.g. by a Renovate PR) since you last ran `terraform init` *in that specific working directory*, you'll get "locked provider ... does not match configured version constraint" on both local and remote (CLI-driven) runs. Fix: `TF_TOKEN_app_terraform_io="$TERRAFORM_TOKEN" terraform init -upgrade` from `provision/terraform/cloudflare/` in the worktree you're actually working in.

### Local `file://` Helm chart dependencies (ArgoCD stale-cache gotcha)

Several apps depend on local charts via `repository: file://../../.../charts/<name>/` (`pgsql-cnpg`, `anytype`, `onlyoffice-documentserver`, etc.). ArgoCD's repo-server caches these by `name@version` from `Chart.yaml`. **Editing a local chart's `values.yaml` or templates without bumping its `Chart.yaml` `version` field will not actually take effect through ArgoCD** — the repo-server keeps serving a stale packaged copy from before your edit, even though `git diff`, `helm template` locally, and ArgoCD's own "Synced" status all look correct. This was hit twice in a row while tuning `onlyoffice-documentserver`'s memory limits: the live Deployment kept the old values from an earlier PR despite a newer PR merging and syncing cleanly.

**Rule:** any change to a local `file://` chart's content requires bumping its `Chart.yaml` `version` *and* the matching `version:` in every parent chart's `dependencies:` entry that references it, or the change silently won't apply in the cluster. Always verify with `kubectl get deployment <name> -o jsonpath='{.spec.template.spec.containers[0].resources}'` (or the relevant field) after a sync that should have changed a local-chart-sourced value — don't trust ArgoCD's Synced/Healthy status alone for these.

### Removing a field ArgoCD cannot prune (`ApplyOutOfSyncOnly=true`)

When an app has `ApplyOutOfSyncOnly=true` and a field was added by the `argocd-controller` `Update` field manager, deleting that field from git does not remove it from the live object: the app still shows Synced. Seen on the Rook `CephCluster` `spec.monitoring.interval` (2026-10-23). Fix: remove the field live with `kubectl patch <kind> <name> --type json -p '[{"op":"remove","path":"..."}]'` (needs consent), keep git without the field, and check the live object afterwards. Operators may also have written related state elsewhere (Rook set `mgr/prometheus/scrape_interval`), so revert that too.

### Stuck sync: a fix merges but never deploys

Argo CD runs one operation per app. An automated sync whose new manifests never become healthy (a crash-looping
DaemonSet, a Deployment that never becomes ready) stays `Running` indefinitely, so the sync of the fix cannot start: the
app shows `OutOfSync` on the fix's revision while the live object keeps the broken spec. Seen on 2026-11-27: the
kube-prometheus-stack 94.1.0 bump crash-looped node-exporter, and the fix (#6490) waited until the owner stepped in.

Check (read-only): the running operation targets the old revision and waits for health.

```sh
argocd app get <app> -o json | jq -r '.status.operationState
  | "\(.phase) rev=\(.operation.sync.revision[0:7]) started=\(.startedAt) msg=\(.message)"'
# Running rev=<old> ... msg=waiting for healthy state of apps/DaemonSet/<name>
```

Fix: stop the operation, then sync the fix. Both are RUNTIME_MUTATION and need consent for each action.

```sh
argocd app terminate-op <app>
argocd app sync <app> --async   # automated sync may not start by itself after the terminate
```

- The workspace token may do both on every app except the exclusions in `docs/src/k8s/dev-workspace.md` (`core/*`,
  `root-app`, access control, the workspaces, storage operators). For those, the owner runs them. A `permission denied`
  error means an excluded app: stop and ask, do not retry.
- Never add `--prune`, `--replace` or `--force` to unblock a sync: they are DESTRUCTIVE and the owner's action.
- Check the exit code of each command before the next (`terminate-op` then `sync`), not one pipeline that hides a failure.
- Afterwards: `Synced`/`Healthy` on the fix's revision, the workload rolled out, and its Prometheus targets `up`. The
  dead pods' last `up=0` stays visible for up to 5 minutes, so an alert such as `TargetDown` can outlast the fix briefly.

### Manifest lint (`task lint:manifests`)

`.taskfiles/lint/resources/check-manifests.sh` renders every enabled app the way the ArgoCD CMP does (`render-apps.sh`:
`helm template` in place with the app's release name and namespace, or `kustomize build`), then:

- replaces `<secret:...>` tokens with placeholders (`<secret:private-domain>` becomes `example.com`), so schema patterns see a plausible value;
- runs kubeconform in strict mode. Schemas come from kubeconform's default Kubernetes source (v1.34.12, the newest it
  publishes), then from the CRDs in our own renders (`crd2schema.py`), then the datree CRDs-catalog. A missing schema is
  an error; a kind with no schema anywhere goes into `kubeconform-skip.txt` with a comment;
- runs `promtool check rules` on every PrometheusRule, and `promtool test rules` for each app folder with
  `tests/*.promtool.yaml` (the tests reference `rule_files: [rules.yaml]`, which the script writes from the app's
  rendered rules; see `cluster/apps/ai/litellm/tests/`).

App names narrow the checks, but every app is still rendered: an app's custom resources can take their schema from
another app's CRDs. The task exits 0 like every `lint:*` task; the `Manifest lint` workflow runs the same script in the
`dev-workstation` image and fails the PR. Set `KEEP_TMP=1` to keep the rendered output.

**API versions file.** `--api-versions` comes from the committed `.taskfiles/lint/resources/kube-api-versions.txt` (CI
cannot reach the cluster); its header sets `--kube-version`. Refresh it with `task lint:api-versions` after a Kubernetes
upgrade or when an app adds or removes CRDs. It needs `group/version/Kind` lines, not only `group/version`: bjw-s
app-template picks the `HTTPRoute` version by `Capabilities.APIVersions.Has "gateway.networking.k8s.io/v1/HTTPRoute"`,
and without that line it renders `v1alpha2`, which the cluster does not serve.

**PR diff.** The Helm job of `diff-yaml-on-pr.yaml` renders the changed chart on `main` and on the PR with the PR's
`render-apps.sh` and API versions file (`RENDER_INCLUDE_DISABLED=1`, `KUBE_API_VERSIONS_FILE`), so the diff comment
shows what ArgoCD would apply: same release name, namespace, CRDs and API list.

## CI/CD

- **Renovate**: Automated dependency updates (Helm charts, container images, Talos/K8s versions)
- **GitHub Actions**: lint, manifest lint, YAML diff on PR, devcontainer publish, GitHub Pages publish
- **Pre-commit**: yamllint, helmlint, gitleaks, prettier

## Branch & PR Workflow

- **Main branch**: `main` — all PRs target this branch
- **Branch naming**: `feat/`, `fix/`, `chore/`, `docs/` prefixes; work in a linked worktree `.worktrees/<type>/<slug>` (`AGENTS.md`)
- **Validation per change type**: `.agents/policy/validation.md`; PRs use `.github/pull_request_template.md`
- **CI on PRs**: MegaLinter (yamllint, markdownlint, prettier, secretlint, actionlint, terraform fmt); Manifest lint (render, kubeconform, promtool) on PRs touching `cluster/`, `charts/` or `.taskfiles/lint/`
- **Labels required**: PRs must have a label — `meta-enforce-labels` blocks merge without one
