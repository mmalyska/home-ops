# Remote development workspace

An always-on development environment on the cluster, run by Coder. It is for working on `home-ops` and the owner's other
repositories from anywhere on the LAN or VPN. It does not replace the local devcontainer, which stays as the break-glass
environment. Plan: `.archive/.plans/remote-dev-workspace/`.

| Part                           | Where                                                                                |
| ------------------------------ | ------------------------------------------------------------------------------------ |
| Image `dev-workstation`        | Built in `mmalyska/containers`, pinned by digest in the template `main.tf`           |
| Coder template `dev-workspace` | `cluster/apps/ai/coder/workspace-template-dev-workspace/`                            |
| Namespace, PVCs, backups, RBAC | `cluster/apps/system/dev-workspace`, see [Dev workspace namespace](dev-workspace.md) |

## Connect

Access is through the Coder agent only. There is no sshd and no LoadBalancer IP, and Coder stays on the internal gateway
(LAN and VPN).

```sh
coder login https://coder.<private-domain>
coder config-ssh        # adds a Host entry per workspace to ~/.ssh/config
```

Then use VS Code Remote-SSH or the Coder extension, or `coder ssh <owner>/<workspace>`.

## What you get

- User `vscode` (UID 1000), no sudo. Tools come from the image (read-only `/opt/mise`). Add more with `mise use -g <tool>` or a
  repository `mise.toml` and `mise install`; they go to the home volume.
- Repositories under `/workspaces/<repo>`, the same paths as the local devcontainer. The dotfiles clone the repository list on
  the first start.
- Docker is not available. Images are built in GitHub Actions.
- Commits are SSH-signed with a dedicated workspace key.
- Resources: 3 Gi memory, 2 CPU limit (starting values, to be tuned after about two weeks of use).

| Path           | Storage                      | Backup    | After a restart            |
| -------------- | ---------------------------- | --------- | -------------------------- |
| `/home/vscode` | PVC `<workspace>-home`, 15 Gi | Every 6 h | Kept (logins, mise tools)  |
| `/workspaces`  | PVC `<workspace>-src`, 30 Gi | Daily     | Kept                       |
| `/cache`       | `emptyDir`, 20 Gi limit      | None      | Empty (rebuildable caches) |
| `/tmp`         | `emptyDir`, 5 Gi limit       | None      | Empty                      |

Commit and push work you care about: the source volume is backed up once a day. Claude and Codex logins live on the home volume
and are in its backup (accepted); every other credential is delivered by environment or memory and never written to a volume.
The `bws` CLI's login state is kept on `/cache` (`~/.config/bws/state` is a symlink to it), so it is not backed up.
The VS Code server's own token (`~/.vscode-server/cli/agent-host-token`) does sit on the home volume and is backed up.

## First use of a repository

The workspace does not run a repository's `.devcontainer` scripts. Per repository, once after the clone:

```sh
cd /workspaces/<repo>
direnv allow             # loads .envrc, which reads the workspace's BWS project
task precommit:init      # installs the secret-scan and attribution hooks; do not skip
```

Then log in to `claude` and `codex` once (home volume). A checkout does not update itself: `git pull --ff-only`, and
`direnv allow` again after `.envrc` changes.

## Secrets

Names only; values live in the dev BWS project and nothing here names the project.

| Name                                 | Delivered by                                                                     |
| ------------------------------------ | -------------------------------------------------------------------------------- |
| `BWS_ACCESS_TOKEN`, `BWS_PROJECT_ID` | Kubernetes Secret `dev-workspace-bws` (ExternalSecret), as environment variables |
| `GITHUB_TOKEN`, `TERRAFORM_TOKEN`    | Loaded by `.envrc` from the BWS project through direnv                           |
| `ARGOCD_AUTH_TOKEN`, `ARGOCD_SERVER` | Same; see the Argo CD account in [Dev workspace namespace](dev-workspace.md)     |
| `SSH_SIGNING_KEY`                    | Read at start into a memory volume and an in-pod `ssh-agent`, then deleted       |

If commits fail with `Couldn't get agent socket?` or `Couldn't find key in agent?`, check the agent with
`ssh-add -l`: exit code 2 means nothing answers on `/run/signing/agent.sock`, 1 means the agent runs without the key.
`/run/signing` is a memory `emptyDir`, so it survives a container restart (an OOM kill on 2026-11-25, for example) while the
agent does not. The startup script replaces a socket that does not answer and reloads the key; a template from before this
check kept the dead socket. To recover without a restart, run in a terminal (it reads the key from BWS, so it is the
owner's action; the key goes through the memory volume and is deleted at once):

```sh
( umask 077; export SSH_AUTH_SOCK=/run/signing/agent.sock; key=/run/signing/key
  ssh-add -l >/dev/null 2>&1; [ $? -eq 2 ] && { rm -f "$SSH_AUTH_SOCK"; ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null; }
  bws secret list "$BWS_PROJECT_ID" -o json | jq -r '.[] | select(.key == "SSH_SIGNING_KEY") | .value' > "$key" \
    && ssh-add "$key"; rm -f "$key"; ssh-add -l )
```

## Cluster access

- **Kubernetes**: read-only through the pod ServiceAccount. No Secrets, no exec, no proxy. `kubectl` uses the in-cluster configuration and no kubeconfig exists.
- **Talos**: `os:reader` only. The config has no nodes list, so pass `--nodes`. Mutating Talos work (`apply-config`, `upgrade`)
  stays on the local devcontainer. A wider role in this pod would also be reachable through the Coder provisioner, which can
  create a Deployment here that mounts the credential's Secret.
- **Argo CD**: read everything; hard refresh; sync and stop a sync (`terminate-op`) on every application except the
  exclusions in `dev-workspace.md` (Argo CD, bootstrap, access control, storage operators, the workspaces). Prune, replace
  and force are the owner's action.
- The consent rules of `AGENTS.md` and `.claude/settings.json` apply here as they do locally. A token that can sync does not
  replace consent for each action.

## Break-glass

If the cluster is unhealthy (Ceph, CoreDNS, Argo CD or the Coder database down), the workspace may be down too. Use the local
devcontainer, which has the full toolset and the mutating Talos access.

## Operating it

Template and workspace changes follow the `coder-workspace-template-deploy` skill. Pushing a template starts nothing;
creating, restarting or updating a workspace and every Argo CD sync or `terminate-op` need the owner's consent. Deleting a
workspace or a template version does not delete the volumes.
