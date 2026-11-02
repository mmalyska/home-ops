---
status: draft
owner: repository owner
profile: STANDARD
topology: SOLO
base_sha: 12666e7ed4c48b7caa03e6901a7905b77d809927
branch: docs/remote-dev-workspace
worktree: .worktrees/docs/remote-dev-workspace
pr: not-opened
started: 2026-11-02
updated: 2026-11-02
---

# Always-on development workspace on the cluster

## Goal

One persistent, always-on development environment on the Talos cluster (Coder), in which the owner can work on `home-ops` and on other repositories of their account (`containers`, `claude-plugins`, `argocd-secret-replacer` and others). It is an evolution of the local devcontainer, not a replacement: the local devcontainer stays and keeps working.

A single shared base image, built in `containers`, feeds both the Coder workspace and the devcontainers of this and other repositories. Secrets for a workspace come from a dedicated Bitwarden Secrets Manager (BWS) project per workspace type, read with a token scoped to that project only. Cluster access is not a BWS secret: it comes from the Talos and Kubernetes service-account mechanisms, granted per workspace.

## Non-goals

- Replacing or changing the `devops` Coder workspace and the `sandbox-*` images. Hermes uses them (`hermes-agent` SSHes into `sandbox-devops`); see Decisions.
- Running Docker, `docker build` or compose inside the workspace. Images are built in GitHub Actions.
- Public (internet) access to Coder. It stays on `envoy-internal` (LAN and VPN).
- Retiring the local devcontainer.

## Decisions (owner, 2026-11-02)

| #   | Topic             | Decision                                                                                                                                                                                                                                                                                                                  |
| --- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Image home        | Extend `mmalyska/containers` with a new dev image. No new repository.                                                                                                                                                                                                                                                     |
| D2  | Platforms         | linux/amd64 and linux/arm64 (a local Apple Silicon machine needs arm64).                                                                                                                                                                                                                                                  |
| D3  | Access            | LAN and VPN only, as now. Client is VS Code Remote-SSH or the Coder extension.                                                                                                                                                                                                                                            |
| D4  | Cluster access    | Opt-in per workspace type, not a BWS secret. Talos: a `talos.dev` ServiceAccount with the `os:reader` role (read-only `talosctl`). Mutating Talos work stays on the local devcontainer. Kubernetes access: see Q16. Supersedes the earlier "admin credentials" answer.                                                    |
| D5  | Tooling model     | Fat image, one workspace, many repositories. No envbuilder.                                                                                                                                                                                                                                                               |
| D6  | Docker            | Not needed in the workspace.                                                                                                                                                                                                                                                                                              |
| D7  | Signing           | Commits are GPG-signed; the key is stored in the BWS project.                                                                                                                                                                                                                                                             |
| D8  | AI tools          | Claude Code (interactive login) and codex-cli are installed.                                                                                                                                                                                                                                                              |
| D9  | `sandbox-*`       | Left unchanged. They serve Hermes. A separate template, image and workspace are added.                                                                                                                                                                                                                                    |
| D10 | Resources         | Start at 2 CPU and 3 Gi memory; measure, then adjust.                                                                                                                                                                                                                                                                     |
| D11 | Secrets           | One BWS project and one read-only machine-account token per workspace type, each scoped to its own project. Common to all types: GPG signing key and `GITHUB_TOKEN`. The dev workspace also gets `TERRAFORM_TOKEN`. The Hermes sandboxes get only what they need. The template takes the secret reference as a parameter. |
| D12 | Homebrew          | Not in the image. Every tool is a pinned, checksummed release download with a Renovate annotation.                                                                                                                                                                                                                        |
| D13 | User name         | `vscode`, UID 1000 (matches devcontainer scripts and Codespaces).                                                                                                                                                                                                                                                         |
| D14 | Repository layout | `/workspaces/<repo>`, same as the local devcontainer; the volume is mounted at `/workspaces`.                                                                                                                                                                                                                             |
| D15 | SSH               | Through the Coder agent (`coder config-ssh`). No sshd, no LoadBalancer IP, no `authorized_key` parameter.                                                                                                                                                                                                                 |
| D16 | Template          | New template; the `sandbox` template is not touched.                                                                                                                                                                                                                                                                      |
| D17 | Sudo              | None. Non-root pod, tools baked into the image. The `sudo` calls in the repo scripts are fixed in the bootstrap.                                                                                                                                                                                                          |
| D18 | Volume            | 20 Gi for home and repositories, parameterised.                                                                                                                                                                                                                                                                           |
| D19 | Image tags        | One image carrying the `devcontainer.metadata` label; no second tag.                                                                                                                                                                                                                                                      |
| D20 | Tool logins       | Claude and Codex use interactive login; tokens sit on the home volume and are included in the VolSync backup.                                                                                                                                                                                                             |
| D21 | Repo list         | Kept in `mmalyska/dotfiles` and applied by the bootstrap.                                                                                                                                                                                                                                                                 |
| D25 | Local flow        | The local devcontainer is unchanged: it keeps loading the existing BWS project including the `TALHELPER_*` secrets and running `task talos:init`. The workspace does not get the `TALHELPER_*` secrets and does not run `talos:init`, `talos:generate` or `apply-config` (confirmed 2026-11-02).                          |
| D22 | NetworkPolicy     | Ingress deny-all for the workspace pod; egress stays open.                                                                                                                                                                                                                                                                |
| D23 | Node placement    | No pinning. Measured 2026-11-02: mc1 to mc3 at 24 to 25% CPU and 37 to 46% memory; nv1 is excluded by its GPU taint. Revisit after T9.                                                                                                                                                                                    |
| D24 | arm64             | A Mac runs the devcontainer flavour locally, so the image is published for amd64 and arm64.                                                                                                                                                                                                                               |

