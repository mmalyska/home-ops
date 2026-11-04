# agent-workspace Coder template

Workspaces for AI agents on the `dev-workstation` image, in the namespace `agent-workspaces`. The sibling template
`../workspace-template-dev-workspace/` is the owner's personal workspace and is unchanged. The pod, startup and bootstrap
are the same as there (see its README); this file lists the differences.

## Creates (per workspace, named `<owner>-<workspace>`)

Deployment, PVCs `-home` and `-src`, ServiceAccount, Talos ServiceAccount (`os:reader`), ExternalSecret for the BWS token,
and an ExternalSecret plus ReplicationSource per PVC for VolSync backups. Everything is in `main.tf`; deleting the workspace
deletes it, including the PVCs. The app that grants this and bounds it: `cluster/apps/ai/agent-workspaces`.

## Parameters

| Parameter               | Default   | Meaning                                                                    |
| ----------------------- | --------- | -------------------------------------------------------------------------- |
| `bws_access_token_ref`  | none      | Bitwarden ID of the secret with the BWS machine token; must be allowlisted |
| `bws_project_id_ref`    | none      | Bitwarden ID of the secret with the BWS project ID; must be allowlisted    |
| `home_size`, `src_size` | 5Gi, 30Gi | PVC sizes                                                                  |
| `arch`                  | `amd64`   | Node architecture and agent platform                                       |

Allowlist: `allowedBwsRefs` in `cluster/apps/ai/agent-workspaces/values.yaml`. The four restic references in `main.tf` must
equal `resticRefs` there.

## Deploying

```sh
# Consent-gated: RUNTIME_MUTATION.
coder templates push agent-workspace --directory cluster/apps/ai/coder/workspace-template-agent-workspace --yes
```
