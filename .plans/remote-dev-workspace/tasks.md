<!-- markdownlint-disable MD013 -->

# Tasks

Each task can be executed without reading `plan.md`. A task that depends on an open question (Qn) is blocked until the owner answers it; the question text is in `plan.md`. Do all repository work in a linked worktree; run `.agents/bin/worktree-preflight` before the first write. Every command that changes cluster or external state needs fresh consent from the owner in the current session.

Common context: the goal is one always-on Coder workspace, on the Talos cluster, for several repositories of the owner, built from one shared multi-arch image published from `mmalyska/containers`. Secrets come from one dedicated BWS project per workspace type. `sandbox-*` images and the `devops` workspace belong to Hermes and must not be changed.

Dependency order (template preparation is separate from creating the first workspace):

```text
T15 -> T2 -> T3 ----------------------------> T5 (template, no workspace)
T1  -> T2                                      ^
T13 (Talos config) -----------------------------+
T19 (namespace, RBAC, backup objects) -----------+
T4 (BWS project, owner) -------------------------+
T2 -> T6 -> T16 ; T14 ; T17 ------------> T7 (first workspace + login) -> T8 -> T9
T17 + T8 + T3 -----------------------------> T10 (migrate devcontainers)
T4 -> T18 (ArgoCD account) -> ArgoCD checks in T7 and T8
```

## T1. Inventory the tools the new image needs

- Status: todo. Blocked by: nothing (Homebrew is out, D12: record for each tool its pinned-release source).
- Do: list every tool the home-ops devcontainer and `sandbox-devops` provide, and every tool the home-ops scripts, `Taskfile`, pre-commit config and `.envrc` call. The real tool list of the local devcontainer is `.github/.devcontainer/local-features/common/Brewfile` (direnv, egctl, gitleaks, go-task, helm, ipcalc, jq, kubectl, kustomize, prettier, stern, terraform, yamllint, yq, argocd, kubelogin, k9s, pre-commit, mkdocs, gh, helmfile, chezmoi, node as of 2026-11-02) plus the other local features. Read `.github/.devcontainer/local-features/*/install*.sh`, that Brewfile, `.devcontainer/scripts/*.sh`, `.taskfiles/`, `.pre-commit-config.yaml`, `.envrc` and `containers/apps/sandbox-devops/Dockerfile`. Then do the same for `claude-plugins`, `containers` and `argocd-secret-replacer` (read only, via `gh api` or a clone).
- Output: `.plans/remote-dev-workspace/tools.md` with a table: tool, source today (feature, Dockerfile, Brewfile), version pin today, used by which repository, upstream publishes checksum (yes/no), has arm64 build (yes/no), Renovate datasource, install path in the image (must be outside `/home/vscode`, D34).
- Check: every tool called by a script or Taskfile target appears in the table; no secret value or private domain appears in the file.

## T2. Build the `dev-workstation` image in `containers`

- Status: todo. Blocked by: T1, T15.
- Do: in `mmalyska/containers` add `apps/dev-workstation/` with `Dockerfile`, `README.md`, `metadata.json` and `ci/`, copying the layout and metadata rules of `apps/sandbox-devops`. Pinned Ubuntu LTS digest. Non-root user `vscode`, UID 1000, no sudo (D13, D17). No Homebrew (D12): install the tools from `tools.md` as pinned release downloads, resolving the architecture instead of hard-coding amd64, with Renovate annotations and checksums where upstream publishes them. **Install every tool under `/usr/local` or another system path, never under `/home/vscode`**: the workspace mounts a volume over the home directory and hides whatever the image put there (D34); put defaults in `/etc/skel`-style seed files instead. The `talosctl` version must equal `TALOS_VERSION` in `.taskfiles/talos/Taskfile.yaml`, because `task talos:install` (which uses `sudo`) is skipped only on an exact match; add a Renovate rule or a CI check that keeps them equal. Install Claude Code and codex-cli. Add the `devcontainer.metadata` label; there is one tag (D19). Build linux/amd64 and linux/arm64 with the native-runner pipeline from T15 (D24, D33).
- Check: CI builds both platforms; `docker run --rm <image> <tool> --version` for every tool on both platforms (run in CI, not in the workspace); no file of the image is under `/home/vscode` except the seed files; image size is recorded in the PR; Renovate dry run picks up the new annotations; no `sandbox-*` file is changed.
- Rollback: delete the app directory; nothing consumes it yet.