## Current state (facts, verified 2026-11-02)

See [evidence.md](evidence.md). In short:

- `home-ops-devcontainer` is built in this repo from `.github/.devcontainer` with `devcontainers/ci` (amd64 and arm64). Tools come from local features: homebrew, common, bws-cli, coder-cli, codex-cli, plus Go. Repo setup is in `.devcontainer/scripts/*.sh`.
- `sandbox-{base,devops,dotnet,node,python}` are plain Dockerfiles in `containers/apps/`, amd64 only, user `coder`, sshd and passwordless sudo. They contain none of: Claude Code, `bws`, `gh`, direnv, task, pre-commit, chezmoi, Homebrew, Go.
- The Coder template (`cluster/apps/ai/coder/workspace-template/main.tf`) runs one Deployment per workspace as root, with sshd started from `startup_script`, a fixed LoadBalancer IP for SSH, a ceph-block home PVC (default parameter 2Gi) and a VolSync restic backup of the whole PVC every 6 hours. Limits are 1 CPU and 2 Gi.
- The Coder HTTPRoute is on `envoy-internal` only. The namespace enforces Pod Security `baseline`.
- Baseline from the local devcontainer (one repo, one Claude session): memory 1.6 GiB in use, 2.1 GiB peak; `/workspaces` 2.8 GB, home 1.8 GB.

## Design

### 1. Image (in `containers`)

- New app, working name `dev-workstation`, next to `sandbox-*`, following the same layout (`Dockerfile`, `metadata.json`, `ci/`, `README.md`) and the same Renovate annotations.
- Base: pinned Ubuntu LTS digest, like the current devcontainer image. Non-root user with UID 1000.
- Contents are the union of: the devcontainer features (homebrew or its replacement, common, bws-cli, coder-cli, codex-cli, Go), the `sandbox-devops` tools (kubectl, helm, talosctl, terraform, k9s, age) and what the repo scripts call (gh, direnv, task, pre-commit, chezmoi, krew, gnupg). Claude Code is added. Exact list comes from task T1.
- Every tool download resolves the architecture (no hard-coded `amd64`) and is version-pinned with a Renovate annotation and a checksum where upstream publishes one.
- One image, two uses. The image carries the `devcontainer.metadata` label so a repository's `devcontainer.json` can reference it with `"image": ...` and no `features` block, and Coder can run it with the agent init script as the command. There is no second tag (D19).
- Publish multi-arch to GHCR with a digest-pinned consumer reference, as `devcontainer-publish.yaml` does now.

