<!-- markdownlint-disable MD013 -->

# Evidence

Facts the plan rests on, read on 2026-11-02 at `base_sha`. Verify before relying on them; the live cluster was not queried except where stated.

## This repository

- `.github/.devcontainer/Dockerfile` is `mcr.microsoft.com/devcontainers/base:ubuntu24.04` (digest pinned) plus `gnupg2`, `gcc`, `build-essential`.
- `.github/.devcontainer/devcontainer.json` features: `ghcr.io/devcontainers/features/go`, local features `homebrew`, `common`, `bws-cli`, `coder-cli`, `codex-cli`. User `vscode`.
- `.github/workflows/devcontainer-publish.yaml` builds with `devcontainers/ci` on `ubuntu-latest` (amd64) and `ubuntu-24.04-arm` (arm64), merges the manifests, then triggers the scheduled Renovate workflow. It publishes `ghcr.io/mmalyska/home-ops-devcontainer`.
- `.devcontainer/devcontainer.json` consumes that image by digest, declares secrets (`TERRAFORM_TOKEN`, `BWS_ACCESS_TOKEN`, `GITHUB_TOKEN`, `WG_PRIVATE_KEY`, `WG_ENDPOINT`), runs with `--cap-add=NET_ADMIN` and `/dev/net/tun`, and has three lifecycle commands.
- `onCreateCommand.sh`: git `safe.directory`, GPG signing when a key is present, `pull.rebase`, `direnv allow`, `chezmoi init --apply mmalyska/dotfiles`, Codespaces-only WireGuard tools, krew and `browse-pvc`.
- `updateContentCommand.sh`: `git gc`, `task init`, `task precommit:init`, `task cilium:init`, and outside Codespaces `task terraform:upgrade:cloudflare` and `task talos:init`.
- `postStartCommand.sh`: Codespaces-only WireGuard setup, `task talos:init`, and symlinks of `/workspaces/home-ops/.claude/memory/*.md` into `~/.claude/projects/-workspaces-home-ops/memory/`. The path is hard-coded.

## Coder in this repository

- `cluster/apps/ai/coder/` is a Helm app (Coder chart 2.34.0, CNPG database, OIDC). Namespace `coder`, Pod Security `baseline`, `selfHeal: true`, `prune: false`.
- Route: `envoy-internal` only.
- `workspace-template/main.tf`: parameters `workspace_image` (default `sandbox-devops:rolling`), `lb_ip`, `authorized_key`, `storage_size` (default `2Gi`). Agent `arch = "amd64"`. Container runs as UID 0, limits 1000m CPU and 2Gi memory, requests 100m and 128Mi. Home PVC on `ceph-block`. SSH LoadBalancer Service with a Cilium LB-IPAM annotation. VolSync `ReplicationSource` every 6 hours, snapshot copy, retain 6 daily, 4 weekly, 2 monthly. `LITELLM_API_KEY` is read with `secret_key_ref` (optional).
- `cluster/apps/ai/coder/README.md` says the workspace limit is 500m to 1000m CPU, 1 to 2 Gi RAM, 20 Gi PVC, which differs from the template default of `2Gi` storage; the live workspace value was not checked.
- Only the `devops` workspace exists (192.168.48.51); dotnet, node, mobile and researcher were removed on 2026-10-21.

## Hermes

- `cluster/apps/ai/hermes-agent/templates/deployment.yaml` copies `SANDBOX_DEVOPS_SSH_KEY` to `/opt/data/ssh/sandbox-devops.key`, so Hermes SSHes into the `devops` workspace. `hermes-agent` is enabled. `.archive/cluster/ai/README.md` records that four of the five sandbox keys were dropped when Hermes was restored on 2026-10-26.

## Other repositories (GitHub, read via `gh`)

- `mmalyska/containers`: `apps/sandbox-{base,devops,dotnet,node,python}` each with `Dockerfile`, `README.md`, `metadata.json`, `ci/`. Also `.devcontainer/`, `Taskfile.yml`, `metadata.rules.cue`. `sandbox-base` is `ubuntu:26.04` (digest pinned) with openssh-server, curl, wget, git, vim, nano, jq, unzip, ripgrep, fd-find, sudo, locales and a `coder` user with passwordless sudo. `sandbox-devops` adds kubectl, helm (installed by the upstream `get-helm-3` script from the `main` branch), talosctl, terraform, k9s and age, all `amd64` URLs, with Renovate `# renovate:` annotations.
- `mmalyska/dotfiles` is a chezmoi source (`.chezmoiroot`, `home/`, `tests/`).
- `mmalyska/github-workflows` holds reusable workflows (Renovate, Talos image build).
- Other account repositories exist (for example `claude-plugins`, `argocd-secret-replacer`, `renovate-config`, `homelab-portal`); their setup was not inspected.

## Baseline measurement (local devcontainer, one repo, one Claude session)

- `memory.current` 1.6 GiB, `memory.peak` 2.1 GiB, no cgroup limit; the host exposes 24 CPUs. Includes page cache. Largest processes: a 524 MiB main thread (not identified by name), `claude` 355 MiB, `npm` 105 MiB.
- Disk: `/workspaces` 2.8 GB, home 1.8 GB.
- This is a floor, not a forecast: several repositories, `terraform`, `helm` and the VS Code remote server add to it. Task T9 replaces it with measurements from the Coder workspace.

## Findings from the U1, U11 and U12 checks (2026-11-02, read-only via `gh`)

### `mmalyska/containers` pipeline (U1)

