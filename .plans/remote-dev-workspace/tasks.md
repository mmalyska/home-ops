# Tasks

Each task can be executed without reading `plan.md`. A task that depends on an open question (Qn) is blocked until the owner answers it; the question text is in `plan.md`. Do all repository work in a linked worktree; run `.agents/bin/worktree-preflight` before the first write. Every command that changes cluster or external state needs fresh consent from the owner in the current session.

Common context: the goal is one always-on Coder workspace, on the Talos cluster, for several repositories of the owner, built from one shared multi-arch image published from `mmalyska/containers`. Secrets come from one dedicated BWS project. `sandbox-*` images and the `devops` workspace belong to Hermes and must not be changed.

## T1. Inventory the tools the new image needs

- Status: todo. Blocked by: nothing (Homebrew is out, D12: record for each tool its pinned-release source).
- Do: list every tool the home-ops devcontainer and `sandbox-devops` provide, and every tool the home-ops scripts, `Taskfile`, pre-commit config and `.envrc` call. Read `.github/.devcontainer/local-features/*/install*.sh`, `.devcontainer/scripts/*.sh`, `.taskfiles/`, `.pre-commit-config.yaml`, `.envrc` and the `containers/apps/sandbox-devops/Dockerfile`. Then do the same for `claude-plugins`, `containers` and `argocd-secret-replacer` (read only, via `gh api` or a clone).
- Output: `.plans/remote-dev-workspace/tools.md` with a table: tool, source today (feature, Dockerfile, brew), version pin today, used by which repository, upstream publishes checksum (yes/no), has arm64 build (yes/no), Renovate datasource.
- Check: every tool called by a script or Taskfile target appears in the table; no secret value or private domain appears in the file.

## T2. Build the `dev-workstation` image in `containers`

- Status: todo. Blocked by: T1, T15.
- Do: in `mmalyska/containers` add `apps/dev-workstation/` with `Dockerfile`, `README.md`, `metadata.json` and `ci/`, copying the layout and metadata rules of `apps/sandbox-devops`. Pinned Ubuntu LTS digest. Non-root user `vscode`, UID 1000, no sudo (D13, D17). No Homebrew (D12): install the tools from `tools.md` as pinned release downloads, resolving the architecture instead of hard-coding amd64, with Renovate annotations and checksums where upstream publishes them. The `talosctl` version must equal `TALOS_VERSION` in `.taskfiles/talos/Taskfile.yaml`, because `task talos:install` (which uses `sudo`) is skipped only on an exact match; add a Renovate rule or a CI check that keeps them equal. Install Claude Code and codex-cli. Add the `devcontainer.metadata` label; there is one tag (D19). Build linux/amd64 and linux/arm64 with the native-runner pipeline from T15 (D24, D33).
- Check: CI builds both platforms; `docker run --rm <image> <tool> --version` for every tool on both platforms (run in CI, not in the workspace); image size is recorded in the PR; Renovate dry run picks up the new annotations; no `sandbox-*` file is changed.
- Rollback: delete the app directory; nothing consumes it yet.

## T3. Publish and pin the image

- Status: todo. Blocked by: T2.
- Do: after merge in `containers`, record the published tag and the digest of the multi-arch manifest. Add the image reference (digest-pinned) to the PRs of T5 and T10 only.
- Check: `docker buildx imagetools inspect <image>` shows both platforms; the digest in the consuming PR matches.

## T4. Create the BWS project and the workspace token (owner action)

- Status: todo. Blocked by: nothing.
- Do (owner, in Bitwarden; the agent never reads values): create a project for the dev workspace type; add `GITHUB_TOKEN`, `TERRAFORM_TOKEN` and the SSH signing key (D32, D30; `SOPS_AGE_KEY` is not included). Register the matching public key on GitHub as a signing key. `BWS_ACCESS_TOKEN` is the machine token you issue below and is delivered by the Kubernetes Secret, not stored in the project. Cluster access is **not** stored here (D4). Create a machine account with read-only access to that project only, and issue one access token. A Hermes sandbox type later gets its own, smaller project (D11).
- Agent part: write the secret **names** (no values, no identifiers) into `docs/` and into the T5 template comments; add an `ExternalSecret` (store `bitwarden`) that creates the Kubernetes Secret with `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` (D31), which the pod reads as environment variables. Make the Secret name a template parameter so other workspace types reuse the pattern. The Bitwarden identifiers stay out of the repository: use the same mechanism other ExternalSecrets in `cluster/apps/ai/coder/templates/externalsecret.yaml` use for references.
- Check: `kubectl kustomize` or `helm template` for `cluster/apps/ai/coder` renders the ExternalSecret with no identifier or value in the output committed to git; gitleaks passes. Live: the Secret exists after sync (consent-gated sync).

