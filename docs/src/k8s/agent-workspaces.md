# Agent workspaces namespace

Namespace `agent-workspaces` holds development workspaces for AI agents (hermes and similar) and for anything else
created from the Coder template `agent-workspace`. The `dev-workspace` template and namespace remain the owner's personal
workspace and are not touched by this setup (see [Dev workspace namespace](dev-workspace.md)).

Two parts:

- **App** `cluster/apps/ai/agent-workspaces`: the namespace, the permissions of the Coder provisioner in it, the
  read-only role of the workspace pods, the ingress deny-all and the guardrails.
- **Template** `cluster/apps/ai/coder/workspace-template-agent-workspace`: creates everything one workspace needs.

## What the template creates per workspace

Names use `<owner>-<workspace name>` (`mmalyska-hermes`), so any number of workspaces can exist side by side.

| Object                                                      | Purpose                                                                      |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `Deployment` `ws-<id>`                                      | The pod (`dev-workstation` image, same hardening as the personal workspace)  |
| PVC `<id>-home`, `<id>-src`                                 | Home (5 Gi, backed up every 6 h) and `/workspaces` (30 Gi, backed up daily)  |
| `ServiceAccount` `<id>`                                     | Pod identity; read-only through the namespace-wide `agent-workspaces-reader` |
| `serviceaccounts.talos.dev` `<id>-talos`                    | `os:reader` Talos credential; Talos creates the Secret with the same name    |
| `ExternalSecret` `<id>-bws`                                 | `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` from the workspace's own BWS project |
| `ExternalSecret` and `ReplicationSource` `<id>-home`/`-src` | VolSync backups, one restic repository per volume                            |

## Create a workspace

1. In Bitwarden create a machine token and a project for the workspace, and two secrets that hold the token and the
   project ID (the same pattern as `dev-workspace`).
2. PR: add the two secret IDs to `allowedBwsRefs` in `cluster/apps/ai/agent-workspaces/values.yaml`. Without it the API
   server refuses the ExternalSecret. This is the only GitOps step per workspace.
3. Create the workspace from the `agent-workspace` template and pass the two IDs as `bws_access_token_ref` and
   `bws_project_id_ref`.

## Guardrails

The Role gives the provisioner create/update/delete on Deployments, PVCs, ServiceAccounts, Talos ServiceAccounts,
ExternalSecrets and ReplicationSources in this namespace, and nothing else (no Secrets, no RBAC objects). Two of those
reach beyond the namespace, so `templates/guardrails.yaml` adds ValidatingAdmissionPolicies:

| Policy                                      | Refuses                                                                                                                                        |
| ------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `agent-workspaces-talos-reader-only`        | a Talos ServiceAccount with any role but `os:reader` (the namespace may request `os:admin`)                                                    |
| `agent-workspaces-externalsecret-allowlist` | an ExternalSecret that uses another store than `bitwarden`, uses `dataFrom`, or reads a Bitwarden ID outside `resticRefs` and `allowedBwsRefs` |

Without them a workspace creator could mint an `os:admin` Talos credential or read any secret of the shared Bitwarden
store. Do not remove them while the namespace is listed in `allowedKubernetesNamespaces`
(`provision/talos/patches/controlplane/40-talos-api-access.yaml`).

## Deleting a workspace

Deleting a workspace in Coder deletes its PVCs and ReplicationSources (stopping it does not). The restic backups in the
bucket stay, and can be restored into a new PVC.

## Checks after the first sync (read-only)

`kubectl auth can-i` as the provisioner (`--as=system:serviceaccount:coder:coder -n agent-workspaces`): `yes` for
`create` on `persistentvolumeclaims`, `serviceaccounts.talos.dev`, `externalsecrets`; `no` for `secrets`, `roles`,
`rolebindings`. The two policies are verified with a server-side dry run of a Talos ServiceAccount with `os:admin` and of
an ExternalSecret with an unlisted ID; both must be refused (consent-gated, they call the API server).