- Layout per app: `apps/<name>/{Dockerfile,metadata.json,README.md,ci/latest.sh,ci/goss.yaml}`. `metadata.rules.cue` validates `metadata.json`; accepted platforms are `linux/amd64` and `linux/arm64`. Test type `cli` runs `dgoss` against the built image with `tail -f /dev/null`.
- Build workflow `.github/workflows/action-image-build.yaml`: a channel whose platforms are exactly `["linux/arm64"]` runs on a native `ubuntu-24.04-arm` runner; **any other channel, including a mixed amd64 + arm64 one, runs on `ubuntu-latest` and builds the foreign architecture under QEMU**. For a mixed channel the Goss test build and run use `linux/amd64` only, so **the arm64 image is built but not tested in CI**.
- Tags are `ghcr.io/mmalyska/<app>:rolling` and `:<version>` for the `stable` channel; other channels get `<app>-<channel>`. The version comes from `ci/latest.sh` (`sandbox-devops` prints a constant). Labels passed by the workflow are additive, so a `LABEL devcontainer.metadata=...` in the Dockerfile is preserved.
- PR validation builds changed apps without pushing and needs repository secrets that already exist (`BOT_APP_ID`, `BOT_APP_PRIVATE_KEY`).

### `mmalyska/dotfiles` (U11)

- chezmoi source under `home/` (`.chezmoiroot`). `home/.chezmoi.toml.tmpl` sets `is_devcontainer` when the user is `vscode` or `REMOTE_CONTAINERS`, `CODESPACES` or `DEVCONTAINER` is set. With `is_devcontainer`, `.chezmoiignore` skips the `linux`, `macos` and `windows` package scripts and runs `.chezmoiscripts/devcontainer/*` (today: a peon-ping install by `curl | bash` from the upstream `main` branch). User `vscode` (D13) therefore makes the workspace a devcontainer for chezmoi.
- `home/.chezmoi.toml.tmpl` uses `promptStringOnce`, `promptBoolOnce` and `promptChoiceOnce` (email, name, work machine, AI profile, Claude, Codex, agent teams, OpenCode). A non-interactive bootstrap must pass answers by flag or pre-write the config; the test library keys the prompt flags by prompt text.
- Static data lives in `home/.chezmoidata/*.yaml` (today `ai-workflow.yaml`); AI plugin install scripts run as `run_onchange_after_*` and need the `claude` and `codex` CLIs present.
- **`home/dot_gitconfig.tmpl` configures SSH signing**: `gpg.format = ssh`, `commit.gpgsign = true`, one ed25519 public `signingkey`. This matches this session's git config. `.devcontainer/scripts/onCreateCommand.sh` in home-ops enables GPG signing only when a specific GPG key is present. The repository has its own plan, test and docs conventions (`docs/plans`, `tests/ai`).

### Other repositories (U12)

- Only `home-ops` has an `.envrc`. `claude-plugins`, `dotfiles`, `renovate-config`, `homeinfra` and the rest have neither `.envrc` nor `.devcontainer`.
- `.devcontainer/` exists in: `home-ops`, `containers`, `github-workflows`, `homelab-portal`, `argocd-secret-replacer`, `willow-inference-server-dockerized`, `home-assistant` (contents not inspected; the last two have not been pushed to since 2023-2024).

## Facts added after the review of `80a33912` (2026-11-02)

- `cluster/apps/core/argocd/patches/argocd-rbac-cm.yaml` sets `policy.default` to empty and maps the group `ArgoCDAdmins` and the owner's user to `role:admin`. An SSO session of the owner is therefore admin.
- `cluster/apps/ai/coder/templates/rbac-services.yaml`: the Coder provisioner ServiceAccount has a Role in `coder` that allows create, update, patch and delete on `services`, `externalsecrets` and `replicationsources`, plus a ClusterRole `coder-crd-reader` (get, list on CustomResourceDefinitions).
- `cluster/apps/system/external-secrets/templates/secretstore.yaml`: the ClusterSecretStore `bitwarden` has one credential in the `external-secrets` namespace and no namespace `conditions`, so an `ExternalSecret` in any namespace can use it.
- `Taskfile.yml` (`task init`) runs `brew bundle` against `.github/.devcontainer/local-features/common/Brewfile` and has preconditions on `brew` and on that file. The Brewfile lists: direnv, egctl, gitleaks, go-task, helm, ipcalc, jq, kubectl, kustomize, prettier, stern, terraform (hashicorp tap), yamllint, yq, argocd, kubelogin, k9s, pre-commit, mkdocs, gh, helmfile, chezmoi, node. `.devcontainer/scripts/onCreateCommand.sh` runs `chezmoi` through `/home/linuxbrew/.linuxbrew/bin/`.
- `.github/linters/.markdownlint.yaml`: `MD013` line length 240, tables and code blocks included. Other plan files carry `<!-- markdownlint-disable MD013 -->`.
- PR #6059 at `80a33912`: seven checks listed by `gh pr checks`, all passing; the Lint job log contains 114 `MD013` errors (112 in the plan files).

## Facts added after the second review (`887cdca4`, 2026-11-02)

- `cluster/apps/core/argocd/kustomization.yaml` pins the ArgoCD install manifests at `v3.5.6`.
- [ArgoCD RBAC documentation](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/): `application.sync.requireOverridePrivilegeForRevisionSync` in `argocd-cm`, new since v3.2, default `'false'`; with it on, passing a revision to a sync needs the `override` action. Application actions: get, create, update, delete, sync, action, override.
- CI for PR #6059 at `887cdca4`: Enforce PR labels, Helm Lint, Instruction checks, Label Size, Labeler, Lint and No Claude attribution all pass; the Lint job log contains no `MD0xx` lines.
- Local run of `bash .agents/tests/run.sh` in the worktree: 165 tests, 0 failed.
