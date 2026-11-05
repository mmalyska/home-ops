# agent-workspace Coder template

Workspaces for AI agents on the `dev-workstation` image, in the namespace `agent-workspaces`. The sibling template
`../workspace-template-dev-workspace/` is the owner's personal workspace and is unchanged. The pod, startup and bootstrap
are the same as there (see its README); this file lists the differences.

## Creates (per workspace, named `<owner>-<workspace>`)

Deployment, PVCs `-home` and `-src`, a ClusterIP Service `-ssh`, ServiceAccount, ExternalSecret `-env` (GitHub token and extra
secrets), and an ExternalSecret plus ReplicationSource per PVC for VolSync backups. Optional: ExternalSecret `-signing` and the
Talos ServiceAccount. Everything is in `main.tf`; deleting the workspace deletes it, including the PVCs. The app that grants this
and bounds it: `cluster/apps/ai/agent-workspaces`. Full description: `docs/src/k8s/agent-workspaces.md`.

## Parameters

| Parameter               | Default   | Meaning                                                                                     |
| ----------------------- | --------- | ------------------------------------------------------------------------------------------- |
| `github_token_ref`      | none      | Bitwarden secret ID of `GITHUB_TOKEN`; must be allowlisted                                  |
| `extra_secrets`         | `[]`      | `NAME=<Bitwarden secret ID>` entries, each an environment variable; IDs must be allowlisted |
| `signing_key_ref`       | empty     | Optional secret ID of the commit signing key                                                |
| `authorized_key`        | none      | Public key allowed to SSH in on 2222 (user `vscode`)                                        |
| `kubernetes_access`     | `false`   | Mount the pod ServiceAccount token (read-only cluster access)                               |
| `talos_access`          | `false`   | Create and mount an `os:reader` Talos credential                                            |
| `home_size`, `src_size` | 5Gi, 30Gi | PVC sizes                                                                                   |
| `arch`                  | `amd64`   | Node architecture and agent platform                                                        |

Allowlist: `allowedBwsRefs` in `cluster/apps/ai/agent-workspaces/values.yaml`. The four restic references in `main.tf` must
equal `resticRefs` there. No BWS machine token or `bws` CLI loader is used here, unlike the personal template.

## SSH

The startup script starts `sshd` (from the image) as `vscode` on port 2222: key login only, no forwarding, host key on the home
volume. Session environment comes from `~/.ssh/environment` (a symlink to a file in `/cache/sshd`, rewritten at every start).
The image must contain `openssh-server` (`mmalyska/containers`, `dev-workstation`, since #783); the digest in `main.tf` is a build
that has it. With an older image the log reads "sshd is not in this image" and only the Coder agent works.

## Deploying

```sh
# Consent-gated: RUNTIME_MUTATION.
coder templates push agent-workspace --directory cluster/apps/ai/coder/workspace-template-agent-workspace --yes
```
