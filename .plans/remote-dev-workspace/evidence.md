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
