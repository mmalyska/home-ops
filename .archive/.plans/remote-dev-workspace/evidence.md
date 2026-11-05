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

## T23: the image in a local devcontainer (2026-11-05)

Scratch folder outside any repository on the owner's Docker host, a `devcontainer.json` with only the `image` (the pinned digest, no `features` block), opened with VS Code "Reopen in Container". The checks ran inside the container as `vscode`; the owner pasted the output. Nothing was committed and the repository's own `.devcontainer` is unchanged.

The agent also read the image config from the registry first (anonymous, no runtime): the digest is a multi-arch index (linux/amd64 and linux/arm64), user `1000:1000`, workdir `/workspaces`, and the label `devcontainer.metadata` holds `remoteUser` and `containerUser` `vscode` and the mount `source=dev-workstation-cache,target=/cache,type=volume`.

| Check | Result | Detail |
| ----- | ------ | ------ |
| The image label mounts the named volume on `/cache` | PASS | `/cache` is a mount point on the Docker volume path `dev-workstation-cache/_data` (ext4); `docker volume ls` on the host lists `dev-workstation-cache`; the label alone did it, with no `mounts` in `devcontainer.json` |
| `/cache` writable by `vscode` | PASS | a test file was created and removed |
| `XDG_CACHE_HOME`, `GOMODCACHE`, `npm_config_cache`, `TF_PLUGIN_CACHE_DIR` resolve under `/cache` | PASS | `/cache`, `/cache/go/mod`, `/cache/npm`, `/cache` |
| A repository `mise.toml` wins after `mise activate bash` | PASS | outside the repository `jq-1.8.2` (the image's pin), inside a directory whose `mise.toml` pins `jq = "1.6"` it prints `jq-1.6` |
| User and layout | PASS | user `vscode`, uid 1000; `/opt/mise` present |

Differences from the image notes: none. Not covered: arm64 (no arm64 host), a `home-ops` checkout inside the container (that is T10), and `mise activate` working in a login shell without the dotfiles (the check ran `bash -ic` for the outside value).

## T10: `home-ops` on the image in a local devcontainer (2026-11-05)

Container started by the owner from the PR branch (#6123), `home-ops` at `/workspaces/home-ops`. The checks ran inside it as `vscode`; the owner pasted the output.

| Check | Result | Detail |
| ----- | ------ | ------ |
| Tools come from the image | PASS | `mise` on `PATH`; `task`, `kubectl`, `chezmoi` under `/opt/mise/installs/` |
| No Homebrew | PASS | `/home/linuxbrew` does not exist |
| Cache | PASS | `/cache` exists, owned by `vscode`; `XDG_CACHE_HOME` is `/cache` |
| `task init` without `brew` | PASS | "All required tools are present."; `task --list` works |
| Git hooks installed (`task precommit:init` in `updateContentCommand`) | PASS | `commit-msg` and `pre-commit` in `.git/hooks` |
| Rebuild with bad values in `devcontainer.env` | FAIL, cause found | `bws returned no secrets`; `task terraform:upgrade:cloudflare` failed with `unauthorized`; `talos:init` skipped; `task cilium:install:cli` up to date; `postStartCommand` ran |
| Rebuild after the values were corrected | PASS | Checked from the results in the container, pasted by the owner; the log of this rebuild was not read by the agent |
| Secrets from BWS through `.envrc` | PASS | direnv exports the `TALHELPER_*` names; `TALHELPER_OSCERT` is set |
| `task talos:init` | PASS | `provision/talos/clusterconfig/talosconfig` exists |
| `task terraform:upgrade:cloudflare` | PASS | `provision/terraform/cloudflare/.terraform/` holds `environment`, `providers` and `terraform.tfstate` |
| `onCreateCommand` (`chezmoi init --apply`) | PASS | `chezmoi managed` lists 13 entries |
| `postStartCommand` (memory symlinks) | PASS | 42 entries in the Claude memory directory |
| `GITHUB_TOKEN` | PASS | set in the shell |

Cause of the failure: not the image. The lines in `devcontainer.env` had a comment after the value, as the old sample laid them out (`NAME=    # comment`). Docker's `--env-file` keeps that text as part of the value, so the variables looked set and the services rejected them. The sample now puts each comment on its own line and states the format.

Three facts for the next person. A fresh container volume starts from the comment-only sample, so the order is clone, fill in the file, rebuild. The scripts have no `set -e`, and `updateContentCommand` printed `Done!` after the Terraform failure, so `Done!` proves nothing. `task` prints `no context is set` when no talosconfig exists (from `talosctl config info`, reproduced with an empty `TALOSCONFIG` path, exit 1); it does not stop the task.

## T10: the other repositories (2026-11-05)

Each repository was opened by the owner with "Clone GitHub Pull Request in Container Volume" and rebuilt; the owner pasted the output. All pin `ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:71335a56…`. Design rules in D49.

| Repository | PR | Devcontainer | Result |
| ---------- | -- | ------------ | ------ |
| `github-workflows` | #33 | features `docker-in-docker`, `act`; `containerUser: root` | First build FAIL: no Docker daemon (the entrypoint needs `sudo` when not root; the image has none). After `containerUser: root`: PASS, Docker server 29.9.3-1 reachable as `vscode`, `act` 0.2.97, Go 1.27.3. No `act` run tried |
| `containers` | #785 | features `docker-in-docker`; `containerUser: root`; local Homebrew Dockerfile removed | PASS: Docker 29.9.3-1, buildx v0.38.2, task 3.54.0, cue v0.17.1, Go 1.27.3; `task test` for `s3-bucket-cleaner` built the image. Its `dgoss` step needs `CLI=true` for a `cli` app (the command given first left it out); the rerun result was not reported before the merge |
| `homelab-portal` | #120 | features `common-utils` (`sudoers: false`), `node` 24, `java` 17 Temurin, NordcomInc `android-sdk:2` (platform 35, build-tools 35.0.0); `overrideFeatureInstallOrder` common-utils, java, android-sdk; `MISE_DISABLE_TOOLS=node`; own image build and publish workflow removed; env sample comments moved off the value lines | PASS: Node v24.22.2, Yarn 1.22.22, OpenJDK 17.0.21, platform 35 and build-tools 35.0.0 under `/usr/local/lib/android`; `yarn lint` (0 errors, 2 old warnings), `yarn typecheck`, `yarn format:check`; `sudo -n true` refused for `vscode`. No local Android build tried |
| `argocd-secret-replacer` | #155 | features `dotnet` 10.0, `sops`; `age` from the image | PASS: .NET SDK 10.0.403, sops 3.13.3, age v1.3.2; `dotnet build`; unit tests 17 of 17. `sops` E2E tests not run (need an age key) |
| `willow-inference-server-dockerized`, `home-assistant` | none | unchanged | Not moved (owner's list, both inactive) |

Feature choice for the Android SDK: the CASL0 feature installs without `sudo` but is small and unchanged since January 2024; the owner preferred the maintained NordcomInc feature, which calls `sudo` and so needs `common-utils` first and Java ordered before it (its `sdkmanager` needs Java at install time).

## T22: pod hardening test on the pinned image (2026-11-04)

Question (Q24, D43): does the image run with `readOnlyRootFilesystem: true` in a namespace enforcing Pod Security `restricted`, and does `fsGroup` with `OnRootMismatch` behave?

**Setup.** Scratch namespace `t22-scratch` labelled `pod-security.kubernetes.io/enforce`, `warn` and `audit` = `restricted`; a 5 Gi `ceph-block` PVC at `/home/vscode`; `emptyDir` at `/tmp` (5 Gi limit), `/cache` (20 Gi limit) and `/workspaces` (5 Gi limit, a stand-in for the source PVC). Pod settings: user and group 1000, `runAsNonRoot`, `fsGroup` 1000, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`, all capabilities dropped, `readOnlyRootFilesystem: true`, no service account token, memory limit 3 Gi, `ephemeral-storage` request 1 Gi and limit 30 Gi. Image `ghcr.io/mmalyska/dev-workstation:1.0.0` at the pinned digest, amd64, on `mc3`. The tests ran from the pod command and were read from the pod log (no `kubectl exec`).

| Check | Result | Detail |
| ----- | ------ | ------ |
| Pod admitted at `restricted` | PASS | no warning from the `warn` mode, pod ran to completion |
| `cp -rn /etc/skel/. "$HOME"/` on an empty home | PASS | home went from 1 entry to 4; exit 0 |
| Second `cp -rn` changes nothing | PASS | hash of all files identical before and after |
| `git init` and an empty commit | PASS | |
| `mise use -g shfmt@3.8.0`, then `mise exec -- shfmt --version` | PASS | installs into the home volume |
| `mise trust`, `mise install` (repository `mise.toml` with `jq 1.7.1`), `mise exec -- jq --version` | PASS | |
| `npm install --package-lock-only` and `npm ci` | PASS | cache under `/cache/npm` |
| `go mod init`, `go get` (a module from the network), `go build`, run the binary | PASS | module cache under `/cache/go/mod` |
| `terraform init` with the `hashicorp/null` provider | PASS | plugin cache `/cache` |
| Coder agent starts | NOT RUN | needs a Coder server and agent token; the scratch pod had neither. The agent normally downloads its binary into `/tmp`, which is writable, but that is not tested |
| `OnRootMismatch` avoids the ownership walk | INCONCLUSIVE | see below |

**Paths that needed to be writable:** `/home/vscode`, `/tmp`, `/cache`, `/workspaces`. Everything else was read-only and nothing failed: `/`, `/etc`, `/usr`, `/usr/local`, `/opt`, `/opt/mise`, `/var`, `/var/tmp`, `/var/log`, `/run`, `/home`, `/root`. After the full run `/cache` held 79 MB and `/tmp` 6 MB.

**`fsGroupChangePolicy`.** With a populated home (10,128 files, a fresh volume) the same pod started on the same node in about 6 s with `OnRootMismatch` and about 5 s with `Always` (kubelet start to container start). Both are noise at this size: the root of the volume was already group 1000 and setgid, and ten thousand empty files are walked in well under a second, so this test cannot show a difference. It shows only that `OnRootMismatch` does no harm. Leave the setting in (D43) for the large source volume; do not read this result as a measurement of the benefit.

**Observations.**

- A fresh volume's root is `root:vscode`, mode 2775 (setgid). With `fsGroup` 1000 the `vscode` user can write there; files it creates are owned by `vscode:vscode`. One entry at the top level of the new volume was not owned by `vscode` (the setup counted it but did not name it; most likely the ext4 `lost+found`, not verified).
- The first `cp -n` prints a GNU coreutils warning ("behavior of -n is non-portable, use --update=none"). It is harmless; the seeding command in the template (D45) could use `--update=none` once the image's coreutils is known to support it.
- Egress was open, as in the design, so every download above worked.

**Not covered.** The source PVC (the test used an `emptyDir` for `/workspaces`), the Coder agent, a restore, arm64, and any behaviour under a node with disk pressure.

**Answer to Q24 (for the owner to confirm, not decided here).** On this evidence `restricted` is accepted and `readOnlyRootFilesystem: true` works with the four writable mounts above. A reasonable end state is: namespace `dev-workspace` at `restricted` for enforce, warn and audit; `readOnlyRootFilesystem: true` kept; the template mounts exactly `/home/vscode` (PVC), `/workspaces` (PVC), `/cache` and `/tmp` (`emptyDir`s). The one open item is the Coder agent, which can only be tested with a real workspace in T7.

Scratch objects: namespace `t22-scratch`, PVC `t22-home` and three pods. The pods were deleted after their logs were read; the namespace and PVC were deleted with the owner's consent on 2026-11-04 (the PV was released with them, none left).

## T7: first workspace, checks so far (2026-11-04)

Template `dev-workspace` (version pushed 2026-11-04 12:59, home-ops `0bd51a75`), workspace created by the owner with the defaults (`dev-workspace`, `dev-workspace-bws`, `amd64`). Image digest-pinned, pod on `mc1`. The owner ran the checks inside the workspace and pasted the output; the cluster-side facts were read with `kubectl` (no `describe`, because the agent token is a plain env value in the pod spec).

| Check | Result | Detail |
| ----- | ------ | ------ |
| Bootstrap at first start | PASS | dotfiles applied; Claude and Codex plugins `fails=0`; `mmalyska/home-ops`, `containers`, `claude-plugins` and `dotfiles` cloned; `bootstrap: done` |
| Pod hardening as in the template | PASS | uid 1000, `fsGroup` 1000 `OnRootMismatch`, read-only root, no privilege escalation, all capabilities dropped; memory 3 Gi, CPU 500m request and 2 limit, ephemeral-storage 30 Gi; mounts `/home/vscode`, `/workspaces`, `/cache`, `/tmp`, `/run/signing`, `/var/run/secrets/talos.dev`; 0 restarts |
| Talos Secret renewed | PASS | the Talos ServiceAccount re-synced while the pod ran (event seen about 4 minutes after start) |
| Signing key in the ssh-agent, `user.signingkey` set by the dotfiles | PASS | `ssh-add -l` lists one ED25519 key from `/run/signing`; `git log --show-signature` on a scratch commit: `Good "git" signature` (with a temporary allowed-signers file) |
| `kubectl` through the pod ServiceAccount, no kubeconfig | PASS | four nodes listed; `~/.kube` contains only `cache` (no `config`); `get secrets -A` answers `no`; `get pods --subresource=exec` answers `no` |
| `talosctl` with `os:reader` | PASS | `version` and `get members` work against `192.168.48.2`; `get machineconfig` is denied (`PermissionDenied`, so `machineconfig` is a sensitive type); `talosctl kubeconfig` is denied |
| Nothing sensitive on the volume (names only) | PASS | no `~/.config/gh`, no `~/.terraform.d`, no `.git-credentials`; `~/.kube/cache` is kubectl's discovery cache |
| Manual per-repository setup in `home-ops` (D48) | PASS | `direnv allow` and `task precommit:init`: `pre-commit` and `commit-msg` hooks installed, the gitleaks environment built |
| Argo CD account with the workspace token | PASS | `can-i get applications` yes, `can-i sync applications` no; the CLI prints a gRPC warning until `--grpc-web` is used |
| Persistence across a restart (home and source files and their owner, `/cache` and `/tmp` reset, signing key reloaded from BWS, dotfiles source and four repositories, git hooks, direnv allow) | PASS | markers survived owned by `vscode:vscode`; `marker-cache` and `/tmp/sc` were gone; `/cache` held only `mise` and `Microsoft`, created since the restart; new pod on the same two PVCs, 0 restarts, started in about 17 s with the image cached |
| Claude login and a user-installed `mise use -g` tool (`claude-squad`) surviving a restart (the template-update restart, new pod) | PASS | `~/.claude/.credentials.json` present and `claude` still logged in; the tool is in `~/.local/share/mise/installs` |
| Template environment after `coder templates push` and an update (`ARGOCD_OPTS=--grpc-web`, `KUBECACHEDIR=/cache/kube`) | PASS | both set; `argocd account can-i get applications` prints `yes` without the gRPC warning; kubectl writes `discovery` and `http` to `/cache/kube` (the old `~/.kube/cache` was removed by hand) |
| `.envrc` loader on the dev project (`.github/tests/envrc.sh`, 14 cases) | PASS | after `git pull` and `direnv allow` in the workspace: no `xargs` error; `ARGOCD_AUTH_TOKEN`, `ARGOCD_SERVER`, `GITHUB_TOKEN`, `TERRAFORM_TOKEN` exported; `SSH_SIGNING_KEY` not in the environment; `SOPS_AGE_KEY` no longer exported (removed from the project by the owner) |
| Claude Code and Codex start | PASS | reported working by the owner before the restart |

### Findings

1. **`.envrc` breaks on the dev project.** `xargs: unmatched double quote` when direnv loads `home-ops/.envrc`: a multi-line secret (the SSH signing key) cannot be parsed by `export $(... | xargs)`. The variables before it were exported, `SSH_SIGNING_KEY` was not, and anything after the broken value would be dropped silently. If the key were single-line it would be exported into every direnv shell. The parsing line predates the workspace; the dev project is the first with a multi-line secret. Fix: read the secrets as JSON, skip `SSH_SIGNING_KEY` explicitly and any multi-line value, export key by key.
2. **`SOPS_AGE_KEY` is in the dev BWS project and exported by `.envrc`.** D30 says the workspace does not get it. Owner action: remove it from that project.
3. **Argo CD CLI needs `--grpc-web`** behind the Envoy gateway. Set `ARGOCD_OPTS=--grpc-web` in the template environment (non-secret).
4. **kubectl's cache lands on the home volume** (`~/.kube/cache`, backed up). Set `KUBECACHEDIR=/cache/kube` in the template environment.
5. One `FailedMount` event (ceph-csi "Aborted", source volume) before the container started: a transient RBD attach race that resolved itself. The first start also spent about 2 minutes pulling the image.
6. peon-ping installs in the workspace although no audio relay is reachable from a pod; decision pending (skipping needs a `.chezmoiignore` change in `mmalyska/dotfiles`).
7. The `ai-workflow` drift warning (marketplace newer than the accepted revision) is unchanged from the scratch-container run.
8. `lost+found` is in `/workspaces` (the ext4 root of the source volume): the one top-level entry not owned by `vscode` seen in T22 was most likely this.
9. The `FailedMount` event (ceph-csi `Aborted ... an operation with the given Pod UUID already exists`) recurred on the second start, on the home volume this time: ceph-csi serialises the two concurrent mounts and kubelet retries; benign.
10. The `.envrc` `xargs` error is unchanged after the restart.

Findings 1, 3 and 4 above are fixed in the PR that records these checks (`.envrc` reads the secrets as JSON and skips `SSH_SIGNING_KEY`; `ARGOCD_OPTS` and `KUBECACHEDIR` are set by the template; `bash .github/tests/envrc.sh`). Finding 2 is an owner action (remove `SOPS_AGE_KEY` from the dev BWS project). The template needs one more `coder templates push` to take effect.

Operational note from the second round: a workspace checkout does not update itself. After a merge in `home-ops`, `git pull --ff-only` in `/workspaces/home-ops` brings the change, and direnv blocks a changed `.envrc` until the owner runs `direnv allow` (the intended direnv behaviour). The first `argocd` call of a session that runs before direnv has loaded `.envrc` fails with "server address unspecified" for the same reason.

## T7 close-out (2026-11-05)

Authorization checks of T19, run by the agent from the devcontainer with `kubectl auth can-i --as=...` (READ-class, no secret read, no forbidden read attempted). Each verb and resource was asked separately, subresources with `--subresource`.

| Check | Result | Detail |
| ----- | ------ | ------ |
| Workspace ServiceAccount, negative list and positive controls | PASS | 82 checks, 0 unexpected. `no`: `get`, `list`, `watch` on `secrets`; `get` on `nodes/proxy`, `pods/proxy`, `services/proxy`; `get` and `create` on `pods/exec`, `pods/attach`, `pods/portforward`; `create` on `serviceaccounts/token`; `update` and `patch` on `pods/ephemeralcontainers`; `get` on `certificatesigningrequests`; `impersonate`, `escalate`, `bind`; `create`, `update`, `patch`, `delete` on `pods`, `deployments`, `configmaps`, `services`, `namespaces`, `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings`, `serviceaccounts`, `customresourcedefinitions`, `externalsecrets`, `serviceaccounts.talos.dev`. `yes`: `get`, `list`, `watch` on `pods`, `nodes`, `namespaces`; `get`, `list` on `applications.argoproj.io` |
| Provisioner ServiceAccount `coder/coder` in `dev-workspace` | PASS | 24 of 24 probes `no` (`create`, `get`, `delete` on `externalsecrets`, `replicationsources`, `replicationdestinations`, `roles`, `rolebindings`, `serviceaccounts.talos.dev`, `persistentvolumeclaims`, `secrets`); the Role `dev-workspace-provisioner` grants `deployments` only, bound to that ServiceAccount; `create` on `pods`, `services`, `configmaps` and `serviceaccounts` answers `no` |
| Both PVCs `Bound` and mounted by name | PASS | `dev-workspace-home` 5 Gi and `dev-workspace-src` 30 Gi, both volumes of the pod; the two `volsync-src-*-cache` PVCs are the backup caches |
| VS Code connects through the Coder agent (`coder config-ssh`, no sshd) | PASS (owner) | confirmed by the owner 2026-11-05 |
| Argo CD stage 2 | PASS | see "T18 stage 2" below |

Findings closed: 2 (`SOPS_AGE_KEY` removed from the dev BWS project, confirmed by the owner) and 6 (peon-ping stays installed, accepted by the owner, no `dotfiles` change).

## T18 stage 2: sync allowlist with the disposable `sync-probe` app (2026-11-04)

PR #6092 merged; the `sync-probe` Application (two ConfigMaps, `prune: false`) appeared after the ApplicationSet refresh, and the `argocd` app was synced to `419319a9`, which put `p, dev-workspace, applications, sync, default/sync-probe, allow` in the live `argocd-rbac-cm` (read with `kubectl`). The owner ran the checks in the workspace with the account token and pasted the output.

| Check | Result | Detail |
| ----- | ------ | ------ |
| `can-i sync applications default/sync-probe` | PASS | `yes` |
| `can-i sync` on another application, `override`, `delete`, `create` | PASS | all `no` |
| `argocd app sync sync-probe` | PASS | both ConfigMaps Synced at `419319a9`, phase Succeeded |
| `argocd app sync coder` (a real application) | PASS (refused) | `PermissionDenied: applications, sync, ai/coder, sub: dev-workspace` |
| `argocd app sync sync-probe --revision <non-main branch>` | PASS (refused) | `PermissionDenied: applications, override, default/sync-probe, sub: dev-workspace`; `requireOverridePrivilegeForRevisionSync` works |
| Prune with `--prune` after removing `probe-prune-me` from git (#6094 merged, `sync-probe` hard-refreshed by the agent with the owner's consent) | PASS | auto-sync left the object: `OutOfSync`, `ignored (requires pruning)`; `argocd app sync sync-probe` without `--prune` succeeded, the object stayed (the CLI exits non-zero with `1 resources require pruning`); `argocd app sync sync-probe --prune` pruned `probe-prune-me`, app `Synced`, `kubectl get cm` lists only `probe-keep` and `kube-root-ca.crt` |
| `argocd app get sync-probe` before the grant | FAIL (expected, not granted) | `PermissionDenied: projects, get, default`: the CLI reads the project too. Sync, prune and the operation result still worked |
| `projects, get` grant (#6096 merged, `argocd` app synced to `462a44e0`; live `argocd-rbac-cm` read with `kubectl`) | PASS | `can-i get projects '*'` yes, `can-i create projects '*'` no, `argocd app get sync-probe` prints the application (Synced, Healthy; `probe-prune-me` Pruned, `probe-keep` Synced) |

The first attempt at the revision check failed only because the placeholder `<non-main branch>` was typed literally (shell syntax error); it was rerun with a real branch.

## T8: safety controls and restore test (2026-11-04)

Run by the agent from the local devcontainer with the owner's consent for each mutation (scratch objects in the namespace `dev-workspace`, names starting `t8-`), and, for the in-workspace checks, one read-only `coder ssh` call and one call that created and removed a temporary worktree. Output was file names, owners and modes only; no file content was read.

### Restore test

| Check | Result | Evidence |
| ----- | ------ | -------- |
| Home restore into a scratch PVC (`ReplicationDestination`, `copyMethod: Direct`, latest snapshot from 18:17Z) | PASS | mover result `Successful`, 57 s |
| Accepted login files present (D20): `.claude/.credentials.json`, `.claude.json`, `.codex/auth.json` | PASS | all three `PRESENT` |
| Must-not-persist names absent: `.git-credentials`, `gh` hosts file, Terraform CLI credentials, `.kube`, `.ssh` private keys, `.bws` | PASS | all `absent` |
| `~/.config/bws` absent | **FAIL** | present, with a `state/` directory holding one 1.9 KB state file (mode 660); not read. Fixed in #6108, see below |
| Other credential-like names on the home volume (names only) | note | `~/.vscode-server/cli/agent-host-token` (36 bytes, mode 660, the VS Code server's own token), a Go telemetry `upload.token`, TLS certificate bundles under `mise` installs, tokenizer data files. Only the VS Code server token is a credential; it is not on the plan's list and is documented |
| Home ownership and content | PASS | 10069 files; the only entries not owned by uid 1000 are the volume root and `lost+found` (ext4 root, `fsGroup`) |
| Src restore, first attempt (snapshot from 09:22Z) | PASS (mechanism), no content | `Successful`, volume holds only `lost+found`: the PVC was created at 09:22:04Z and the only scheduled backup ran 18 s later, before the workspace pod started (16:57Z) |
| Src restore after a one-off backup (`ReplicationSource` `t8-src-backup`, `copyMethod: Snapshot`, 15 s) | PASS | `Successful`; four repositories with a `.git` directory (`claude-plugins`, `containers`, `dotfiles`, `home-ops`), `AGENTS.md`, `marker-src`; 2152 files; none owned by anyone but uid 1000 (root volume root and `lost+found` excluded); no `.git-credentials`, `.env`, `*.pem`, `id_*` or `*.tfstate` names |
| Scratch objects deleted | PASS | pods, `ReplicationDestination`s, `ReplicationSource`, scratch PVCs and the one-off cache PVC removed; `dev-workspace-home`, `dev-workspace-src`, their cache PVCs, both `ReplicationSource`s and the workspace pod were unchanged |

Side effect to know about: the one-off backup wrote an extra snapshot lineage into the live src restic repository. The cleanup does not remove it (only `restic forget` would, and it was not run). The scheduled src backup next runs at 03:47Z.

### In-workspace checks

| Check | Result | Evidence |
| ----- | ------ | -------- |
| `.claude/settings.json` and `.agents/policy` in the workspace checkout equal `origin/main` | PASS | empty `git diff --stat` after `git fetch` (the checkout was 4 commits behind) |
| Argo CD sync and refresh rules present and in `ask` | PASS | `argocd app sync*`, `task argocd:sync*`, `argocd app get/diff *--refresh*` and `*--hard-refresh*` |
| `worktree-preflight` in the primary checkout | PASS | exit 3, `kind=primary` |
| `worktree-preflight` in a linked worktree | PASS | exit 0, `kind=worktree`, in a temporary worktree and branch that were removed afterwards |
| Claude session in auto mode: `argocd app sync sync-probe` | blocked, not by the rule | denied by the auto-mode classifier ("Shared Cluster Mutation"); the `ask` rule did not produce a prompt |
| Claude session in auto mode: `kubectl delete pod t8-nonexistent -n default` | **FAIL** for the `ask` rule | ran without a prompt although `kubectl delete*` is an `ask` rule; refused by Kubernetes RBAC (`Forbidden`, the `dev-workspace` ServiceAccount cannot delete pods) |
| Claude session in auto mode: Write in the primary checkout | PASS | denied by the `PreToolUse:Write` worktree guard; no file created |
| Claude session in auto mode: `git status -sb` | PASS | ran |
| The same `ask` rules in `default` mode | NOT RUN | needs an interactive session in `default` mode; the owner has not run it yet |

Finding, accepted by the owner on 2026-11-04: in auto mode the repository's `ask` rules are decided by the classifier and are not a human gate. The read-only Kubernetes ServiceAccount (D26, D27) held and is the boundary that matters in the workspace.

### The `bws` state file

`bws` keeps its login state in `~/.config/bws/state` and keys its config file by the access token's identifier. #6108 set `BWS_CONFIG_FILE` to `/cache/bws/config` and ran `bws config state-dir`. That broke `bws` in the live workspace (2026-11-05): the profile it writes has no server settings, so every call failed with `Profile has no server_base or server_identity`, and the loader loaded no secrets. The scratch test of #6108 made no real `bws` call and missed it. The fix replaces both with a symlink: the loader makes `~/.config/bws/state` point to `/cache/bws/state` (removing an old real directory first), and no config file is used. Checked locally: the symlink step in a scratch HOME, run twice, with an old real directory present (PASS). Checked live 2026-11-05 (#6114 merged, template pushed from a current `main`, workspace updated; the first push, version `fierce_james15`, lacked the change, and the second, `magnificent_kling98`, carried #6108 and failed as above): in the new pod `BWS_CONFIG_FILE` is unset, `bws secret list` exits 0 (output discarded), `~/.config/bws/state` is a symlink to `/cache/bws/state`, and the one state file sits under `/cache/bws/state`. The old real directory and its file on the home volume are gone (PASS). Not done: the old file stays in existing snapshots of the home volume until their retention expires, and the token was not rotated (optional).
