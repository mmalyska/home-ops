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

A single shared base image, built in `containers`, feeds both the Coder workspace and the devcontainers of this and other repositories. Secrets for the workspace come from one dedicated Bitwarden Secrets Manager (BWS) project, read with a token scoped to that project only.

## Non-goals

- Replacing or changing the `devops` Coder workspace and the `sandbox-*` images. Hermes uses them (`hermes-agent` SSHes into `sandbox-devops`); see Decisions.
- Running Docker, `docker build` or compose inside the workspace. Images are built in GitHub Actions.
- Public (internet) access to Coder. It stays on `envoy-internal` (LAN and VPN).
- Retiring the local devcontainer.

## Decisions (owner, 2026-11-02)

| #   | Topic               | Decision                                                                                         |
| --- | ------------------- | ------------------------------------------------------------------------------------------------ |
| D1  | Image home          | Extend `mmalyska/containers` with a new dev image. No new repository.                            |
| D2  | Platforms           | linux/amd64 and linux/arm64 (a local Apple Silicon machine needs arm64).                         |
| D3  | Access              | LAN and VPN only, as now. Client is VS Code Remote-SSH or the Coder extension.                   |
| D4  | Cluster credentials | The workspace holds admin credentials (kubeconfig, talosconfig), same as the local devcontainer. |
| D5  | Tooling model       | Fat image, one workspace, many repositories. No envbuilder.                                      |
| D6  | Docker              | Not needed in the workspace.                                                                     |
| D7  | Signing             | Commits are GPG-signed; the key is stored in the BWS project.                                    |
| D8  | AI tools            | Claude Code (interactive login) and codex-cli are installed.                                     |
| D9  | `sandbox-*`         | Left unchanged. They serve Hermes. A separate template, image and workspace are added.           |
| D10 | Resources           | Start at 2 CPU and 3 Gi memory; measure, then adjust.                                            |
| D11 | Secrets             | One new BWS project and one machine-account token with access to that project only.              |

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
- One image, two uses. The image carries the `devcontainer.metadata` label so a repository's `devcontainer.json` can reference it with `"image": ...` and no `features` block, and Coder can run it with the agent init script as the command. Whether to split into two tags is open question Q12.
- Publish multi-arch to GHCR with a digest-pinned consumer reference, as `devcontainer-publish.yaml` does now.

### 2. Coder template and workspace

- A new template (working name `dev`) so the Hermes-facing `sandbox` template is not touched. Alternative: a new workspace on the existing template; open question Q7.
- One workspace, one persistent volume mounted so repositories live under `/workspaces/<repo>`. This keeps every path assumed by existing scripts and every Claude project directory key identical to the local devcontainer. Alternative layout is open question Q8.
- Pod runs as the non-root image user, with no privilege escalation and all capabilities dropped, which satisfies the existing `baseline` Pod Security level. Open question Q9 asks whether anything needs root.
- SSH: proposed to use Coder's built-in SSH through the agent (`coder config-ssh` writes the VS Code Remote-SSH host entry). That removes sshd, the root requirement, the per-workspace LoadBalancer IP and the `authorized_key` parameter. The owner already has the Coder CLI locally. Open question Q10 confirms.
- Resources: requests equal limits for memory (3 Gi), CPU limit 2, CPU request chosen from the measurement in T9. PVC size is a parameter; the current default of 2Gi is too small for several repositories, worktrees and toolchains (the local baseline is about 4.6 GB before any build cache), so the spec proposes a larger default; open question Q11.
- Backups: the existing VolSync pattern is reused, but see Risks R2 for what must not be on the volume.

### 3. Secrets (BWS)

