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

| Object                                                      | Purpose                                                                                                |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `Deployment` `ws-<id>`                                      | The pod (`dev-workstation` image, same hardening as the personal workspace)                            |
| PVC `<id>-home`, `<id>-src`                                 | Home (5 Gi, backed up every 6 h) and `/workspaces` (30 Gi, backed up daily)                            |
| `Service` `<id>-ssh`                                        | ClusterIP, port 22 to the pod's sshd on 2222; this is how the agent (hermes) logs in                   |
| `ServiceAccount` `<id>`                                     | Pod identity. Its token is mounted only when Kubernetes access is on                                   |
| `ExternalSecret` `<id>-env` (when there is a secret)        | The optional `GITHUB_TOKEN` and the extra secrets as environment variables, each fetched by its own ID |
| `ExternalSecret` `<id>-signing` (optional)                  | The commit signing key, as a file loaded into an in-pod ssh-agent                                      |
| `serviceaccounts.talos.dev` `<id>-talos` (optional)         | `os:reader` Talos credential; Talos creates the Secret with the same name                              |
| `ExternalSecret` and `ReplicationSource` `<id>-home`/`-src` | VolSync backups, one restic repository per volume                                                      |

No BWS machine token goes into the pod. A token reads its whole project, and the free tier has a single shared project, so
the pod gets exactly the secrets named in the parameters and cannot list the others.

## Parameters (access is chosen per workspace)

| Parameter                       | Meaning                                                                                                                                                                                        |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `github_token_ref`              | Optional Bitwarden secret ID of a `GITHUB_TOKEN` that works against `api.github.com`. Empty means no GitHub credential (GitHub App authentication and signed commits are still to be designed) |
| `extra_secrets`                 | List of `NAME=<Bitwarden secret ID>`; each becomes an environment variable                                                                                                                     |
| `signing_key_ref`               | Optional secret ID of an SSH key that signs the agent's commits                                                                                                                                |
| `git_user_name`                 | Optional git `user.name`, written to `~/.gitconfig` at every start                                                                                                                             |
| `git_user_email`                | Optional git `user.email`, written to `~/.gitconfig` at every start                                                                                                                            |
| `authorized_key`                | Public key allowed to SSH in (user `vscode`, port 2222)                                                                                                                                        |
| `kubernetes_access`             | Off by default. On: the pod token is mounted and `kubectl` reads the cluster (read-only role, no Secrets, no exec)                                                                             |
| `talos_access`                  | Off by default. On: an `os:reader` Talos credential is created and mounted                                                                                                                     |
| `home_size`, `src_size`, `arch` | Sizes and platform                                                                                                                                                                             |

## Create a workspace

1. Only if the agent needs secrets: create them in Bitwarden (in the project the cluster `bitwarden` store reads) and add their IDs
   to `allowedBwsRefs` in `cluster/apps/ai/agent-workspaces/values.yaml` by PR. The API server refuses any other ID. A workspace
   without secrets needs no GitOps step.
2. Generate an SSH key pair for the agent (`ssh-keygen -t ed25519`); the public half is the `authorized_key` parameter.
3. Create the workspace from the `agent-workspace` template with the parameters above.

## How hermes connects

Hermes runs in the `hermes-agent` namespace and uses SSH. It has two workspaces, one for each profile:

| Profile                      | Workspace       | Service host                                                    | GitHub account   |
| ---------------------------- | --------------- | --------------------------------------------------------------- | ---------------- |
| `default` (`rudi-the-brain`) | `hermes-main`   | `mmalyska-hermes-main-ssh.agent-workspaces.svc.cluster.local`   | `rudi-the-brain` |
| `worker` (`agent-rosie`)     | `hermes-worker` | `mmalyska-hermes-worker-ssh.agent-workspaces.svc.cluster.local` | `agent-rosie`    |

Both have read-only Kubernetes access and no Talos access. `hermes-worker` has a larger `/workspaces` volume (50 Gi).

- **Network.** The namespace has an ingress deny-all. `allow-ssh-from-agents` opens port 2222 of the workspace pods to the
  pods listed in `sshClients` (values.yaml): the Hermes pod (`app=hermes-agent`) in `hermes-agent`. Nothing else reaches it.
- **Keys.** Each workspace has its own SSH key pair. The private keys are Bitwarden items `HERMES_MAIN_WS_SSH_KEY` and
  `HERMES_WORKER_WS_SSH_KEY`. The Hermes chart copies them at every pod start to `/opt/data/ssh/hermes-main.key` and
  `/opt/data/ssh/hermes-worker.key` (mode 600), and removes the old `sandbox-devops.key`. The public half of each is that
  workspace's `authorized_key` parameter. Both items must be in the `cluster` Bitwarden project, and a private key stored there
  must end with a newline.
- **Target.** Each profile selects its SSH terminal with `terminal.backend: ssh` in its `config.yaml` and reads the target
  from its `.env` ([Hermes docs](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools)):
  `TERMINAL_SSH_HOST`, `TERMINAL_SSH_USER=vscode`, `TERMINAL_SSH_PORT=22` and `TERMINAL_SSH_KEY=/opt/data/ssh/hermes-{main,worker}.key`;
  `terminal.cwd` is `/workspaces`. The chart writes these keys (`hermes.profileEnv`). One profile has one SSH target. The server
  host key is kept on the home volume, so `known_hosts` stays valid when a workspace restarts onto a new pod.
- **File tools.** Hermes `write_file` refuses paths outside `/opt/data`, so the `file` toolset is off and files are edited through the terminal.
- **Repository rules.** Startup context files such as `AGENTS.md` are not loaded from the workspace over SSH. The skills read the
  repository's `AGENTS.md` from the default branch explicitly.
- **Shell.** Hermes runs commands non-interactively (no TTY). Tools come from `/usr/local/bin` shims, so no shell init is needed.

- **Environment.** The optional `GITHUB_TOKEN`, the extra secrets, `TALOSCONFIG` (when on), `KUBERNETES_SERVICE_HOST` and
  `KUBERNETES_SERVICE_PORT` (when `kubernetes_access` is on, so `kubectl` finds the API server) and `SSH_AUTH_SOCK` are handed to SSH
  sessions through `~/.ssh/environment`, rebuilt at every start from a file in `/cache`.
- **Image.** sshd comes from the `dev-workstation` image (`openssh-server`, added in `mmalyska/containers`). With an older
  image the workspace still starts and the log says sshd is missing.

## Git identity and signing

Each workspace acts as its own GitHub account. The template parameters set it up:

- `github_token_ref` is that account's classic token (`repo`, `workflow` and `read:org` scopes). It is both the `GITHUB_TOKEN` for `gh` and the
  HTTPS credential for git. There is no SSH authentication key for git.
- `git_user_name` and `git_user_email` (the account name and its GitHub noreply address) are written to `~/.gitconfig` at every start.
- `signing_key_ref` is an SSH signing key. It is loaded into the in-pod ssh-agent and never written to a volume. All of the
  account's commits are signed and show "Verified" on GitHub, because the public half is registered on the account as a signing key.

The Hermes pod holds none of this: the tokens and signing keys exist only in the workspaces.

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
