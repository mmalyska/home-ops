<!-- markdownlint-disable MD013 -->

# Handoff for a fresh session (2026-11-04)

Portable handoff for the `remote-dev-workspace` plan. Read `AGENTS.md` first, then `plan.md` (decisions D1 to D48, open question Q24), `tasks.md` and `evidence.md`. The plan, not this file, is the source of truth; this file says where things stand and what to do first.

## Scope and mode

- Always-on Coder dev workspace on the Talos cluster, built from `ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:76a0c4f0359029fa9ce976a39b87d7770bb332c56336e7ea673d753a0dc30f98`.
- Profile STANDARD, topology SOLO. Work in linked worktrees (`.worktrees/<type>/<slug>`), run `.agents/bin/worktree-preflight` before the first write, no AI attribution in commits or PRs.
- Push and PR only when the owner says so for that task. Every cluster mutation (syncs, `kubectl annotate`, scratch volumes, workspace restarts) needs fresh consent that names action, target and effect. Never read secret values or print the environment.
- Shell tooling notes: the worktree guard fails closed on long heredocs and multi-line `python`, so use the Edit and Write tools and short commands, and absolute paths. The first `git push` sometimes fails transiently; retry. The agent session has no `argocd` login and no container runtime; the owner runs those with the `!` prefix or in the workspace.

## State at handoff

| Area                                                                                                               | State                                                   |
| ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| Image, containers pipeline, dotfiles (`mmalyska/dotfiles` #7 and #8)                                               | done and merged                                         |
| Namespace app `cluster/apps/system/dev-workspace` (PVC pairs, backups, RBAC, Talos ServiceAccount, ExternalSecret) | merged and synced                                       |
| Talos `os:reader` access (T13)                                                                                     | merged and applied                                      |
| Coder template `workspace-template-dev-workspace`, bootstrap script, `.envrc` loader, Taskfile version guards      | merged; template pushed to Coder                        |
| First workspace (T7)                                                                                               | running; checks in `evidence.md` all PASS except below  |
| Argo CD account (T18): read all apps and projects, sync and prune only on `default/sync-probe`, no `override`      | done, merged, synced, tested live (stage 1 and stage 2) |
| Docs PR #6091, evidence PRs up to #6097                                                                            | merged                                                  |

Open inside T7: Codex login persistence across a restart was skipped by the owner.

The status lines of T5, T13, T16 and T19 in `tasks.md` still say "in review"; the work is merged (T5 #6086 and #6087, T13 and T19 #6076, T16 dotfiles #7). Treat the merged state as true and tidy those lines in the next plan PR.

## Next steps (owner picks; suggested order)

1. **DONE 2026-11-05 (T8).** **T8 restore test** (consent-gated, DESTRUCTIVE only for the scratch volumes it creates): restore the latest snapshot of `dev-workspace-home` and `dev-workspace-src` into scratch volumes, list file names only, check the accepted login files are present and the must-not-persist names are absent, then delete the named scratch volumes. Also the safety checks in the workspace (repository Claude permission file applies, preflight returns 0 in a worktree and 3 in the primary checkout). The Argo CD ask rules for sync and prune are in `.claude/settings.json`.
2. **DONE 2026-11-05 (Q24 answered: keep `baseline`, no PR).** **Q24** (waited for the owner): Pod Security level and `readOnlyRootFilesystem`. `evidence.md` (T22) shows `restricted` is admitted and the read-only root works. Needs the owner's answer, then a small PR (namespace label) if they choose `restricted`.
3. **DONE 2026-11-04 (T11, #6098).** **T11 docs and skills**: `cluster/apps/ai/coder/README.md` table, a docs page for the remote workspace, update `.agents/skills/coder-workspace-template-deploy/SKILL.md` for the new template, then `.agents/bin/sync-skills`. Part of the Argo CD section already lives in `docs/src/k8s/dev-workspace.md`.
4. **T23 DONE 2026-11-05; T10 next.** **T23** local devcontainer test of the image (scratch directory outside the repository, not committed), then **T10** (one PR per repository, `home-ops` first, rollback digest in the PR text).
5. **DONE 2026-11-05 (T9, values accepted).** **T9** measure resources after about two weeks of use (Prometheus, `prometheus-historical-queries` skill); ask before changing limits.
6. Later: add real applications to the Argo CD allowlist, one reviewed PR each, with `Prune=false` on PVCs and stateful owners; exclusions in D38. The `sync-probe` app can stay as a test target or be removed (removal is a separate live step, see the `add-app` skill).

## Decisions and facts a new session must not re-derive

- D48: the Coder workspace does not run a repository's `.devcontainer` lifecycle; per-repository setup is manual for now (`direnv allow`, `task precommit:init`). A hook that stops Claude writing memory outside the repository is the owner's to write.
- Talos and Cilium client guards fail only when the installed client is older than the repository pin.
- Argo CD: `get` covers read and hard refresh, `sync` covers prune, a revision other than `targetRevision` needs `override` (never granted; `requireOverridePrivilegeForRevisionSync` is on), `argocd app get` also needs `projects, get` (granted). The CLI needs `--grpc-web` (set through `ARGOCD_OPTS` in the template). `kubectl auth can-i` needs `--subresource=` for subresources.
- Argo CD itself and the ApplicationSets refresh about every 24 h and `argocd` has `syncPolicy.enabled: false`: after a merge the owner (or the agent with consent) hard-refreshes the Application, then syncs `argocd`. A new app appears once `appset-default` (or the matching ApplicationSet) has refreshed.
- A workspace checkout does not update itself: `git pull --ff-only` in the workspace, then `direnv allow` after a changed `.envrc`.
- Benign recurring event: ceph-csi `FailedMount` "Aborted ... Pod UUID already exists" on start. `lost+found` in `/workspaces` is the ext4 root.
- Never write the private domain, Bitwarden identifiers, node credentials or secret output into any file, PR text or message.

## Where things are

- Plan: `.plans/remote-dev-workspace/{plan.md,tasks.md,evidence.md,bootstrap.md,tools.md,talos-access.md}`.
- Workspace docs: `docs/src/k8s/dev-workspace.md`. Template: `cluster/apps/ai/coder/workspace-template-dev-workspace/`. Namespace app: `cluster/apps/system/dev-workspace/`. Argo CD policy: `cluster/apps/core/argocd/patches/argocd-rbac-cm.yaml` and `argocd-cm.yaml`.
- Template deploy procedure: skill `coder-workspace-template-deploy`.
