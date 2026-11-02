# Tasks

Each task can be executed without reading `plan.md`. A task that depends on an open question (Qn) is blocked until the owner answers it; the question text is in `plan.md`. Do all repository work in a linked worktree; run `.agents/bin/worktree-preflight` before the first write. Every command that changes cluster or external state needs fresh consent from the owner in the current session.

Common context: the goal is one always-on Coder workspace, on the Talos cluster, for several repositories of the owner, built from one shared multi-arch image published from `mmalyska/containers`. Secrets come from one dedicated BWS project. `sandbox-*` images and the `devops` workspace belong to Hermes and must not be changed.

## T1. Inventory the tools the new image needs

- Status: todo. Blocked by: Q1.
- Do: list every tool the home-ops devcontainer and `sandbox-devops` provide, and every tool the home-ops scripts, `Taskfile`, pre-commit config and `.envrc` call. Read `.github/.devcontainer/local-features/*/install*.sh`, `.devcontainer/scripts/*.sh`, `.taskfiles/`, `.pre-commit-config.yaml`, `.envrc` and the `containers/apps/sandbox-devops/Dockerfile`. Then do the same for `claude-plugins`, `containers` and `argocd-secret-replacer` (read only, via `gh api` or a clone).
- Output: `.plans/remote-dev-workspace/tools.md` with a table: tool, source today (feature, Dockerfile, brew), version pin today, used by which repository, upstream publishes checksum (yes/no), has arm64 build (yes/no), Renovate datasource.
- Check: every tool called by a script or Taskfile target appears in the table; no secret value or private domain appears in the file.

## T2. Build the `dev-workstation` image in `containers`

- Status: todo. Blocked by: T1, Q1, Q6, Q12, Q15.
- Do: in `mmalyska/containers` add `apps/dev-workstation/` with `Dockerfile`, `README.md`, `metadata.json` and `ci/`, copying the layout and metadata rules of `apps/sandbox-devops`. Pinned Ubuntu LTS digest. Non-root user (name from Q6, UID 1000). Install the tools from `tools.md`, resolving the architecture instead of hard-coding amd64, with version pins and Renovate annotations, and checksums where upstream publishes them. Install Claude Code and codex-cli. Add the `devcontainer.metadata` label (or the two tags from Q12). Build linux/amd64 and linux/arm64 on native runners.
- Check: CI builds both platforms; `docker run --rm <image> <tool> --version` for every tool on both platforms (run in CI, not in the workspace); image size is recorded in the PR; Renovate dry run picks up the new annotations; no `sandbox-*` file is changed.
- Rollback: delete the app directory; nothing consumes it yet.

## T3. Publish and pin the image

- Status: todo. Blocked by: T2.
- Do: after merge in `containers`, record the published tag and the digest of the multi-arch manifest. Add the image reference (digest-pinned) to the PRs of T5 and T10 only.
- Check: `docker buildx imagetools inspect <image>` shows both platforms; the digest in the consuming PR matches.

## T4. Create the BWS project and the workspace token (owner action)

- Status: todo. Blocked by: Q2, Q4.
- Do (owner, in Bitwarden; the agent never reads values): create a project for the workspace; add the secrets from the inventory in Q4 by name. Cover at least: GitHub token, Terraform token, the cluster kubeconfig and talosconfig as values, the GPG signing key, and the other repositories' tokens if any. Create a machine account with read-only access to that project only, and issue one access token.
- Agent part: write the secret **names** (no values, no identifiers) into `docs/` and into the T5 template comments; add an `ExternalSecret` (store `bitwarden`) that creates the Kubernetes Secret with the access token and the project reference. The Bitwarden identifiers stay out of the repository: use the same mechanism other ExternalSecrets in `cluster/apps/ai/coder/templates/externalsecret.yaml` use for references.
- Check: `kubectl kustomize` or `helm template` for `cluster/apps/ai/coder` renders the ExternalSecret with no identifier or value in the output committed to git; gitleaks passes. Live: the Secret exists after sync (consent-gated sync).

```sh consent-gated
# After merge, owner decides when ArgoCD syncs the coder app; do not run without fresh consent.
argocd app sync coder
```

## T5. New Coder template and workspace

- Status: todo. Blocked by: T3, T4, Q3, Q5, Q7, Q8, Q9, Q10, Q11, Q14.
- Do: add the template under `cluster/apps/ai/coder/workspace-template/` (new directory for a new template, or a new parameter set on the existing one if Q7 says so). Requirements:
  - image from T3 (digest-pinned); `arch` follows the image platform;
  - non-root pod, `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault` (if Q9 allows);
  - memory request = limit = 3Gi; CPU limit 2; CPU request from T9 (start at 500m);
  - PVC size from Q11, mounted so repositories live where Q8 says;
  - SSH through the Coder agent (Q10); no sshd and no LoadBalancer Service if Q10 says so;
  - `emptyDir` with `medium: Memory` for credentials files (kubeconfig, talosconfig, GPG home), sized small (for example 64Mi) and counted in the 3Gi limit;
  - the token and project reference from T4 read with `secret_key_ref`; no secret value in Terraform variables or state;
  - VolSync backup as in the current template; exclusions per Q3;
  - NetworkPolicy per Q14.