## T3. Publish and pin the image

- Status: todo. Blocked by: T2.
- Do: after merge in `containers`, record the published tag and the digest of the multi-arch manifest. Add the image reference (digest-pinned) to the PRs of T5 and T10 only.
- Check: `docker buildx imagetools inspect <image>` shows both platforms; the digest in the consuming PR matches.

## T4. Create the BWS project and the workspace token (owner action)

- Status: todo. Blocked by: nothing for the base set; the ArgoCD token waits for T18.
- Do (owner, in Bitwarden; the agent never reads values): create a project for the dev workspace type; add `GITHUB_TOKEN`, `TERRAFORM_TOKEN` and the SSH signing key (D32, D30; `SOPS_AGE_KEY` is not included). When T18 is done, also add the ArgoCD account token and the ArgoCD server address (the address contains the private domain, so it is delivered as a secret value, not written into the repository). Register the matching public key on GitHub as a signing key. `BWS_ACCESS_TOKEN` is the machine token you issue below and is delivered by the Kubernetes Secret, not stored in the project. Cluster access is **not** stored here (D4). Create a machine account with read-only access to that project only, and issue one access token. A Hermes sandbox type later gets its own, smaller project (D11).
- Agent part: write the secret **names** (no values, no identifiers) into `docs/` and into the T5 template comments; add an `ExternalSecret` (store `bitwarden`) in `dev-workspace`, owned by GitOps (D35, in the T19 app), that creates the Kubernetes Secret with `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` (D31), which the pod reads as environment variables. Make the Secret name a template parameter so other workspace types reuse the pattern. The Bitwarden identifiers stay out of plans, docs and PR text; manifests use the same reference mechanism other ExternalSecrets in the repository use.
- Check: `kubectl kustomize` or `helm template` renders the ExternalSecret with no identifier or value in anything but the manifest reference fields; gitleaks passes. Live: the Secret exists after sync (consent-gated sync).

```sh consent-gated
# After merge, owner decides when ArgoCD syncs the app that holds the namespace; do not run without fresh consent.
argocd app sync <app-name>
```

## T5. New Coder template (prepare only, no workspace)

- Status: todo. Blocked by: T3, T4, T13, T19. This task never creates a workspace; that is T7.
- Do: add a new template in a new directory under `cluster/apps/ai/coder/workspace-template/` (D16; the `sandbox` template is not changed). Requirements:
  - image from T3 (digest-pinned); `arch` follows the image platform;
  - runs as `vscode`, non-root, no sudo, `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault`, `fsGroup: 1000`;
  - memory request = limit = 3Gi; CPU limit 2; CPU request from T9 (start at 500m);
  - the PVC `dev-workspace-data` (created and owned by GitOps in T19, D39) mounted twice with `subPath`: `home` at `/home/vscode` and `workspaces` at `/workspaces` (D34). The template only references the PVC by name; it does not create it and has no size parameter. The first-start step seeds an empty home from the image's seed files and fixes ownership; nothing in the image under `/home/vscode` is relied on;
  - SSH through the Coder agent only (D15): no sshd, no LoadBalancer Service, no `authorized_key` parameter;
  - runs in the namespace `dev-workspace` (D28). The provisioner's Role there is created by T19 and allows only the workload objects the template needs (D35); the template creates no `ExternalSecret`, `ReplicationSource`, RBAC object or `serviceaccounts.talos.dev`;
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