- One new BWS project holds everything the workspace needs. One machine-account token, read-only, scoped to that project only. The owner creates the project and the token; nothing in this repository names the project or its identifiers.
- Delivery: an `ExternalSecret` (store `bitwarden`) creates a Kubernetes Secret holding the machine token and the project reference. The pod receives them through `secret_key_ref`, the same pattern as `LITELLM_API_KEY`. No secret value passes through Terraform variables, so none reaches Terraform state.
- At workspace start an entrypoint step runs the BWS CLI once and exports the project's secrets to the shell environment of the session (equivalent to `bws run`), failing soft with a clear message when the token is missing.
- Values that are files (kubeconfig, talosconfig, GPG private key) are stored in BWS as secret values and written at start to a memory-backed `emptyDir`, never to the home volume. `KUBECONFIG`, `TALOSCONFIG` and `GNUPGHOME` point there. They are re-created on every start.
- Secret inventory (names only) is open question Q4 and task T4.

### 4. Repositories and bootstrap

- A list of repositories to clone (public repo names, no secrets) is kept in the image or in `mmalyska/dotfiles`; open question Q13.
- A bootstrap step in the image clones missing repositories, applies chezmoi dotfiles, sets git identity and GPG signing, and runs each repository's own setup. Because `devcontainer.json` lifecycle commands only run under a devcontainer tool, the bootstrap either calls the three scripts a repository names (`onCreateCommand`, `updateContentCommand`, `postStartCommand`) directly or each repository gains a small tool-agnostic `setup` entry point that `devcontainer.json` also calls. T6 is a spike that picks one.
- The worktree rule from `AGENTS.md` applies unchanged: primary checkouts stay on `main`; work happens in `.worktrees/`.
- Claude memory symlinks (`postStartCommand.sh`) are generalised from the hard-coded home-ops path to the current repository, so they keep working under `/workspaces/<repo>`.

### 5. Migration of other devcontainers

After the image is stable, `home-ops` switches `.devcontainer/devcontainer.json` from `home-ops-devcontainer` to the new image and deletes `.github/.devcontainer`, its publish workflow and its Renovate rules. `containers`, `claude-plugins` and the other repositories follow one at a time. Each switch is its own PR and keeps the previous image digest as the rollback.

## Risks

| #   | Risk                                                                                                                                                                                                                                                                                                   | Mitigation                                                                                                                                                                                                                                                                                                                                                                                       |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| R1  | Admin kubeconfig, talosconfig, GPG key and the BWS token live in a pod on the cluster they administer (owner accepted, D4). A compromised workspace is cluster admin. Also a circular dependency: if Ceph, CoreDNS, ArgoCD or the Coder database is down the workspace is down when it is needed most. | The local devcontainer stays as the break-glass environment (non-goal: retiring it). Token scoped to one project and rotatable. Workspace reachable only from LAN and VPN. Consider a Cilium NetworkPolicy limiting workspace egress (Q14). The consent rules in `AGENTS.md` and `.claude/settings.json` ship in the image and repositories, so they apply in the workspace too; T8 verifies it. |
| R2  | VolSync snapshots the whole home volume to S3 every 6 hours. Anything written there is backed up, including Claude and Codex login tokens.                                                                                                                                                             | Credentials from BWS never touch the volume (memory-backed `emptyDir`). Tool login tokens: accept, or exclude their directories from the restic source; Q3.                                                                                                                                                                                                                                      |
| R3  | 3 Gi is tight with several repositories, `terraform`/`helm`, and the VS Code server; exceeding it OOM-kills the pod.                                                                                                                                                                                   | Memory request equals limit, measure for two weeks (T9), adjust. Check node headroom first; mc1-mc3 also run cluster workloads.                                                                                                                                                                                                                                                                  |
| R4  | Fat image grows, rebuild and pull time grow, and tool versions drift between the image and a repository's expectations.                                                                                                                                                                                | Pin and Renovate every tool; keep the `.tool-versions` or equivalent per repository out of scope until needed. Measure image size in T2.                                                                                                                                                                                                                                                         |
| R5  | A sandbox image regression breaks Hermes.                                                                                                                                                                                                                                                              | `sandbox-*` untouched (D9); new image is a separate app.                                                                                                                                                                                                                                                                                                                                         |
| R6  | Lifecycle scripts assume devcontainer behaviour (`/workspaces/<repo>`, user `vscode`, Codespaces env flags).                                                                                                                                                                                           | Same path and a user-name decision (Q6); T6 spike before building.                                                                                                                                                                                                                                                                                                                               |
| R7  | Merging changes under `cluster/apps/**` deploys them.                                                                                                                                                                                                                                                  | Every runtime step is consent-gated per `AGENTS.md`; the template push and workspace creation are RUNTIME_MUTATION.                                                                                                                                                                                                                                                                              |