### 2. Coder template and workspace

- A new template (working name `dev`) so the Hermes-facing `sandbox` template is not touched (D16).
- One workspace, one persistent volume mounted at `/workspaces` so repositories live under `/workspaces/<repo>` (D14). This keeps every path assumed by existing scripts and every Claude project directory key identical to the local devcontainer.
- Pod runs as the non-root `vscode` user, no sudo, no privilege escalation, all capabilities dropped (D13, D17). The existing `baseline` Pod Security level is satisfied.
- SSH goes through Coder's built-in agent tunnel (`coder config-ssh` writes the VS Code Remote-SSH host entry), which removes sshd, the root requirement, the per-workspace LoadBalancer IP and the `authorized_key` parameter (D15).
- Resources: requests equal limits for memory (3 Gi), CPU limit 2, CPU request chosen from the measurement in T9. PVC size is a parameter with a default of 20 Gi (D18); the current template default of 2Gi is too small (the local baseline is about 4.6 GB before any build cache).
- The pod runs in its own namespace (Q17), has an ingress deny-all NetworkPolicy (D22), and takes its secret reference as a parameter (D11).
- Backups: the existing VolSync pattern is reused, but see Risks R2 for what must not be on the volume.

### 3. Secrets (BWS)

- One BWS project per workspace type holds what that type needs; one machine-account token per project, read-only. The dev workspace's project holds `GITHUB_TOKEN`, `TERRAFORM_TOKEN` and the GPG signing key. The template takes the name of the `ExternalSecret`/Secret as a parameter so a Hermes sandbox type can use a smaller project later. The owner creates projects and tokens; nothing in this repository names a project or its identifiers.
- Note: the local flow loads an existing BWS project wholesale (`.envrc`: `bws secret list <project> -o env`). The local `task talos:init` builds the talosconfig from the `TALHELPER_*` Talos secrets in that project. The workspace will not receive those secrets, so `task talos:init` cannot run there (also because `task talos:install` uses `sudo`); see section 3a.
- Delivery: an `ExternalSecret` (store `bitwarden`) creates a Kubernetes Secret holding the machine token and the project reference. The pod receives them through `secret_key_ref`, the same pattern as `LITELLM_API_KEY`. No secret value passes through Terraform variables, so none reaches Terraform state.
- At workspace start an entrypoint step runs the BWS CLI once and exports the project's secrets to the shell environment of the session (equivalent to `bws run`), failing soft with a clear message when the token is missing.
- The GPG private key is stored in BWS as a secret value and imported at start into a memory-backed `emptyDir` used as `GNUPGHOME`, never into the home volume. It is re-created on every start.
- Secret inventory for the dev workspace (names only): `GITHUB_TOKEN`, `TERRAFORM_TOKEN`, GPG signing key. The Cloudflare credentials Terraform uses and tokens for other repositories are not in the inventory; add them if a task needs them (Q18).

### 3a. Cluster access (not BWS)

- Talos: the control planes already run `KubeTalosAPIAccessConfig` (`provision/talos/patches/controlplane/40-talos-api-access.yaml`; roles `os:etcd:backup` and `os:admin`; namespaces `talos-backup` and `tuppr`) and the `serviceaccounts.talos.dev` CRD is installed. The workspace gets a `talos.dev/v1alpha1` `ServiceAccount` with `roles: [os:reader]`; Talos generates a Secret containing a talosconfig, mounted into the pod (field and mount details: `talosctl inject serviceaccount` output in the [Talos guide](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/talos-api-access-from-k8s)). This needs `os:reader` added to `allowedRoles` and the workspace namespace added to `allowedKubernetesNamespaces`: a control-plane machine config change (consent-gated `apply-config`).
- Escalation risk: `allowedRoles` is cluster-wide and already contains `os:admin`. Anyone who can create a `ServiceAccount.talos.dev` in an allowed namespace can request `os:admin`. The workspace therefore needs its own namespace (Q17), and RBAC must stop everything except GitOps from creating those resources there. The Coder provisioner has broad RBAC in `coder`, so the workspace must not be provisioned into `coder` with that namespace allowed.
- Not documented by Talos, to verify in spike T12: the Secret's keys, credential lifetime and rotation, how the interaction between the two lists works, and whether `os:reader` can run `talosctl kubeconfig`.
- Kubernetes: kubeconfig is regenerated, not stored. The mechanism and the permission level (read-only or admin) are open question Q16.
- `.envrc` sets `KUBECONFIG` to `~/.kube/config` (home volume, backed up) and defaults `TALOSCONFIG` to a file inside the repository tree. The bootstrap must point both to the memory-backed volume or the mounted Secret so no credential file lands on the backed-up volume.