- Status: todo. Blocked by: T2 (a scratch build of the T2 Dockerfile is enough to start; the spike runs inside the image).
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
  - persistence: write a marker file under `/home/vscode` and one under `/workspaces`, restart the workspace (consent-gated), and confirm both survive with owner `vscode`, and that the Claude and Codex logins survive;
  - `git log --show-signature -1` verifies in the scratch repository; `claude` and `codex` start;
  - `kubectl get nodes` works through the in-cluster configuration with no kubeconfig file (if the `.envrc` `KUBECONFIG` export gets in the way, fix it in T14);
  - `talosctl --nodes <control-plane ip> version` and `talosctl get` on a non-sensitive type work, a sensitive type and `talosctl kubeconfig` are denied, and the pod reaches `talos.default` (record which `talosctl get` types are sensitive);
  - authorization is checked with `kubectl auth can-i`, never by attempting a forbidden read: the negative list from T19 all answers `no` and the positive list answers `yes`;
  - the ArgoCD token works for the actions D29 allows and `argocd account can-i` denies the others (after T18);
  - `env` is **not** printed and no credential file is read (SECRET_ACCESS).

## T8. Verify safety controls in the workspace

- Status: todo. Blocked by: T7.
- Do: confirm in the workspace that the repository's Claude permission file and `AGENTS.md` consent rules apply (open `home-ops`, check that `.claude/settings.json` is read and a denied command is denied, including the ArgoCD sync and prune ask rules), and that the worktree preflight returns 0 in a worktree and 3 in the primary checkout. Then check what is on the backed-up volume, by file name only (`find`, never print contents):
  - accepted on the volume (D20): the Claude and Codex login files;
  - must stay off the volume: the SSH signing key, the Talos credential, the BWS access token and project reference, `GITHUB_TOKEN`, `TERRAFORM_TOKEN`, the ArgoCD token, and any file a tool writes when it persists a login (for example `.git-credentials`, the `gh` hosts file, Terraform CLI credentials, an `~/.kube/config`); T6 supplies the final list of file names.
- Do (restore test, consent-gated): restore the latest VolSync snapshot into a scratch volume, list file names, confirm the accepted login files are present, the must-not-persist names are absent, and `/home/vscode` and `/workspaces` content and ownership are intact. Delete the scratch volume afterwards (DESTRUCTIVE for that scratch volume only; name it first).
- Check: report each as PASS, FAIL or NOT RUN with the reason.

## T9. Measure and adjust resources

- Status: todo. Blocked by: T7. Run for two weeks after first use.
- Do: query Prometheus (use the `prometheus-historical-queries` skill) for the workspace pod: max and p95 of `container_memory_working_set_bytes`, CPU usage p95, throttling, restarts and OOM kills; and the PVC usage. Check node headroom on the node hosting the pod.
- Output: a table in `plan.md` Status with measured values and the proposed new requests and limits; ask the owner before changing them.
- Check: numbers come from queries, not estimates; the memory limit stays above the observed peak by a stated margin.

## T10. Move devcontainers to the new image

- Status: todo. Blocked by: T3, T6, T8, T17.
- Do: one PR per repository that has a `.devcontainer` (home-ops, containers, github-workflows, homelab-portal, argocd-secret-replacer, and the two old ones willow-inference-server-dockerized and home-assistant if still wanted; claude-plugins has none), `home-ops` first. Change `devcontainer.json` to `"image": "<new image>@<digest>"`, drop the `features` block and the local build, keep `runArgs`, `secrets` and lifecycle commands. For `home-ops` also remove `.github/.devcontainer/` (this deletes the Brewfile that `task init` reads, which is why T17 comes first), `.github/workflows/devcontainer-publish.yaml` and the Renovate rules that referenced them, and update `docs/`, `AGENTS.md` and the `dev-workflow` skill if they mention the old image. Keep the old image digest in the PR description as the rollback.
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