```sh consent-gated
# After merge, owner decides when ArgoCD syncs the coder app; do not run without fresh consent.
argocd app sync coder
```

## T5. New Coder template and workspace

- Status: todo. Blocked by: T3, T4, T13.
- Do: add a new template in a new directory under `cluster/apps/ai/coder/workspace-template/` (D16; the `sandbox` template is not changed). Requirements:
  - image from T3 (digest-pinned); `arch` follows the image platform;
  - runs as `vscode`, non-root, no sudo, `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault`;
  - memory request = limit = 3Gi; CPU limit 2; CPU request from T9 (start at 500m);
  - PVC default 20Gi (parameter), mounted at `/workspaces` (D14, D18);
  - SSH through the Coder agent only (D15): no sshd, no LoadBalancer Service, no `authorized_key` parameter;
  - runs in the namespace `dev-workspace` (D28), with a narrow Role for the Coder provisioner there added to `templates/rbac-services.yaml` (no access to `serviceaccounts.talos.dev`);
  - `emptyDir` with `medium: Memory` for the SSH signing key (loaded into an in-pod ssh-agent, D32), sized small (for example 64Mi) and counted in the 3Gi limit;
  - the Talos ServiceAccount Secret from T13 mounted as a directory (no `subPath`, so the 6-hour certificate rotation reaches the pod) at `/var/run/secrets/talos.dev`, with `TALOSCONFIG=/var/run/secrets/talos.dev/config` (never a copy, never the repository tree); the config has no nodes list, so check in T6 which `task talos:*` targets and skills need `--nodes`; kubectl uses the pod's Kubernetes ServiceAccount (D26), so no `~/.kube/config` is created;
  - the BWS token and project reference read with `secret_key_ref` from the Secret named by a template parameter; no secret value in Terraform variables or state;
  - VolSync backup as in the current template (tool logins are accepted in the backup, D20);
  - a NetworkPolicy with ingress deny-all (D22); egress open.
- Check (local): `terraform fmt -check`, `terraform validate` in the template directory; `helm template` for the app; `bash .agents/tests/run.sh`; `task lint:all` read, not assumed.
- Check (live, consent-gated): push the template and create the workspace.

```sh consent-gated
# Pushing a template and creating a workspace are RUNTIME_MUTATION; ask first.
coder templates push <template-name> --directory cluster/apps/ai/coder/workspace-template/<dir> --yes
coder create <workspace-name> --template <template-name>
```

- Rollback: `coder delete <workspace-name>` is DESTRUCTIVE for its volume; first confirm a VolSync snapshot exists. Deleting the template does not touch `sandbox`.

## T6. Spike: repository bootstrap

- Status: todo. Blocked by: nothing (user `vscode`, path `/workspaces/<repo>`, repo list in dotfiles: D13, D14, D21).
- Do: decide how the workspace runs each repository's setup. Option A: the image bootstrap calls the `onCreateCommand`, `updateContentCommand` and `postStartCommand` scripts named in the repository's `devcontainer.json` (note that file may contain comments, so parse it with a JSONC-aware tool). Option B: each repository gets a tool-agnostic `setup` entry point that `devcontainer.json` also calls. Try A on a copy of `home-ops` in a scratch container started from the T2 image and record what breaks (Codespaces-only branches, `NET_ADMIN`, hard-coded `/workspaces/home-ops` in `postStartCommand.sh`, `task` targets that expect the VPN).
- Output: `.plans/remote-dev-workspace/bootstrap.md` with the chosen option, the list of script changes, and the generalised memory-symlink loop for `.claude/memory`.
- Check: the spike runs to the end on both amd64 and arm64 if arm64 is available; no step needs the cluster or secrets.

## T7. First start and login