### 4. Repositories and bootstrap

- A list of repositories to clone (public repo names, no secrets) is kept in `mmalyska/dotfiles` and applied by chezmoi on bootstrap (D21).
- A bootstrap step in the image clones missing repositories, applies chezmoi dotfiles, sets git identity and GPG signing, and runs each repository's own setup. Because `devcontainer.json` lifecycle commands only run under a devcontainer tool, the bootstrap either calls the three scripts a repository names (`onCreateCommand`, `updateContentCommand`, `postStartCommand`) directly or each repository gains a small tool-agnostic `setup` entry point that `devcontainer.json` also calls. T6 is a spike that picks one.
- The worktree rule from `AGENTS.md` applies unchanged: primary checkouts stay on `main`; work happens in `.worktrees/`.
- Claude memory symlinks (`postStartCommand.sh`) are generalised from the hard-coded home-ops path to the current repository, so they keep working under `/workspaces/<repo>`.

### 5. Migration of other devcontainers

After the image is stable, `home-ops` switches `.devcontainer/devcontainer.json` from `home-ops-devcontainer` to the new image and deletes `.github/.devcontainer`, its publish workflow and its Renovate rules. `containers`, `claude-plugins` and the other repositories follow one at a time. Each switch is its own PR and keeps the previous image digest as the rollback.

## Risks

| #   | Risk                                                                                                                                                                                                                                                                                                                                                     | Mitigation                                                                                                                                                                                                                                                                                                                                                                                       |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R1  | The GPG key, the BWS token and cluster credentials live in a pod on the cluster they administer. With `os:reader` a compromised workspace cannot change Talos, but its Kubernetes permission level is still open (Q16). Also a circular dependency: if Ceph, CoreDNS, ArgoCD or the Coder database is down the workspace is down when it is needed most. | The local devcontainer stays as the break-glass environment (non-goal: retiring it). Token scoped to one project and rotatable. Workspace reachable only from LAN and VPN. Consider a Cilium NetworkPolicy limiting workspace egress (Q14). The consent rules in `AGENTS.md` and `.claude/settings.json` ship in the image and repositories, so they apply in the workspace too; T8 verifies it. |
| R2  | VolSync snapshots the whole home volume to S3 every 6 hours. Anything written there is backed up, including Claude and Codex login tokens.                                                                                                                                                                                                               | The GPG key and cluster credentials never touch the volume (memory-backed `emptyDir` and the mounted Talos Secret). Tool login tokens are accepted in the backup (D20); the restic repository is encrypted and the tokens are revocable.                                                                                                                                                         |
| R3  | 3 Gi is tight with several repositories, `terraform`/`helm`, and the VS Code server; exceeding it OOM-kills the pod.                                                                                                                                                                                                                                     | Memory request equals limit, measure for two weeks (T9), adjust. Check node headroom first; mc1-mc3 also run cluster workloads.                                                                                                                                                                                                                                                                  |
| R4  | Fat image grows, rebuild and pull time grow, and tool versions drift between the image and a repository's expectations.                                                                                                                                                                                                                                  | Pin and Renovate every tool; keep the `.tool-versions` or equivalent per repository out of scope until needed. Measure image size in T2.                                                                                                                                                                                                                                                         |
| R5  | A sandbox image regression breaks Hermes.                                                                                                                                                                                                                                                                                                                | `sandbox-*` untouched (D9); new image is a separate app.                                                                                                                                                                                                                                                                                                                                         |
| R6  | Lifecycle scripts assume devcontainer behaviour (`/workspaces/<repo>`, user `vscode`, Codespaces env flags).                                                                                                                                                                                                                                             | Same path and user name as local (D13, D14); T6 spike before building.                                                                                                                                                                                                                                                                                                                           |
| R7  | Merging changes under `cluster/apps/**` deploys them.                                                                                                                                                                                                                                                                                                    | Every runtime step is consent-gated per `AGENTS.md`; the template push and workspace creation are RUNTIME_MUTATION.                                                                                                                                                                                                                                                                              |