- Check (local): `terraform fmt -check`, `terraform validate` in the template directory; `helm template` for the app; `bash .agents/tests/run.sh`; `task lint:all` read, not assumed.
- Check (live, consent-gated): push the template and create the workspace.

```sh consent-gated
# Pushing a template and creating a workspace are RUNTIME_MUTATION; ask first.
coder templates push <template-name> --directory cluster/apps/ai/coder/workspace-template/<dir> --yes
coder create <workspace-name> --template <template-name>
```

- Rollback: `coder delete <workspace-name>` is DESTRUCTIVE for its volume; first confirm a VolSync snapshot exists. Deleting the template does not touch `sandbox`.

## T6. Spike: repository bootstrap

- Status: todo. Blocked by: Q6, Q8, Q13.
- Do: decide how the workspace runs each repository's setup. Option A: the image bootstrap calls the `onCreateCommand`, `updateContentCommand` and `postStartCommand` scripts named in the repository's `devcontainer.json` (note that file may contain comments, so parse it with a JSONC-aware tool). Option B: each repository gets a tool-agnostic `setup` entry point that `devcontainer.json` also calls. Try A on a copy of `home-ops` in a scratch container started from the T2 image and record what breaks (Codespaces-only branches, `NET_ADMIN`, hard-coded `/workspaces/home-ops` in `postStartCommand.sh`, `task` targets that expect the VPN).
- Output: `.plans/remote-dev-workspace/bootstrap.md` with the chosen option, the list of script changes, and the generalised memory-symlink loop for `.claude/memory`.
- Check: the spike runs to the end on both amd64 and arm64 if arm64 is available; no step needs the cluster or secrets.

## T7. First start and login

- Status: todo. Blocked by: T5, T6.
- Do (owner at the keyboard): connect with VS Code through the Coder extension, run `claude` and `codex` login (per Q2), clone the repositories, check GPG signing with a throwaway commit in a scratch repository (not on `main` of a real repo).
- Check: `git log --show-signature -1` verifies in the scratch repository; `claude` and `codex` start; `kubectl get nodes` and `talosctl get members` work (these are READ-class); `env` is **not** printed (SECRET_ACCESS).

## T8. Verify safety controls in the workspace

- Status: todo. Blocked by: T7.
- Do: confirm in the workspace that the repository's Claude permission file and `AGENTS.md` consent rules apply (open `home-ops`, check that `.claude/settings.json` is read and a denied command is denied), that the worktree preflight returns 0 in a worktree and 3 in the primary checkout, that no credential file exists under the home volume (`find` for the file names only; do not print contents), and that a VolSync snapshot taken after setup does not contain the credential files (restore into a scratch location and list names, consent-gated).
- Check: report each as PASS, FAIL or NOT RUN with the reason.

## T9. Measure and adjust resources

- Status: todo. Blocked by: T7. Run for two weeks after first use.
- Do: query Prometheus (use the `prometheus-historical-queries` skill) for the workspace pod: max and p95 of `container_memory_working_set_bytes`, CPU usage p95, throttling, restarts and OOM kills; and the PVC usage. Check node headroom on the node hosting the pod.
- Output: a table in `plan.md` Status with measured values and the proposed new requests and limits; ask the owner before changing them.
- Check: numbers come from queries, not estimates; the memory limit stays above the observed peak by a stated margin.

## T10. Move devcontainers to the new image

- Status: todo. Blocked by: T3, T6, T8.
- Do: one PR per repository, `home-ops` first. Change `devcontainer.json` to `"image": "<new image>@<digest>"`, drop the `features` block and the local build, keep `runArgs`, `secrets` and lifecycle commands. For `home-ops` also remove `.github/.devcontainer/`, `.github/workflows/devcontainer-publish.yaml` and the Renovate rules that referenced them, and update `docs/`, `AGENTS.md` and the `dev-workflow` skill if they mention the old image. Keep the old image digest in the PR description as the rollback.
- Check: devcontainer rebuilds locally and the three lifecycle commands succeed; `task lint:all`, `bash .agents/tests/run.sh`; `.agents/bin/check-plans`.

## T11. Documentation and skills

- Status: todo. Blocked by: T5.
- Do: document the workspace in `cluster/apps/ai/coder/README.md` (the table currently lists only `devops`), add a docs page for the remote workspace (what it is, how to connect, secret names, break-glass using the local devcontainer), update `.agents/skills/coder-workspace-template-deploy/SKILL.md` for the new template, run `.agents/bin/sync-skills`, and update the Coder row in `docs/` if one exists. Add or update memory files in `.claude/memory/` only for non-obvious findings, and commit them on the branch.
- Check: `task lint:all` read; `bash .agents/tests/run.sh`; links resolve.