- Status: todo. Blocked by: T5, T6.
- Do (owner at the keyboard): connect with VS Code through the Coder extension, run `claude` and `codex` interactive login (D20), clone the repositories, check SSH signing with a throwaway commit in a scratch repository (not on `main` of a real repo).
- Check: `git log --show-signature -1` verifies in the scratch repository; `claude` and `codex` start; `kubectl get nodes` and `talosctl get members` work and `kubectl get secrets` is denied (READ-class checks); `argocd login --sso` completes through VS Code port forwarding and `argocd app list` works; `env` is **not** printed (SECRET_ACCESS).

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
- Do: one PR per repository that has a `.devcontainer` (home-ops, containers, github-workflows, homelab-portal, argocd-secret-replacer, and the two old ones willow-inference-server-dockerized and home-assistant if still wanted; claude-plugins has none), `home-ops` first. Change `devcontainer.json` to `"image": "<new image>@<digest>"`, drop the `features` block and the local build, keep `runArgs`, `secrets` and lifecycle commands. For `home-ops` also remove `.github/.devcontainer/`, `.github/workflows/devcontainer-publish.yaml` and the Renovate rules that referenced them, and update `docs/`, `AGENTS.md` and the `dev-workflow` skill if they mention the old image. Keep the old image digest in the PR description as the rollback.
- Check: devcontainer rebuilds locally and the three lifecycle commands succeed; `task lint:all`, `bash .agents/tests/run.sh`; `.agents/bin/check-plans`.

## T11. Documentation and skills

- Status: todo. Blocked by: T5.
- Do (docs, after the work they describe): document the workspace in `cluster/apps/ai/coder/README.md` (the table currently lists only `devops`), add a docs page for the remote workspace (what it is, how to connect, secret names, break-glass using the local devcontainer), update `.agents/skills/coder-workspace-template-deploy/SKILL.md` for the new template, run `.agents/bin/sync-skills`, and update the Coder row in `docs/` if one exists. Add or update memory files in `.claude/memory/` only for non-obvious findings, and commit them on the branch.
- Check: `task lint:all` read; `bash .agents/tests/run.sh`; links resolve.

## T12. Spike: Talos ServiceAccount mechanics

- Status: done 2026-11-02 (findings in [talos-access.md](talos-access.md); open items listed there are live checks for T7).
- Do: find out what the Talos docs do not say, using read-only means first. (1) Read the existing `tuppr` and `talos-backup` wiring in the repository (`cluster/apps/system/talos-backup/`, the tuppr app) to see how the `talos.dev` `ServiceAccount` is declared and how the generated Secret is mounted and read. (2) Read the Talos source or release notes for v1.14 for: the Secret keys, credential lifetime and rotation, how `allowedRoles` and `allowedKubernetesNamespaces` interact, and which `talosctl` commands `os:reader` allows (kubectl access no longer depends on Talos, D26). Do not print Secret values; key names only, and only if a read of them is permitted.
- Output: `.plans/remote-dev-workspace/talos-access.md` with the findings, the exact YAML for a `ServiceAccount` with `os:reader`, how the pod gets `TALOSCONFIG`, and the list of `talosctl` read commands that work with `os:reader`.
- Check: each claim cites the file or documentation page; anything not confirmed is marked unverified.

## T13. Talos machine config: allow the workspace namespace with `os:reader`

- Status: todo. Blocked by: nothing (T12 done). Use the reference YAML in [talos-access.md](talos-access.md); the Secret name equals the resource name, and the namespace must also be added to `allowedKubernetesNamespaces`.
- Do: edit `provision/talos/patches/controlplane/40-talos-api-access.yaml` to add `os:reader` to `allowedRoles` and the namespace `dev-workspace` to `allowedKubernetesNamespaces`; update its header comment with the new escalation note (the namespace can request `os:admin` because that role is in the cluster-wide list). Update the exact-match assertion in `provision/talos/tests/test_render.sh` (it asserts the roles and namespaces lists) and regenerate the generated docs (`docs/src/talos/config-map.md`) with the repository tooling. Add, as a new app or templates under `cluster/apps/` (use the `add-app` skill): the `dev-workspace` namespace with Pod Security `baseline`; the Talos `ServiceAccount` with `os:reader`; the Kubernetes ServiceAccount, a ClusterRole granting `get`, `list`, `watch` on all resources including CRDs and excluding Secrets, and its ClusterRoleBinding (D26, D27); and the RBAC that prevents anything but GitOps from creating `serviceaccounts.talos.dev` in that namespace. Verify the ClusterRole with `kubectl auth can-i --list --as=system:serviceaccount:dev-workspace:<name>` (READ-class) and confirm `get secrets` is denied.
- Check (local): `bash provision/talos/tests/test_render.sh`, `bash .agents/tests/run.sh`, `task lint:all` read, `.agents/bin/check-plans`.
- Check (live, consent-gated): the change is a rolling machine config apply on mc1 to mc3 and is a separate PR with its own impact statement and rollback (revert the patch and apply again).

