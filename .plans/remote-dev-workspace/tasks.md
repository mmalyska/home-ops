<!-- markdownlint-disable MD013 -->

# Tasks

Each task can be executed without reading `plan.md`. A task that depends on an open question (Qn) is blocked until the owner answers it; the question text is in `plan.md`. Do all repository work in a linked worktree; run `.agents/bin/worktree-preflight` before the first write. Every command that changes cluster or external state needs fresh consent from the owner in the current session.

Revised 2026-11-03 (image 1.0.0 adopted, storage design D40 to D47): T2 and T3 are done, T22 and T23 are new, T21 was dropped, and T5, T7, T8, T9, T17 and T19 changed. Task text refers to decisions in `plan.md`.

Common context: the goal is one always-on Coder workspace, on the Talos cluster, for several repositories of the owner, built from one shared multi-arch image published from `mmalyska/containers`. Secrets come from one dedicated BWS project per workspace type. `sandbox-*` images and the `devops` workspace belong to Hermes and must not be changed.

Dependency order (template preparation is separate from creating the first workspace):

```text
T15, T1, T2, T3 (done: image 1.0.0 published) ---> T22, T23 (hardening and devcontainer tests)
T22 ----------------------------------------------> T5 (template, no workspace)
T13 (Talos config) -------------------------------> T5
T19 (namespace, RBAC, PVC pairs, backups) --------> T5
T4 (BWS project, owner) --------------------------> T5
T2 -> T6 -> T16 ; T14 ; T17 ----------------------> T7 (first workspace + login) -> T8 -> T9
T17 + T8 + T3 -----------------------------> T10 (migrate devcontainers)
T4 -> T18 (ArgoCD account) -> ArgoCD checks in T7 and T8
```

## T1. Inventory the tools the new image needs