- Status: todo. Blocked by: nothing (T12 done). Use the reference YAML in [talos-access.md](talos-access.md); the Secret name equals the resource name.
- Do: edit `provision/talos/patches/controlplane/40-talos-api-access.yaml` to add `os:reader` to `allowedRoles` and the namespace `dev-workspace` to `allowedKubernetesNamespaces`; update its header comment with the new escalation note (the namespace can request `os:admin` because that role is in the cluster-wide list). Update the exact-match assertion in `provision/talos/tests/test_render.sh` (it asserts the roles and namespaces lists) and regenerate the generated docs (`docs/src/talos/config-map.md`) with the repository tooling. This is a separate PR from T19.
- Check (local): `bash provision/talos/tests/test_render.sh`, `bash .agents/tests/run.sh`, `task lint:all` read, `.agents/bin/check-plans`.
- Check (live, consent-gated): the change is a rolling machine config apply on mc1 to mc3 with its own impact statement and rollback (revert the patch and apply again).

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

## T17. Rework the home-ops bootstrap so both consumers work (prerequisite to T7 and T10)

- Status: todo. Blocked by: T6 (its output lists the script changes).
- Why: the local devcontainer and the Coder workspace must run the same lifecycle commands. Today they depend on things the new image drops: `task init` runs `brew bundle` against `.github/.devcontainer/local-features/common/Brewfile` (and the Taskfile precondition checks `command -v brew`), `.devcontainer/scripts/onCreateCommand.sh` calls `chezmoi` by its Homebrew path, several lines use `sudo` (including `sudo git config --global`, which writes root's configuration, not the user's), `task talos:install` uses `sudo`, and `postStartCommand.sh` hard-codes `/workspaces/home-ops`. Deleting `.github/.devcontainer/` (T10) would break all of them.
- Do: in `home-ops`: make `task init` and its preconditions check that the tools are present (the image provides them) instead of installing them with Homebrew; call `chezmoi` through `PATH`; replace `sudo git config --global` with the unprivileged form; make `task talos:install` a no-op when the pinned `talosctl` already matches; make the memory-symlink loop use the current repository path; keep Codespaces-only branches working; keep a documented way to run the tool install for a machine without the image if still wanted. Land the change while the old image still works, so it can be verified on the current local devcontainer first.
- Check: a fresh local devcontainer start with the current image passes the three lifecycle commands; the same scripts pass in a scratch container from the T2 image; `task lint:all` read; `bash .agents/tests/run.sh`; `.agents/bin/check-plans`. Report each as PASS, FAIL or NOT RUN.

## T18. ArgoCD account for the workspace