```sh consent-gated
# RUNTIME_MUTATION: apply the changed control-plane config; ask first; load the talos-config-editing skill for the procedure before running.
task talos:apply-config
```

## T14. Make the BWS project in `.envrc` configurable

- Status: todo. Blocked by: nothing (can land before the workspace exists; the local result must be identical).
- Do: in `.envrc` change the line that runs `bws secret list <project> -o env` so the project comes from `BWS_PROJECT_ID`, defaulting to the project the file uses today (D31). Keep the exported variable set unchanged when `BWS_PROJECT_ID` is unset. Only `home-ops` has an `.envrc` (checked 2026-11-02, see evidence.md), so this is a single PR. Do not write the project identifier into plans, docs or PR text; reference it by name only.
- Check: with `BWS_PROJECT_ID` unset, `direnv` loads the same variables as before (compare variable **names** before and after, never values); with it set to another project, the other project is read; `shellcheck` on `.envrc` as the repository does; `task lint:all` read; `bash .agents/tests/run.sh`.

## T15. `containers`: native per-platform builds and a merged manifest

- Status: todo. Blocked by: nothing (D33). Must land before T2.
- Do: in `mmalyska/containers`, change `.github/workflows/action-image-build.yaml` so a channel with several platforms builds each platform on its native runner (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64), runs the Goss test on each platform, pushes per-platform images and publishes a merged multi-arch manifest under the existing `:rolling` and `:<version>` tags. Today a mixed channel builds on `ubuntu-latest` with QEMU and tests amd64 only (evidence.md). Keep single-platform channels and the metadata schema (`metadata.rules.cue`) unchanged so every existing app keeps building. Update `CLAUDE.md` and the README of `containers`.
- Check: a PR build of an existing multi-platform app (`argocd-secret-replacer` or `s3-bucket-cleaner`, both amd64 + arm64) builds and tests both platforms and a dry run shows the merged manifest; amd64-only apps (`nextcloud`, `vintagestory`, the `sandbox-*`) build exactly as before; no pushed tag changes name. Report each check as PASS, FAIL or NOT RUN.
- Rollback: revert the workflow change; images already published keep working.
- Consent: a merge in `containers` rebuilds and pushes images (GITOPS-style side effect on every image); ask before merging.

## T16. `dotfiles`: workspace-only changes

- Status: todo. Blocked by: T6 (the bootstrap spike decides the exact shape).
- Do: in `mmalyska/dotfiles` (evidence.md has the layout): (1) let a host override `user.signingkey` for the workspace SSH signing key (D32) without changing the owner's own key elsewhere, for example a chezmoi data flag such as `is_remote_workspace` read in `home/dot_gitconfig.tmpl`; (2) add the list of repositories to clone as static data in `home/.chezmoidata/`, plus a `run_onchange` script under `.chezmoiscripts/` that clones missing repositories to `/workspaces/<repo>` only when the workspace flag is set, so the local devcontainer and Codespaces are unchanged (D21); (3) document or provide the non-interactive way to run `chezmoi init --apply` (the config template prompts for email, name, work machine and AI profile; use the prompt flags or a pre-written config). Follow the dotfiles repository's own plan and test conventions (`docs/plans`, `tests/ai`).
- Check: the dotfiles test suite (`tests/ai`) passes; chezmoi applied with the flag unset produces byte-identical output to before for the existing fixtures; with the flag set the signing key and repository list appear.
- Consent: a merge changes the dotfiles every machine of the owner applies; ask before merging.