- Status: done (`tools.md`, PR #6061; the six open questions were decided on 2026-11-02, see its Decisions section). Superseded in method on 2026-11-03: the tool list now lives in the image's `mise.toml` (D46) and `tools.md` records why each tool is there. Blocked by: nothing.
- Do: list every tool the home-ops devcontainer and `sandbox-devops` provide, and every tool the home-ops scripts, `Taskfile`, pre-commit config and `.envrc` call. The real tool list of the local devcontainer is `.github/.devcontainer/local-features/common/Brewfile` (direnv, egctl, gitleaks, go-task, helm, ipcalc, jq, kubectl, kustomize, prettier, stern, terraform, yamllint, yq, argocd, kubelogin, k9s, pre-commit, mkdocs, gh, helmfile, chezmoi, node as of 2026-11-02) plus the other local features. Read `.github/.devcontainer/local-features/*/install*.sh`, that Brewfile, `.devcontainer/scripts/*.sh`, `.taskfiles/`, `.pre-commit-config.yaml`, `.envrc` and `containers/apps/sandbox-devops/Dockerfile`. Then do the same for `claude-plugins`, `containers` and `argocd-secret-replacer` (read only, via `gh api` or a clone).
- Output: `.plans/remote-dev-workspace/tools.md` with a table: tool, source today (feature, Dockerfile, Brewfile), version pin today, used by which repository, upstream publishes checksum (yes/no), has arm64 build (yes/no), Renovate datasource, install path in the image (must be outside `/home/vscode`, D34).
- Check: every tool called by a script or Taskfile target appears in the table; no secret value or private domain appears in the file.

## T2. Build the `dev-workstation` image in `containers`

- Status: done 2026-11-03 (`containers` PR #772, merge commit `b3804aa`; amd64 and arm64, Build and Goss passed on both; not yet run on this cluster). The text below is the original brief, kept for history; the delivered design is D46: one `mise.toml`, image tools read-only in `/opt/mise`, no lock files, no `home-ops` dependency, `talosctl` and `cilium` follow upstream. Blocked by: T1, T15.
- Do: in `mmalyska/containers` add `apps/dev-workstation/` with `Dockerfile`, `README.md`, `metadata.json` and `ci/`, copying the layout and metadata rules of `apps/sandbox-devops`. Pinned Ubuntu LTS digest. Non-root user `vscode`, UID 1000, no sudo (D13, D17). No Homebrew (D12): install the tools from `tools.md` as pinned release downloads, resolving the architecture instead of hard-coding amd64, with Renovate annotations and checksums where upstream publishes them. **Install every tool under `/usr/local` or another system path, never under `/home/vscode`**: the workspace mounts a volume over the home directory and hides whatever the image put there (D34); put defaults in `/etc/skel`-style seed files instead. The `talosctl` version must equal `TALOS_VERSION` in `.taskfiles/talos/Taskfile.yaml`, because `task talos:install` (which uses `sudo`) is skipped only on an exact match; add a Renovate rule or a CI check that keeps them equal. Install Claude Code and codex-cli. Add the `devcontainer.metadata` label; there is one tag (D19). Build linux/amd64 and linux/arm64 with the native-runner pipeline from T15 (D24, D33).
- Check: CI builds both platforms; `docker run --rm <image> <tool> --version` for every tool on both platforms (run in CI, not in the workspace); no file of the image is under `/home/vscode` except the seed files; image size is recorded in the PR; Renovate dry run picks up the new annotations; no `sandbox-*` file is changed.
- Rollback: delete the app directory; nothing consumes it yet.

## T3. Publish and pin the image

- Status: done for the image (`ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:76a0c4f0359029fa9ce976a39b87d7770bb332c56336e7ea673d753a0dc30f98`, D46); the remaining step is adding the digest to the T5 and T10 PRs and re-checking it with `docker buildx imagetools inspect` before each. Blocked by: T2.
- Do: after merge in `containers`, record the published tag and the digest of the multi-arch manifest. Add the image reference (digest-pinned) to the PRs of T5 and T10 only.
- Check: `docker buildx imagetools inspect <image>` shows both platforms; the digest in the consuming PR matches.

## T4. Create the BWS project and the workspace token (owner action)

- Status: owner part done 2026-11-03 for the BWS-token and project references (the two cluster-project secrets exist and are referenced in the T19 app); the ArgoCD token waits for T18. Blocked by: nothing for the base set; the ArgoCD token waits for T18.
- Do (owner, in Bitwarden; the agent never reads values): create a project for the dev workspace type; add `GITHUB_TOKEN`, `TERRAFORM_TOKEN` and the SSH signing key (D32, D30; `SOPS_AGE_KEY` is not included). When T18 is done, also add the ArgoCD account token and the ArgoCD server address (the address contains the private domain, so it is delivered as a secret value, not written into the repository). Register the matching public key on GitHub as a signing key. `BWS_ACCESS_TOKEN` is the machine token you issue below and is delivered by the Kubernetes Secret, not stored in the project. Cluster access is **not** stored here (D4). Create a machine account with read-only access to that project only, and issue one access token. A Hermes sandbox type later gets its own, smaller project (D11).
- Agent part: write the secret **names** (no values, no identifiers) into `docs/` and into the T5 template comments; add an `ExternalSecret` (store `bitwarden`) in `dev-workspace`, owned by GitOps (D35, in the T19 app), that creates the Kubernetes Secret with `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` (D31), which the pod reads as environment variables. Make the Secret name a template parameter so other workspace types reuse the pattern. The Bitwarden identifiers stay out of plans, docs and PR text; manifests use the same reference mechanism other ExternalSecrets in the repository use.
- Check: `kubectl kustomize` or `helm template` renders the ExternalSecret with no identifier or value in anything but the manifest reference fields; gitleaks passes. Live: the Secret exists after sync (consent-gated sync).

```sh consent-gated
# After merge, owner decides when ArgoCD syncs the app that holds the namespace; do not run without fresh consent.
argocd app sync <app-name>
```

## T5. New Coder template (prepare only, no workspace)

- Status: todo. Blocked by: T3, T4, T13, T19, T22. This task never creates a workspace; that is T7.
- Do: add a new template in a new directory under `cluster/apps/ai/coder/workspace-template/` (D16; the `sandbox` template is not changed). Requirements:
  - image from T3 (digest-pinned, never the bare tag); `arch` follows the image platform; PATH and `mise` behaviour as in D46 (scripts that need a repository's tool versions use `mise exec`);
  - runs as `vscode`, non-root, no sudo, `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault`, `fsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`, and `readOnlyRootFilesystem: true` if T22 shows it works (D43);
  - memory request = limit = 3Gi; CPU limit 2; CPU request from T9 (start at 500m); `ephemeral-storage` request and limit above the two `sizeLimit`s plus margin (D43);
  - the two PVCs of the workspace (home and source, created and owned by GitOps in T19, D39, D41) mounted by name, without `subPath`: home at `/home/vscode` and source at `/workspaces`. The template only references them; it creates neither and has no size parameter. `/cache` and `/tmp` are `emptyDir`s with `sizeLimit` (about 20 Gi and 5 Gi). At workspace start the step `cp -rn /etc/skel/. "$HOME"/` fills an empty home (D45); nothing else is seeded and no ownership step is needed;
  - SSH through the Coder agent only (D15): no sshd, no LoadBalancer Service, no `authorized_key` parameter;
  - runs in the namespace `dev-workspace` (D28). The provisioner's Role there is created by T19 and allows only the workload objects the template needs (D35): it manages Deployments and has no PVC permission; the template creates no `ExternalSecret`, `ReplicationSource`, RBAC object or `serviceaccounts.talos.dev`;
  - `emptyDir` with `medium: Memory` for the SSH signing key (loaded into an in-pod ssh-agent, D32), sized small (for example 64Mi) and counted in the 3Gi limit;
  - the Talos ServiceAccount Secret from T19 mounted as a directory (no `subPath`, so the 6-hour certificate rotation reaches the pod) at `/var/run/secrets/talos.dev`, with `TALOSCONFIG=/var/run/secrets/talos.dev/config` (never a copy, never the repository tree); the config has no nodes list, so check in T6 which `task talos:*` targets and skills need `--nodes`; kubectl uses the pod's Kubernetes ServiceAccount (D26), so no `~/.kube/config` is created;
  - the BWS token and project reference read with `secret_key_ref` from the Secret named by a template parameter; no secret value in Terraform variables or state;
  - tool logins (Claude, Codex) live on the home volume and are backed up (D20); every other credential is delivered by environment or memory-backed volume and must never be written to the volume (checked in T8).
- Check (local): `terraform fmt -check`, `terraform validate` in the template directory; `helm template` for the app; `bash .agents/tests/run.sh`; `task lint:all` read, not assumed.
- Check (live, consent-gated): pushing the template makes it available but starts nothing.

```sh consent-gated
# Pushing a template is RUNTIME_MUTATION; ask first. It does not create a workspace.
coder templates push <template-name> --directory cluster/apps/ai/coder/workspace-template/<dir> --yes
```

- Rollback: delete the template version in Coder; the `sandbox` template is untouched.

## T6. Spike: repository bootstrap

- Status: done 2026-11-03 for amd64 (PR #6074; `bootstrap.md` holds the analysis and the scratch-container run; arm64 skipped by the owner). Blocked by: nothing.
- Do: decide how the workspace runs each repository's setup. Option A: the image bootstrap calls the `onCreateCommand`, `updateContentCommand` and `postStartCommand` scripts named in the repository's `devcontainer.json` (note that file may contain comments, so parse it with a JSONC-aware tool). Option B: each repository gets a tool-agnostic `setup` entry point that `devcontainer.json` also calls. Try A on a copy of `home-ops` in a scratch container started from the T2 image and record what breaks (Codespaces-only branches, `NET_ADMIN`, hard-coded `/workspaces/home-ops` in `postStartCommand.sh`, `task` targets that expect the VPN, `task init` reading the Brewfile, the Homebrew path to `chezmoi`, `sudo` calls, the empty-home seed from D34).
- Output: `.plans/remote-dev-workspace/bootstrap.md` with the chosen option, the list of script changes (which become T17), and the generalised memory-symlink loop for `.claude/memory`.
- Check: the spike runs to the end on both amd64 and arm64 if arm64 is available; no step needs the cluster or secrets.

## T7. Create the first workspace and log in

- Status: todo. Blocked by: T5, T6, T14, T16, T17. The ArgoCD checks also need T18.
- Do (owner at the keyboard; creating a workspace is RUNTIME_MUTATION, ask first): create the workspace from the T5 template, connect with VS Code through the Coder extension, run `claude` and `codex` interactive login (D20), let the bootstrap clone the repositories, check SSH signing with a throwaway commit in a scratch repository (not on `main` of a real repo).

```sh consent-gated
# Creating the workspace is RUNTIME_MUTATION; ask first.
coder create <workspace-name> --template <template-name>
```

- Check:
  - VS Code connects through the Coder agent without sshd (`coder config-ssh`);
  - persistence: write a marker file under `/home/vscode` and one under `/workspaces`, and one under `/cache`, restart the workspace (consent-gated), and confirm the first two survive with owner `vscode`, that the Claude and Codex logins and a tool added with `mise use -g` survive, and that `/cache` is empty again (accepted, D40);
  - `git log --show-signature -1` verifies in the scratch repository; `claude` and `codex` start;
  - `kubectl get nodes` works through the in-cluster configuration with no kubeconfig file (if the `.envrc` `KUBECONFIG` export gets in the way, fix it in T14);
  - `talosctl --nodes <control-plane ip> version` and `talosctl get` on a non-sensitive type work, a sensitive type and `talosctl kubeconfig` are denied, and the pod reaches `talos.default` (record which `talosctl get` types are sensitive);
  - authorization is checked with `kubectl auth can-i`, never by attempting a forbidden read: the negative list from T19 all answers `no` and the positive list answers `yes`;
  - ArgoCD (after T18), in the order T18 defines: with the allowlist empty, read works and every sync, refresh and prune check answers `no`; a `yes` is tested only after an app has been added to the allowlist (a disposable test application first), and then only for that app;
  - `env` is **not** printed and no credential file is read (SECRET_ACCESS).

## T8. Verify safety controls in the workspace

- Status: todo. Blocked by: T7.
- Do: confirm in the workspace that the repository's Claude permission file and `AGENTS.md` consent rules apply (open `home-ops`, check that `.claude/settings.json` is read and a denied command is denied, including the ArgoCD sync and prune ask rules), and that the worktree preflight returns 0 in a worktree and 3 in the primary checkout. Then check what is on the backed-up volume, by file name only (`find`, never print contents):
  - accepted on the volume (D20): the Claude and Codex login files;
  - must stay off the volume: the SSH signing key, the Talos credential, the BWS access token and project reference, `GITHUB_TOKEN`, `TERRAFORM_TOKEN`, the ArgoCD token, and any file a tool writes when it persists a login (for example `.git-credentials`, the `gh` hosts file, Terraform CLI credentials, an `~/.kube/config`); T6 supplies the final list of file names.
- Do (restore test, consent-gated): restore the latest snapshot of each of the two PVCs (home, every 6 h; source, daily) into a scratch volume, list file names, confirm the accepted login files are present in the home restore, the must-not-persist names are absent, and `/home/vscode` and `/workspaces` content and ownership are intact. Neither restore targets the live claim (`restore.enabled: false` on the live release). Delete the scratch volumes afterwards (DESTRUCTIVE for those scratch volumes only; name them first).
- Check: report each as PASS, FAIL or NOT RUN with the reason.

## T9. Measure and adjust resources

- Status: todo. Blocked by: T7. Run for two weeks after first use.
- Do: query Prometheus (use the `prometheus-historical-queries` skill) for the workspace pod: max and p95 of `container_memory_working_set_bytes`, CPU usage p95, throttling, restarts and OOM kills; and the usage of both PVCs, of `/cache` and `/tmp` against their `sizeLimit`s (the pod's ephemeral-storage usage) and any eviction. Check node headroom on the node hosting the pod.
- Output: a table in `plan.md` Status with measured values and the proposed new requests and limits; ask the owner before changing them.
- Check: numbers come from queries, not estimates; the memory limit stays above the observed peak by a stated margin.

## T10. Move devcontainers to the new image

- Status: todo. Blocked by: T3, T6, T8, T17.
- Do: one PR per repository that has a `.devcontainer` (home-ops, containers, github-workflows, homelab-portal, argocd-secret-replacer (deferred, see below), and the two old ones willow-inference-server-dockerized and home-assistant if still wanted; claude-plugins has none), `home-ops` first. Change `devcontainer.json` to `"image": "<new image>@<digest>"`, drop the `features` block and the local build, keep `runArgs`, `secrets` and lifecycle commands. For `home-ops` also remove `.github/.devcontainer/` (this deletes the Brewfile that `task init` reads, which is why T17 comes first), `.github/workflows/devcontainer-publish.yaml` and the Renovate rules that referenced them, and update `docs/`, `AGENTS.md` and the `dev-workflow` skill if they mention the old image. Keep the old image digest in the PR description as the rollback. `argocd-secret-replacer` is not moved by this task: its devcontainer provides the .NET SDK and `sops`, which the shared image excludes (T1 decisions 1 and 3), so replacing the image would remove both. Moving it has a prerequisite: either the shared image gains the .NET SDK and `sops` (a change to the T1 decisions) or the repository keeps its own devcontainer. Until one of those is decided, leave its `.devcontainer` as it is.
- Check: a fresh local devcontainer rebuild succeeds and the three lifecycle commands succeed, **and** a fresh Coder workspace start succeeds with the same scripts; `task init` works without `brew`; `task lint:all`, `bash .agents/tests/run.sh`; `.agents/bin/check-plans`.

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

- Status: in review (PR open: patch, render test and config map done and checked locally; the live apply is not done and is consent-gated). Blocked by: nothing (T12 done). Use the reference YAML in [talos-access.md](talos-access.md); the Secret name equals the resource name.
- Do: edit `provision/talos/patches/controlplane/40-talos-api-access.yaml` to add `os:reader` to `allowedRoles` and the namespace `dev-workspace` to `allowedKubernetesNamespaces`; update its header comment with the new escalation note (the namespace can request `os:admin` because that role is in the cluster-wide list). Update the exact-match assertion in `provision/talos/tests/test_render.sh` (it asserts the roles and namespaces lists) and regenerate the generated docs (`docs/src/talos/config-map.md`) with the repository tooling. This is a separate PR from T19.
- Check (local): `bash provision/talos/tests/test_render.sh`, `bash .agents/tests/run.sh`, `task lint:all` read, `.agents/bin/check-plans`.
- Check (live, consent-gated): the change is a rolling machine config apply on mc1 to mc3 with its own impact statement and rollback (revert the patch and apply again).

```sh consent-gated
# RUNTIME_MUTATION: apply the changed control-plane config; ask first; load the talos-config-editing skill for the procedure before running.
task talos:apply-config
```

## T14. Make the BWS project in `.envrc` configurable

- Status: done (PR #6060). Blocked by: nothing (can land before the workspace exists; the local result must be identical).
- Do: in `.envrc` change the line that runs `bws secret list <project> -o env` so the project comes from `BWS_PROJECT_ID`, defaulting to the project the file uses today (D31). Keep the exported variable set unchanged when `BWS_PROJECT_ID` is unset. Only `home-ops` has an `.envrc` (checked 2026-11-02, see evidence.md), so this is a single PR. Do not write the project identifier into plans, docs or PR text; reference it by name only.
- Check: with `BWS_PROJECT_ID` unset, `direnv` loads the same variables as before (compare variable **names** before and after, never values); with it set to another project, the other project is read; `shellcheck` on `.envrc` as the repository does; `task lint:all` read; `bash .agents/tests/run.sh`.

## T15. `containers`: native per-platform builds and a merged manifest

- Status: done (`mmalyska/containers` PR #760, merged; controlled push of `s3-bucket-cleaner` verified: native builds, Goss per platform, merged manifest, both tags on one digest). Not run in a real push: one platform failing, and a single-platform push with the new workflow (first scheduled rebuild of an amd64-only app will show it). Blocked by: nothing (D33). Must land before T2.
- Do: in `mmalyska/containers`, change `.github/workflows/action-image-build.yaml` so a channel with several platforms builds each platform on its native runner (`ubuntu-latest` for amd64, `ubuntu-24.04-arm` for arm64), runs the Goss test on each platform, pushes per-platform images and publishes a merged multi-arch manifest under the existing `:rolling` and `:<version>` tags. Today a mixed channel builds on `ubuntu-latest` with QEMU and tests amd64 only (evidence.md). Keep single-platform channels and the metadata schema (`metadata.rules.cue`) unchanged so every existing app keeps building. Update `CLAUDE.md` and the README of `containers`.
- Check: a PR build of an existing multi-platform app (`argocd-secret-replacer` or `s3-bucket-cleaner`, both amd64 + arm64) builds and tests both platforms and a dry run shows the merged manifest; amd64-only apps (`nextcloud`, `vintagestory`, the `sandbox-*`) build exactly as before; no pushed tag changes name. Report each check as PASS, FAIL or NOT RUN.
- Rollback: revert the workflow change; images already published keep working.
- Consent: a merge in `containers` rebuilds and pushes images (GITOPS-style side effect on every image); ask before merging.

## T16. `dotfiles`: workspace-only changes

- Status: todo. Blocked by: nothing (T6 done). Inputs from the T6 run in `bootstrap.md` notes 18 and 19: the dotfiles must take their chezmoi answers without a TTY, and the owner decides whether the workspace gets the peon-ping and plugin installs.
- Do: in `mmalyska/dotfiles` (evidence.md has the layout): (1) let a host override `user.signingkey` for the workspace SSH signing key (D32) without changing the owner's own key elsewhere, for example a chezmoi data flag such as `is_remote_workspace` read in `home/dot_gitconfig.tmpl`; (2) add the list of repositories to clone as static data in `home/.chezmoidata/`, plus a `run_onchange` script under `.chezmoiscripts/` that clones missing repositories to `/workspaces/<repo>` only when the workspace flag is set, so the local devcontainer and Codespaces are unchanged (D21); (3) document or provide the non-interactive way to run `chezmoi init --apply` (the config template prompts for email, name, work machine and AI profile; use the prompt flags or a pre-written config). Follow the dotfiles repository's own plan and test conventions (`docs/plans`, `tests/ai`).
- Check: the dotfiles test suite (`tests/ai`) passes; chezmoi applied with the flag unset produces byte-identical output to before for the existing fixtures; with the flag set the signing key and repository list appear.
- Consent: a merge changes the dotfiles every machine of the owner applies; ask before merging.

## T17. Rework the home-ops bootstrap so both consumers work (prerequisite to T7 and T10)

- Status: done 2026-11-03 (PR #6074; remaining checks: a fresh local devcontainer start with the current image, which T23 covers, and arm64, skipped by the owner). Blocked by: nothing.
- Why: the local devcontainer and the Coder workspace must run the same lifecycle commands. Today they depend on things the new image drops: `task init` runs `brew bundle` against `.github/.devcontainer/local-features/common/Brewfile` (and the Taskfile precondition checks `command -v brew`), `.devcontainer/scripts/onCreateCommand.sh` calls `chezmoi` by its Homebrew path, several lines use `sudo` (including `sudo git config --global`, which writes root's configuration, not the user's), `task talos:install` uses `sudo`, and `postStartCommand.sh` hard-codes `/workspaces/home-ops`. Deleting `.github/.devcontainer/` (T10) would break all of them.
- Do: in `home-ops`: make `task init` and its preconditions check that the tools are present (the image provides them) instead of installing them with Homebrew; call `chezmoi` through `PATH`; replace `sudo git config --global` with the unprivileged form; make `task talos:install` and `task cilium:install` never call `sudo` when the tool already exists (D47): the image's `talosctl` and `cilium` follow upstream, so their versions will differ from `TALOS_VERSION` and `CILIUM_VERSION` after the next Renovate bump (1.14.5 and 0.20.2 are already proposed against pins of 1.14.4 and 0.20.1). Concretely: when `sudo` is not available, or the tool is present, print a one-line warning with the two versions and skip instead of failing; keep the real install for a machine that has `sudo` and no tool; change the `talos:generate` precondition (`.taskfiles/talos/Taskfile.yaml`, the `talosctl does not match` check) so a different client version warns instead of pointing at `task talos:install`, while keeping a hard failure where an exact match is needed for correctness (`talos:upgrade` and config generation); update `docs/src/k8s/tuppr.md`, which tells the reader to run `task talos:install`; do not reintroduce any dependency from `containers` on this repository; make the memory-symlink loop use the current repository path; keep Codespaces-only branches working; keep a documented way to run the tool install for a machine without the image if still wanted. Land the change while the old image still works, so it can be verified on the current local devcontainer first.
- Check: a fresh local devcontainer start with the current image passes the three lifecycle commands; the same scripts pass in a scratch container from the T2 image; `task lint:all` read; `bash .agents/tests/run.sh`; `.agents/bin/check-plans`. Report each as PASS, FAIL or NOT RUN.

## T18. ArgoCD account for the workspace

- Status: todo. Blocked by: T4 for storing the token (Q23 is answered, D38).
- Do: in `cluster/apps/core/argocd/patches/` add a dedicated local account for the workspace (API key only, no password login) and its policy in `argocd-rbac-cm.yaml`: read, refresh, sync and prune on a named allowlist of apps that starts empty (D38; the owner adds app names by reviewed PR), nothing else: no delete, no create or update of applications, no repository, cluster, project or account changes, no exec, and **no `override`**. In `argocd-cm` set `application.sync.requireOverridePrivilegeForRevisionSync: "true"` (documented since ArgoCD v3.2, deployed v3.5.6; confirm against the deployed version's docs before merging) so a sync cannot select an arbitrary revision such as an unmerged branch or an older commit. For each app added to the allowlist, put `argocd.argoproj.io/sync-options: Prune=false` on its PVCs and stateful owners (it stops ArgoCD pruning that object, not destructive updates or deletion by another controller). Confirm which ArgoCD actions refresh and prune need before writing the policy. The owner generates the token in ArgoCD and stores it in the dev BWS project (T4); the agent never handles it. SSO is not used from the workspace because the owner's identity and the `ArgoCDAdmins` group map to `role:admin` in that file.
- Check (local): `kubectl kustomize cluster/apps/core/argocd`, `task lint:all` read. Check (live, consent-gated sync, then READ-class): the live `argocd-cm` shows the revision setting on (a ConfigMap read); `argocd account can-i` for the new account, in two stages. Stage 1 (the allowlist is empty, which is the initial state): `get` answers `yes`; sync, prune and refresh (if refresh is a separate action) answer `no` for every app; `override`, `delete`, `create` and `update` answer `no`. Stage 2 (only after an app has been added to the allowlist by a reviewed PR, a disposable test application first): the sync and prune checks answer `yes` for that app only and `no` for every other app and for `override`. A behavioural test of syncing a non-`main` revision runs only against a disposable test application in a scratch project (consent-gated), never against a real app, because a misconfiguration would deploy that revision.
- Consent: this changes ArgoCD's own configuration (a `core` app), and a merge may deploy it; ask before merging and before any sync. Using the token to sync or prune still needs fresh consent for each action (`AGENTS.md`).

## T19. Namespace, RBAC and backup objects for the workspace (GitOps-owned)

- Status: in review (app `cluster/apps/system/dev-workspace`; T13 is merged and applied). Deviation from the text below, for the owner to confirm: the reader role is an explicit ClusterRole `dev-workspace-reader`, not a binding of the built-in `view` (which aggregates 18 external-secrets generator kinds that can hold inline credentials and grows when operators change). The BWS-token ExternalSecret renders only after the owner fills in the two Bitwarden references (T4). Live checks are not run: they need the consent-gated sync. Blocked by: T4 for the BWS references only.
- Do: add an app (use the `add-app` skill) that owns everything the provisioner must not create (D35):
  - the `dev-workspace` namespace with Pod Security `baseline`;
  - the Talos `ServiceAccount` with `os:reader`, and RBAC that lets nothing but GitOps create `serviceaccounts.talos.dev` there;
  - the Kubernetes ServiceAccount and read-only RBAC from D27 as explicit lists, no wildcard resources: the built-in `view` ClusterRole plus one reviewed ClusterRole for the cluster-scoped resources and the CRD groups the owner uses (derive the list from the live CRDs with a read-only `kubectl get crd`, justify each group, and review each resource type for credential-bearing fields). Subresources are granted only where named (`pods/log`);
  - the Coder provisioner's Role and RoleBinding in `dev-workspace`: manage Deployments; `get`, `list` and `watch` on Pods and events only if T5 shows the template's rollout wait needs them; no PVC permission, because the template only references the existing claim (D39); no `externalsecrets`, `replicationsources`, RBAC or `serviceaccounts.talos.dev`;
  - the workspace list (D42): a values list, one entry per workspace, each rendering two PVCs (`<workspace>-home` about 5 Gi and `<workspace>-src` about 30 Gi, on `ceph-block`, D39, D41) and, with `charts/volsync` and `pvc.existingClaim`, two backups (home every 6 h, source daily; the chart default is 12 h, so both schedules are set explicitly; `restore.enabled: false` on live claims, section 2a of `plan.md`). Also the BWS-token `ExternalSecret` (T4), the backup `ExternalSecret`s and the ingress deny-all NetworkPolicy (D22). The provisioner still gets no PVC permission (D35);
- Check (local): `helm template` or `kubectl kustomize`; `task lint:all` read; `.agents/bin/check-plans`.
- Check (live; the sync is consent-gated, the checks are READ-class and read no secret): (1) review the effective rules, not only the source: `kubectl get clusterrole view -o yaml` (aggregated rules) and `kubectl auth can-i --list --as=system:serviceaccount:dev-workspace:<name>`; (2) concrete negative checks with `kubectl auth can-i --as=...`, each must answer `no`: `get`, `list`, `watch` on `secrets`; `get` on `nodes/proxy`, `pods/proxy`, `services/proxy`; `get` and `create` on `pods/exec`, `pods/attach`, `pods/portforward`; `create` on `serviceaccounts/token`; `update` and `patch` on `pods/ephemeralcontainers`; `get` on `certificatesigningrequests`; `impersonate`, `escalate`, `bind`; and `create`, `update`, `patch`, `delete` on each of `pods`, `deployments`, `configmaps`, `services`, `namespaces`, `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings`, `serviceaccounts`, `customresourcedefinitions`, `externalsecrets` and `serviceaccounts.talos.dev`. A check on `*` alone is not evidence; (3) positive control: `yes` for `get`, `list` and `watch` on `pods`, `nodes`, `namespaces` and the chosen CRD resources; (4) both PVCs of the first workspace exist, are `Bound`, and are mounted by name; (5) the provisioner ServiceAccount answers `no` for `externalsecrets`, `replicationsources`, `roles`, `rolebindings` and `serviceaccounts.talos.dev` in `dev-workspace`, and `no` for `persistentvolumeclaims` as well, and `yes` only for the workload objects of D35.
- Consent: a merge deploys the namespace and RBAC (ArgoCD sync); ask before merging and before syncing.

## T21. Dev StorageClass (dropped)

- Status: dropped by the owner on 2026-11-03 (D44). The workspace PVCs use `ceph-block`. The number is kept so references to T22 and T23 stay valid.

## T22. Test the pod hardening on this image (D43)

- Status: done 2026-11-04 (report in `evidence.md`; Coder agent start NOT RUN, `OnRootMismatch` benefit inconclusive; scratch namespace `t22-scratch` and PVC `t22-home` still to be deleted with consent). Needs the pinned image only.
- Do (consent-gated; scratch namespace labelled `pod-security.kubernetes.io/enforce: restricted`, then deleted): run the image with the pod settings of T5 plus `readOnlyRootFilesystem: true`, `emptyDir`s on `/tmp` and `/cache`, a PVC on the home path, and `fsGroup: 1000` with `fsGroupChangePolicy: OnRootMismatch`. Check: the pod is admitted at `restricted`; `cp -rn /etc/skel/. "$HOME"/` works on an empty home and a second run changes nothing; `mise use -g`, `mise install`, `git`, `npm ci`, `go build` and `terraform init` work; the Coder agent starts; list every path that needed to be writable. Record start time with a populated volume, to confirm `OnRootMismatch` avoids the walk.
- Output: a report in `evidence.md`; the answer to Q24 (namespace level, `readOnlyRootFilesystem` kept or not).
- Check: report each as PASS, FAIL or NOT RUN with the reason.

## T23. Try the image in a local devcontainer (D46)

- Status: todo. Blocked by: nothing for the image; the `home-ops` switch itself is T10.
- Do: in a scratch directory outside this repository (not committed), write a `devcontainer.json` that references the pinned image with no `features` block, open it with the devcontainer CLI or VS Code, and check that the image label mounts the named volume `dev-workstation-cache` on `/cache` (the image says no test covers this), that `mise activate bash` makes a repository's `mise.toml` win, and that `GOMODCACHE`, `npm_config_cache` and `TF_PLUGIN_CACHE_DIR` resolve under `/cache`. Report anything that differs from the image notes.
- Check: PASS, FAIL or NOT RUN with the reason; no change to the repository's own `.devcontainer`.