## Questions

Resolved with the owner on 2026-11-02 (Q1 to Q15 from the first draft); the answers are decisions D4 and D11 to D24 above:

| Q   | Topic                      | Resolved as                                            |
| --- | -------------------------- | ------------------------------------------------------ |
| Q1  | Homebrew                   | D12                                                    |
| Q2  | Codex login                | D20                                                    |
| Q3  | Login tokens in the backup | D20                                                    |
| Q4  | Secret inventory (dev)     | D11, section 3 (cluster files are not BWS secrets: D4) |
| Q5  | Node placement             | D23                                                    |
| Q6  | User name                  | D13                                                    |
| Q7  | New template or workspace  | D16                                                    |
| Q8  | Repository layout          | D14                                                    |
| Q9  | Root / sudo                | D17                                                    |
| Q10 | SSH model                  | D15                                                    |
| Q11 | Volume size                | D18                                                    |
| Q12 | Image tags                 | D19                                                    |
| Q13 | Repo list location         | D21                                                    |
| Q14 | NetworkPolicy              | D22                                                    |
| Q15 | arm64 need                 | D24                                                    |

Open (to answer before status changes to approved):

| #   | Question                                                                                                                                                                                                                                                                                           | Needed for   |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| Q16 | Kubernetes access from the workspace: which mechanism (in-cluster Kubernetes ServiceAccount with RBAC in git, or a kubeconfig regenerated at start from the Talos credential) and which permission level (read-only, a defined write set, or cluster-admin)? Talos is settled at `os:reader` (D4). | T5, T12, T13 |
| Q17 | Which namespace does the dev workspace run in? It must not be `coder` if that namespace is added to `allowedKubernetesNamespaces` (section 3a). The Coder provisioner needs RBAC in the new namespace to create the workload.                                                                      | T5, T13      |
| Q18 | Other secrets the dev workspace needs: Cloudflare credentials for Terraform in `provision/terraform/cloudflare`, tokens for `claude-plugins`, `containers` or other repositories, `BOT_APP_PRIVATE_KEY` (referenced by Taskfiles/workflows, probably CI-only)? Names only.                         | T4           |

## Phases

1. **Inventory and spikes** (T1, T6, T12): tool list, pipeline in `containers`, bootstrap approach, Talos ServiceAccount mechanics.
2. **Image** (T2, T3): `dev-workstation` in `containers`, multi-arch, published.
3. **Secrets and cluster access** (T4, T13): BWS project and token (owner), ExternalSecret; Talos machine config change for `os:reader` and the namespace.
4. **Workspace** (T5, T7, T8): template, workspace, first login, verification.
5. **Migrate** (T10): home-ops devcontainer, then other repositories.
6. **Measure and document** (T9, T11): resource tuning, docs and skills.

Tasks are in [tasks.md](tasks.md).

## Validation

Per [`.agents/policy/validation.md`](../../.agents/policy/validation.md). For this plan's changes: `task lint:all`, `helm template` and `kubectl kustomize` for anything under `cluster/apps/ai/coder`, `terraform fmt` and `terraform validate` for `workspace-template/`, `bash .agents/tests/run.sh` and `.agents/bin/check-plans`. Live checks (workspace starts, secrets arrive, tools run) are listed in T7 and T8 and need consent.

## Status

Draft. Spec written and committed (`4ac268a3`). Q1 to Q15 are resolved (2026-11-02) and recorded as decisions; the cluster-access design changed (D4, section 3a). Q16, Q17 and Q18 are open, and the Talos ServiceAccount mechanics need spike T12. No implementation has started.
