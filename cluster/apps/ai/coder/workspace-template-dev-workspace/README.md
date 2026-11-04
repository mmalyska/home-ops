# dev-workspace Coder template

A long-lived development workspace on the `dev-workstation` image (`ghcr.io/mmalyska/dev-workstation`, pinned by digest in
`main.tf`). Plan: `.plans/remote-dev-workspace/`. The `sandbox` template in `../workspace-template/` is not touched.

Access is through the Coder agent only (no sshd, no Service, no `authorized_keys`): `coder config-ssh`, then VS Code with the
Coder extension.

## What the template creates

One `Deployment` (`ws-<workspace>`) in the namespace `dev-workspace`, and nothing else. The provisioner has a Role there that
allows Deployments only.

## What it references (all owned by GitOps in `cluster/apps/system/dev-workspace`)

| Parameter    | Default             | Objects it selects                                                                        |
| ------------ | ------------------- | ----------------------------------------------------------------------------------------- |
| `workspace`  | `dev-workspace`     | PVCs `<name>-home` and `<name>-src`, ServiceAccount `<name>`, Talos Secret `<name>-talos` |
| `bws_secret` | `dev-workspace-bws` | Secret with `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID`                                       |
| `arch`       | `amd64`             | `kubernetes.io/arch` node selector and the agent platform                                 |

## Pod

- User `vscode` (1000), non-root, no sudo, `allowPrivilegeEscalation: false`, all capabilities dropped, `RuntimeDefault`
  seccomp, `readOnlyRootFilesystem: true`, `fsGroup` 1000 with `OnRootMismatch`. Tested at Pod Security `restricted` (T22).
- Memory 3 Gi (request = limit), CPU 500m request and 2 limit (starting values, T9), `ephemeral-storage` 30 Gi.
- Writable paths: `/home/vscode` (PVC, backed up every 6 h), `/workspaces` (PVC, backed up daily), `/cache` (`emptyDir`,
  20 Gi), `/tmp` (`emptyDir`, 5 Gi), `/run/signing` (memory `emptyDir`, 64 Mi).
- Talos: the `<name>-talos` Secret is mounted as a directory at `/var/run/secrets/talos.dev` (renewed by Talos) and
  `TALOSCONFIG` points at its `config`. Role `os:reader`; the config has no nodes list, so `talosctl` needs `--nodes`.
- Kubernetes: the pod ServiceAccount token; `kubectl` uses the in-cluster configuration and no kubeconfig exists.

## Startup

1. `cp -rn /etc/skel/. "$HOME"/` fills an empty home volume.
2. If `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` are set, the script reads the secret named `SSH_SIGNING_KEY` from that BWS project
   into the memory volume, loads it into an `ssh-agent` on `/run/signing/agent.sock` (`SSH_AUTH_SOCK` is set for every
   session), and deletes the file. The key is never written to a volume and never printed.

## Bootstrap (`bootstrap.sh`)

A `coder_script` runs `bootstrap.sh` at every start. It does not block login, and a failure is logged and skipped. Once per home
volume (no `~/.local/share/chezmoi/.git` yet) it runs `chezmoi init --apply --promptDefaults mmalyska/dotfiles`. The agent
environment sets `REMOTE_WORKSPACE=1`, so the dotfiles switch on the workspace signing key and clone the repository list to
`/workspaces/<name>`. Later starts do not pull; run `chezmoi update` yourself. To redo the first step, delete
`~/.local/share/chezmoi`.

The GitHub token is read from the workspace's BWS project (secret `GITHUB_TOKEN`) into a shell variable and passed only to that
command, so private repositories can be cloned. It is never printed or written to disk. If it is missing, public repositories
still clone.

**This workspace does not run a repository's `.devcontainer` lifecycle scripts** (plan D48). It serves several repositories and
is not meant to be backwards compatible with the devcontainer flow. For now the per-repository setup is manual, once per
repository after the clone:

```sh
cd /workspaces/<repo>
direnv allow             # load the repository's .envrc
task precommit:init      # install the pre-commit hooks (secret scan, attribution check); do not skip this
task terraform:upgrade:cloudflare   # only where the repository needs it (home-ops)
```

Claude memory stays in the repository: a hook in that repository (separate change) stops Claude writing memory outside it, so
no symlinks are needed here. Automating the manual steps is a later task.

## Deploying

Pushing the template makes it available and starts nothing; creating a workspace is a separate step. Both need the
owner's consent. See the `coder-workspace-template-deploy` skill for the push, with this directory in place of
`workspace-template`.

```sh
# Consent-gated: RUNTIME_MUTATION.
coder templates push dev-workspace --directory cluster/apps/ai/coder/workspace-template-dev-workspace --yes
```