- Status: todo. Blocked by: T4 for storing the token (Q23 is answered, D38).
- Do: in `cluster/apps/core/argocd/patches/` add a dedicated local account for the workspace (API key only, no password login) and its policy in `argocd-rbac-cm.yaml`: read, refresh, sync and prune on a named allowlist of apps that starts empty (D38; the owner adds app names by reviewed PR), nothing else: no delete, no create or update of applications, no repository, cluster, project or account changes, no exec, and **no `override`**. In `argocd-cm` set `application.sync.requireOverridePrivilegeForRevisionSync: "true"` (documented since ArgoCD v3.2, deployed v3.5.6; confirm against the deployed version's docs before merging) so a sync cannot select an arbitrary revision such as an unmerged branch or an older commit. For each app added to the allowlist, put `argocd.argoproj.io/sync-options: Prune=false` on its PVCs and stateful owners (it stops ArgoCD pruning that object, not destructive updates or deletion by another controller). Confirm which ArgoCD actions refresh and prune need before writing the policy. The owner generates the token in ArgoCD and stores it in the dev BWS project (T4); the agent never handles it. SSO is not used from the workspace because the owner's identity and the `ArgoCDAdmins` group map to `role:admin` in that file.
- Check (local): `kubectl kustomize cluster/apps/core/argocd`, `task lint:all` read. Check (live, consent-gated sync, then READ-class): the live `argocd-cm` shows the revision setting on (a ConfigMap read); `argocd account can-i` for the new account answers `yes` for sync and prune on an allowlisted app and `no` for `override`, `delete`, `create` and `update` and for any app off the list. A behavioural test of syncing a non-`main` revision runs only against a disposable test application in a scratch project (consent-gated), never against a real app, because a misconfiguration would deploy that revision.
- Consent: this changes ArgoCD's own configuration (a `core` app), and a merge may deploy it; ask before merging and before any sync. Using the token to sync or prune still needs fresh consent for each action (`AGENTS.md`).

## T19. Namespace, RBAC and backup objects for the workspace (GitOps-owned)

- Status: todo. Blocked by: T4 (names only), T13 for the Talos part to work. Can be reviewed before T13 is applied.
- Do: add an app (use the `add-app` skill) that owns everything the provisioner must not create (D35):
  - the `dev-workspace` namespace with Pod Security `baseline`;
  - the Talos `ServiceAccount` with `os:reader`, and RBAC that lets nothing but GitOps create `serviceaccounts.talos.dev` there;
  - the Kubernetes ServiceAccount and read-only RBAC from D27 as explicit lists, no wildcard resources: the built-in `view` ClusterRole plus one reviewed ClusterRole for the cluster-scoped resources and the CRD groups the owner uses (derive the list from the live CRDs with a read-only `kubectl get crd`, justify each group, and review each resource type for credential-bearing fields). Subresources are granted only where named (`pods/log`);
  - the Coder provisioner's Role and RoleBinding in `dev-workspace`: Deployments, Pods, PVCs and their events only; no `externalsecrets`, `replicationsources`, RBAC or `serviceaccounts.talos.dev`;
  - the PVC `dev-workspace-data` (20Gi, `ceph-block`, D39), the BWS-token `ExternalSecret` (T4), the backup `ExternalSecret` and the VolSync `ReplicationSource` for that PVC, and the ingress deny-all NetworkPolicy (D22).
- Check (local): `helm template` or `kubectl kustomize`; `task lint:all` read; `.agents/bin/check-plans`.
- Check (live; the sync is consent-gated, the checks are READ-class and read no secret): (1) review the effective rules, not only the source: `kubectl get clusterrole view -o yaml` (aggregated rules) and `kubectl auth can-i --list --as=system:serviceaccount:dev-workspace:<name>`; (2) concrete negative checks with `kubectl auth can-i --as=...`, each must answer `no`: `get`, `list`, `watch` on `secrets`; `get` on `nodes/proxy`, `pods/proxy`, `services/proxy`; `get` and `create` on `pods/exec`, `pods/attach`, `pods/portforward`; `create` on `serviceaccounts/token`; `update` and `patch` on `pods/ephemeralcontainers`; `get` on `certificatesigningrequests`; `impersonate`, `escalate`, `bind`; and `create`, `update`, `patch`, `delete` on each of `pods`, `deployments`, `configmaps`, `services`, `namespaces`, `roles`, `rolebindings`, `clusterroles`, `clusterrolebindings`, `serviceaccounts`, `customresourcedefinitions`, `externalsecrets` and `serviceaccounts.talos.dev`. A check on `*` alone is not evidence; (3) positive control: `yes` for `get`, `list` and `watch` on `pods`, `nodes`, `namespaces` and the chosen CRD resources; (4) the provisioner ServiceAccount answers `no` for `externalsecrets`, `replicationsources`, `roles`, `rolebindings` and `serviceaccounts.talos.dev` in `dev-workspace`, and `yes` only for the workload objects of D35.
- Consent: a merge deploys the namespace and RBAC (ArgoCD sync); ask before merging and before syncing.
