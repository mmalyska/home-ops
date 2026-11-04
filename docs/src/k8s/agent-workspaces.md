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

| Object                                                      | Purpose                                                                                   |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `Deployment` `ws-<id>`                                      | The pod (`dev-workstation` image, same hardening as the personal workspace)               |
| PVC `<id>-home`, `<id>-src`                                 | Home (5 Gi, backed up every 6 h) and `/workspaces` (30 Gi, backed up daily)               |
| `Service` `<id>-ssh`                                        | ClusterIP, port 22 to the pod's sshd on 2222; this is how the agent (hermes) logs in      |
| `ServiceAccount` `<id>`                                     | Pod identity. Its token is mounted only when Kubernetes access is on                      |
| `ExternalSecret` `<id>-env`                                 | `GITHUB_TOKEN` and the extra secrets as environment variables, each fetched by its own ID |
| `ExternalSecret` `<id>-signing` (optional)                  | The commit signing key, as a file loaded into an in-pod ssh-agent                         |
| `serviceaccounts.talos.dev` `<id>-talos` (optional)         | `os:reader` Talos credential; Talos creates the Secret with the same name                 |
| `ExternalSecret` and `ReplicationSource` `<id>-home`/`-src` | VolSync backups, one restic repository per volume                                         |

No BWS machine token goes into the pod. A token reads its whole project, and the free tier has a single shared project, so
the pod gets exactly the secrets named in the parameters and cannot list the others.

## Parameters (access is chosen per workspace)

| Parameter                       | Meaning                                                                                                                              |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `github_token_ref`              | Bitwarden secret ID of this agent's `GITHUB_TOKEN`; required, so every agent has GitHub. Use one token per bot account, or share one |
| `extra_secrets`                 | List of `NAME=<Bitwarden secret ID>`; each becomes an environment variable                                                           |
| `signing_key_ref`               | Optional secret ID of an SSH key that signs the agent's commits                                                                      |
| `authorized_key`                | Public key allowed to SSH in (user `vscode`, port 2222)                                                                              |
| `kubernetes_access`             | Off by default. On: the pod token is mounted and `kubectl` reads the cluster (read-only role, no Secrets, no exec)                   |
| `talos_access`                  | Off by default. On: an `os:reader` Talos credential is created and mounted                                                           |
| `home_size`, `src_size`, `arch` | Sizes and platform                                                                                                                   |

## Create a workspace

1. In Bitwarden create the secrets the agent needs (its GitHub token, optionally a signing key and others).
2. PR: add their IDs to `allowedBwsRefs` in `cluster/apps/ai/agent-workspaces/values.yaml`. The API server refuses any
   other ID. This is the only GitOps step per workspace. The file holds placeholders for hermes until the real IDs exist.
3. Create the workspace from the `agent-workspace` template with the parameters above.

## How hermes connects

Hermes runs in the `hermes-agent` namespace and uses SSH, as it does with the `sandbox` workspace today.

- **Network.** The namespace has an ingress deny-all. `allow-ssh-from-agents` opens port 2222 of the workspace pods to the
  pods listed in `sshClients` (values.yaml): the Hermes pod (`app=hermes-agent`) in `hermes-agent`. Nothing else reaches it.
- **Key.** Hermes already holds a private key at `/opt/data/ssh/sandbox-devops.key`. Derive its public half and pass it as
  the workspace's `authorized_key` (`ssh-keygen -y -f <key>`), or generate a new pair and store the private key for Hermes the
  same way as the existing one.
- **Target.** Point the profile's SSH terminal at `vscode@<id>-ssh.agent-workspaces.svc.cluster.local` (port 22) with that key.
  The server host key is kept on the home volume, so `known_hosts` stays valid across restarts.
- **Environment.** `GITHUB_TOKEN`, the extra secrets, `TALOSCONFIG` (when on) and `SSH_AUTH_SOCK` are handed to SSH
  sessions through `~/.ssh/environment`, rebuilt at every start from a file in `/cache`.
- **Image.** sshd comes from the `dev-workstation` image (`openssh-server`, added in `mmalyska/containers`). With an older
  image the workspace still starts and the log says sshd is missing.

## How you get in to fix something

The Coder agent is a separate way in, independent of sshd and of the network policy: `coder ssh <owner>/<workspace>`,
`coder config-ssh` with VS Code, or the web terminal. From your own workspace, `kubectl -n agent-workspaces get pods`
and `logs` work (read-only). Hermes and you share the `vscode` user and the home volume.

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