## Open questions (to answer before status changes to approved)

| #   | Question                                                                                                                                                                   | Needed for |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| Q1  | Is the new image allowed to depend on Homebrew, or must every tool be a pinned release download? Homebrew is how the devcontainer gets many tools today but is not pinned. | T1, T2     |
| Q2  | Login for codex-cli: interactive like Claude, or API key from BWS?                                                                                                         | T4, T5     |
| Q3  | Should Claude and Codex login tokens be excluded from the backup (R2)?                                                                                                     | T5         |
| Q4  | Secret inventory: names (never values) of secrets for the BWS project, and which are shared with other repositories.                                                       | T4         |
| Q5  | Should the workspace be pinned to specific nodes (mc1 to mc3 only, or avoid the node with least headroom)? Needed after T9 data.                                           | T5, T9     |
| Q6  | User name in the image: `vscode` (devcontainer) or `coder` (sandbox)? Either way UID 1000.                                                                                 | T2, T6     |
| Q7  | New template or new workspace on the existing `sandbox` template?                                                                                                          | T5         |
| Q8  | Repository layout: `/workspaces/<repo>` (recommended, identical paths) or `~/src/<repo>`?                                                                                  | T5, T6     |
| Q9  | Does anything need root inside the workspace pod?                                                                                                                          | T5         |
| Q10 | SSH through the Coder agent (no sshd, no LoadBalancer IP) or keep sshd with a fixed IP?                                                                                    | T5         |
| Q11 | Volume size for the home and repositories volume.                                                                                                                          | T5         |
| Q12 | One image with devcontainer metadata, or two tags (devcontainer, Coder)?                                                                                                   | T2         |
| Q13 | Where does the list of repositories to clone live: image, dotfiles, or a Coder parameter?                                                                                  | T6         |
| Q14 | Add a NetworkPolicy limiting workspace egress and ingress?                                                                                                                 | T5         |
| Q15 | Which machine is the Apple Silicon one, and does it use the devcontainer flavour of the image? (Confirms D2.)                                                              | T2         |

## Phases

1. **Inventory and spikes** (T1, T6): tool list, pipeline in `containers`, bootstrap approach.
2. **Image** (T2, T3): `dev-workstation` in `containers`, multi-arch, published.
3. **Secrets** (T4): BWS project and token (owner), ExternalSecret.
4. **Workspace** (T5, T7, T8): template, workspace, first login, verification.
5. **Migrate** (T10): home-ops devcontainer, then other repositories.
6. **Measure and document** (T9, T11): resource tuning, docs and skills.

Tasks are in [tasks.md](tasks.md).

## Validation

Per [`.agents/policy/validation.md`](../../.agents/policy/validation.md). For this plan's changes: `task lint:all`, `helm template` and `kubectl kustomize` for anything under `cluster/apps/ai/coder`, `terraform fmt` and `terraform validate` for `workspace-template/`, `bash .agents/tests/run.sh` and `.agents/bin/check-plans`. Live checks (workspace starts, secrets arrive, tools run) are listed in T7 and T8 and need consent.

## Status

Draft. Spec written; open questions Q1 to Q15 are waiting for the owner. No implementation has started.
