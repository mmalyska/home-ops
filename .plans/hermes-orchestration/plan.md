---
status: draft
owner: repository owner
profile: DEEP
topology: SOLO
base_sha: 811d8ced9af420910a852f1b799141433017a861
branch: feat/hermes-orchestration
worktree: .worktrees/feat/hermes-orchestration
pr: not-opened
started: 2026-11-06
updated: 2026-11-06
---

# Hermes orchestration: two profiles, Coder workspaces, Renovate triage, spec-driven work

## Goal

Hermes (`cluster/apps/ai/hermes-agent`) becomes a working assistant with two profiles:

- **`default`**: the orchestrator and chat driver. It talks with the owner on Discord, writes specs, plans work on the kanban board, makes the decisions and does the merges it is allowed to do.
- **`worker`**: does well-defined tasks the orchestrator assigns, using a cheaper model. It runs the Renovate PR checks and implements specs.

Neither profile runs commands in the Hermes pod. Each one has its own Coder workspace (template `agent-workspace`, namespace `agent-workspaces`) as its SSH terminal, its own GitHub account and its own credentials.

Three jobs:

1. **Chat**: ad-hoc conversations on Discord (other platforms later, out of scope here).
2. **Daily Renovate triage** at 06:00 Europe/Warsaw, across every non-archived `mmalyska` repository. The worker checks each open Renovate PR. The orchestrator merges the clean ones itself and asks the owner about the rest.
3. **Spec-driven work**: the owner and Hermes write a spec in a spec PR. When the owner says "go", Hermes runs it to a finished PR and only comes back for questions and for the final review.

## Current state (2026-11-06, evidence in `evidence.md`)

- Hermes runs the image `v2026.9.24`. Upstream moved to `v0.x` tags (latest `v0.23.0`, 2026-11-05). Renovate's `loose` versioning ranks `0.23` below `2026.9`, so no upgrade has been proposed since the switch. Profile routing for delegation, the "one gateway for every profile" change and cron stop/cancel all arrived in v0.22 to v0.23.
- The PVC is 10 days old (the stack was restored on 2026-10-26, #5936). At boot only `default` is reconciled. The README still lists seven profiles and the Honcho ConfigMap seven hosts. Whether the old profile directories exist on the PVC is unknown (finding out needs an `exec`). T5 finds out.
- `agent-workspaces` (namespace, provisioner Role, guardrails, SSH ingress from the Hermes pod) and the `agent-workspace` template exist. No workspace runs. The template loads the signing key into an in-pod ssh-agent and puts `GITHUB_TOKEN` in the environment, but writes no git configuration (identity, signing format, credential helper). The workspace read role already covers `argoproj.io` (ArgoCD Applications) and has no Secrets.
- The Bitwarden references `HERMES_MAIN_GITHUB_TOKEN` and `HERMES_WORKER_GITHUB_TOKEN` are already allowlisted (#6119).
- GitHub accounts: `rudi-the-brain` (main profile) and `agent-rosie` (worker), both created 2026-11-06. PR #6133 (rudi as code owner) is open.
- The Renovate bot is `app/bendo-bot`. Open bot PRs: home-ops 11, containers 3, homelab-portal 12.
- In home-ops a merge deploys (ArgoCD). `AGENTS.md` makes every merge a GITOPS_TRIGGER that needs fresh consent, and treats non-interactive runs as denied. Without a written exception Hermes would refuse to auto-merge in home-ops.

## Decisions (owner, 2026-11-06)

| #   | Decision                                                                                                                                                                                                                                                                                            |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Auto-merge covers patch, minor, digest **and major** updates, provided they pass every gate in "Clean gate". The denylist always applies.                                                                                                                                                           |
| D2  | Scope: every non-archived repository owned by `mmalyska`. New repositories are picked up automatically.                                                                                                                                                                                             |
| D3  | Models: `default` stays on `main` (`chatgpt/gpt-6.1-sol`). `worker` uses a new gateway alias `main-cheap` (`chatgpt/gpt-6.1-terra`, same subscription), with gateway fallback to `main`. If the provider does not serve Terra (T1), `main-cheap` points at `main`'s model and nothing else changes. |
| D4  | Hermes never merges a spec/feature PR. The owner merges every non-Renovate PR.                                                                                                                                                                                                                      |
| D5  | Two workspaces: `hermes-main` (rudi, no cluster access) and `hermes-worker` (rosie, read-only Kubernetes, no Talos).                                                                                                                                                                                |
| D6  | After an auto-merge in home-ops, an app that turns unhealthy gets a revert PR. Hermes notifies the owner and does not merge the revert.                                                                                                                                                             |
| D7  | Old profiles (orchestrator, devops, researcher, dotnet-dev, node-dev, mobile-dev) are kept on disk, but taken out of dispatch, overlays and docs. Honcho hosts are set to `enabled: false`.                                                                                                         |
| D8  | Discord: a new channel `#hermes-renovate` gets one daily summary and one thread per PR that needs a decision. Spec work gets one thread per spec in the existing free-response channel.                                                                                                             |
| D9  | The daily run starts at 06:00 Europe/Warsaw, every day.                                                                                                                                                                                                                                             |
| D10 | Identities: `rudi-the-brain` for `default`, `agent-rosie` for `worker`. Git authenticates over HTTPS with each account's GitHub token (`gh auth setup-git`); there is no SSH authentication key. Each account has an SSH signing key, and all their commits are signed.                             |
| D11 | A spec is `.plans/<slug>/` (plan.md + tasks.md) in the target repository, in a spec PR. Execution starts when the owner says "go" in the spec thread.                                                                                                                                               |

## Design decisions (conductor; each one follows from the decisions above)

| #   | Decision                                                                                                                                                                                                                                                                                                                                                                                                                 | Why                                                                                                                                                        |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1  | Everything Hermes needs is declared in git and seeded on pod start: profile config overlays, per-profile `.env` (non-secret keys only), SOUL.md, skills, the cron job and the kanban settings. The only imperative step is `hermes profile create worker`, run once.                                                                                                                                                     | The pod and the PVC can then be rebuilt from git. The current README depends on hand edits in the pod.                                                     |
| C2  | The merge rules live in one file, `.agents/policy/hermes-merge-policy.md` in home-ops. `AGENTS.md` and `permissions.md` point to it as a standing, scoped authorization. Hermes's skill reads the live copy from `main` at the start of every run.                                                                                                                                                                       | Consent rules belong in `AGENTS.md`/`.agents/`. A single file stops the skill and the policy from drifting apart. A policy edit is a reviewed PR.          |
| C3  | Rollout ramp: the policy file holds `merge_enabled: false` at first. For 3 daily runs Hermes reports what it _would_ merge and merges nothing. The owner turns it on in a one-line PR (T14).                                                                                                                                                                                                                             | The owner checks the gate against real PRs before anything deploys by itself.                                                                              |
| C4  | The orchestrator does not trust the worker blindly. Before each merge it re-checks the deterministic gates itself through the GitHub API (author, denylist, head SHA, checks, mergeability). The worker's judgement covers only changelog and diff semantics.                                                                                                                                                            | PR bodies and changelogs are untrusted input (prompt injection). A wrong verdict must not be enough to merge something on the denylist or with failing CI. |
| C5  | The worker cannot merge. Its account `agent-rosie` gets write access (needed to push fixes to Renovate branches and open PRs), and its profile has `approvals.deny` globs for `gh pr merge*`, `gh api*merge*`, `gh api*pulls*` writes, `git push*main*` and `git push --force*`. Residual risk: on user-owned repositories GitHub cannot stop a write collaborator from merging, so the deny globs are the only barrier. | Owner accepts this as part of D10. It is recorded in the policy file.                                                                                      |
| C6  | Hermes's own stack (`hermes-agent`, `litellm`, `litellm-operator`, `honcho`, `agent-workspaces`, `coder`) is on the denylist.                                                                                                                                                                                                                                                                                            | A bad merge there would take Hermes down before its post-merge check can report.                                                                           |
| C7  | Work directories: the worker clones each task into `/workspaces/tasks/<kanban-task-id>/<repo>` and deletes the directory when the task ends. Long-lived checkouts are in `/workspaces/repos/<repo>` (fetch only). `kanban.max_in_progress_per_profile.worker: 2`.                                                                                                                                                        | One SSH target per profile, so parallel tasks need separate trees.                                                                                         |
| C8  | The worker has no memory toolset and no Honcho host. `default` keeps Honcho.                                                                                                                                                                                                                                                                                                                                             | Worker tasks are self-contained. User modelling belongs to the chat profile.                                                                               |
| C9  | The Hermes pod drops its own `GITHUB_TOKEN` (the old personal token) and the `sandbox` SSH key. GitHub credentials exist only in the workspaces.                                                                                                                                                                                                                                                                         | The tokens follow the profiles, not the pod. The `sandbox` workspace is gone (#5784).                                                                      |
| C10 | A run that finds nothing still posts its summary ("0 PRs"). If no summary appears by 07:00, the run failed.                                                                                                                                                                                                                                                                                                              | Silence must mean something.                                                                                                                               |
| C11 | A spec PR is also its implementation PR: the worker pushes to the spec branch. A spec may declare extra PRs in `tasks.md`. The PR starts as a draft and is marked ready when every task is done and CI is green.                                                                                                                                                                                                         | Matches the home-ops convention (the plan travels with the change), and the owner reviews one place.                                                       |

## Clean gate (the content of `hermes-merge-policy.md`)

A Renovate PR is **clean** only if all of these hold. Gates G1 to G5 are deterministic and the orchestrator checks them itself (C4). G6 to G8 are judged by the worker, which must give evidence for each.

- **G1 Author**: the PR is opened by `app/bendo-bot` from a `renovate/` branch, is not a draft and has no `do-not-merge`/`blocked` label. Every commit is Renovate's (a PR the worker fixed under "fix" is no longer auto-mergeable; the owner decides).
- **G2 Not denylisted.** home-ops: `cluster/apps/core/**`; packages or paths for Talos, kubelet and `tuppr`; the `kubernetes` group; `cilium` (the chart; `cilium-cli` is allowed); `rook-ceph*`; `cloudnative-pg` and Postgres images used by CNPG clusters; `argo-cd`; `envoy-gateway`; `cert-manager`; `external-secrets`; `coredns`; `cluster/apps/ai/coder/workspace-template*/**`; the Hermes stack (C6); `provision/**`; Terraform providers and modules. Other repositories: all of `github-workflows` and `renovate-config` (they change every other repository). Every other repository: none.
- **G3 CI**: every check run and status on the head SHA has finished with `success`, `skipped` or `neutral`, none is pending, `mergeable` is `MERGEABLE` and `mergeStateStatus` is not `BLOCKED`/`BEHIND`/`DIRTY`.
- **G4 Head SHA**: the head SHA at merge time is the one the worker checked.
- **G5 Renovate automerge**: if Renovate's own automerge is on for the PR and the PR is less than 24 h old, skip it (Renovate will merge it).
- **G6 Diff shape**: the changed lines are only version, tag, digest, chart version and the matching lock/checksum lines. Anything else (a new key, a values change, a migration file) is not clean.
- **G7 Release notes**: the worker read the release notes or changelog for every version between the old and the new one (GitHub releases, `CHANGELOG*`, Artifact Hub changes for charts). It cites each source. Not clean: a breaking change, a removed or renamed option that this repository uses (the worker greps the repository for it), a required migration or manual step, a minimum-version requirement this repository does not meet, or notes it could not find for a major. For a major, the verdict must name the breaking changes listed upstream and say why none applies here.
- **G8 Rendered impact (home-ops, Helm/Kustomize apps)**: the rendered diff (the `diff-yaml-on-pr` workflow comment, or `helm template` of base and head) changes only image references, chart/app version labels and annotations, and checksum annotations. Not clean: CRDs, `volumeClaimTemplates`, PVC specs, Service type or ports, RBAC rules, NetworkPolicies, a new or removed resource, a security context change.

Run limits (home-ops): at most 5 auto-merges per run, one at a time. After each merge the worker waits up to 20 minutes for the ArgoCD Application(s) owning the changed path to reach `Synced` + `Healthy`. On a failure: stop merging for the rest of the run, open a revert PR (as `agent-rosie`), and post the evidence in the PR's thread with an owner mention (D6). Other repositories: no limit. The post-merge check there is the default-branch CI run after the merge; if it fails, the same revert-and-notify applies.

## Behaviour

### Daily Renovate run

1. 06:00 Europe/Warsaw: the cron job `renovate-daily` (profile `default`, skill `renovate-triage`) starts.
2. `default` reads `hermes-merge-policy.md` from home-ops `main`, lists the open `app/bendo-bot` PRs in every non-archived `mmalyska` repository, and drops those G5 skips.
3. For each remaining PR it creates a kanban task for `worker` with idempotency key `renovate:<repo>#<number>@<head-sha>`. A PR already checked at the same SHA is not checked again; its earlier verdict is reused.
4. `worker` runs skill `renovate-pr-check` and completes the task with a verdict in the task metadata (schema in the skill): `clean | needs-owner | needs-fix`, with the gates passed and failed, each with evidence and links.
5. `default` waits for all verdicts (up to 2 h; a task still open after that counts as `needs-owner` with reason "timeout"). Then, for `clean` verdicts and `merge_enabled: true`, it re-checks G1 to G5 and merges with the repository's allowed method (squash where allowed). After each home-ops merge it assigns `worker` the post-merge check.
6. It posts the summary in `#hermes-renovate`: merged, would-merge (while `merge_enabled` is false), waiting for the owner (with links to threads), skipped and why, and checks that failed to run.
7. For each `needs-owner`/`needs-fix` PR it creates or reuses a thread named `<repo>#<number> <title>`. The thread holds the verdict, the reasons and four choices: **fix** (the worker pushes the change to the Renovate branch, re-checks, and the PR comes back as `needs-owner`), **I merge** (Hermes stops tracking it), **merge** (`default` merges it; this is the owner's per-action consent), **reject** (close the PR with a comment, which makes Renovate ignore that version). An unanswered thread is listed again in each daily summary. It never expires.

### Spec-driven work

1. The owner starts a conversation (a mention in the free-response channel opens a thread). `default` asks questions until the spec has no open question, then writes `.plans/<slug>/plan.md` and `tasks.md` in the target repository, following that repository's plan convention (home-ops: `.plans/README.md` and `check-plans`; other repositories: the same layout). It pushes `feat/<slug>` as `rudi-the-brain` and opens a draft spec PR.
2. "go" in the thread starts execution. `default` turns `tasks.md` into kanban tasks with `parents` for the dependencies, assigned to `worker`.
3. `worker` implements each task in its own task directory (C7). It follows the target repository's `AGENTS.md` (worktrees, checks, no AI attribution, no secrets), commits signed as `agent-rosie`, pushes to the spec branch and completes the task with the checks it ran.
4. Questions: the worker blocks the task with `kind=needs_input`. `default` answers from the spec if it can; otherwise it asks in the spec thread and unblocks the task once the owner answers.
5. When every task is done and CI is green, `default` marks the PR ready and mentions the owner in the thread. The owner merges (D4). Review comments on the PR become new kanban tasks.

### Chat

`default` answers on Discord as today. Its terminal is `hermes-main`. It may delegate a bounded task to `worker` through the kanban.

## Out of scope

Platforms other than Discord. Talos access for Hermes. Hermes merging feature PRs. Automating the owner prerequisites (Bitwarden items, GitHub keys and invitations, the Discord channel). Removing the old profile directories. The admin-workspace TODO item.

## Acceptance criteria

1. `kubectl -n agent-workspaces get deploy` shows `ws-mmalyska-hermes-main` and `ws-mmalyska-hermes-worker` Available. `coder list` shows both healthy and up to date.
2. From the Hermes pod: `hermes chat -q` with a command such as `hostname` runs on `hermes-main` for `default` and on `hermes-worker` for `-p worker` (the hostnames differ from the Hermes pod's).
3. In the workspaces: `gh auth status` shows `rudi-the-brain` and `agent-rosie` respectively. A test commit on a scratch branch shows "Verified" on GitHub. `git push` over HTTPS with the token works. The worker cannot merge (a `gh pr merge` attempt is denied by the approval globs; tested on a throwaway PR in a non-GitOps repository, consent-gated).
4. `hermes kanban` assigns to `worker` only (`dispatch_profiles: [worker]`). The old profiles are not dispatched.
5. With `merge_enabled: false`: three consecutive daily runs post a summary by 07:00 with a verdict for every open bot PR, and nothing is merged.
6. With `merge_enabled: true`: a clean PR is merged and its app is checked. A denylisted or failing PR gets a thread with the four choices. "merge" in a thread merges.
7. A spec conversation produces a spec PR. "go" leads to commits by `agent-rosie` on that branch and a ready PR with green CI, with no owner input other than the questions the worker raised.
8. Pod restart: the profiles, cron job, skills, SOUL.md files and settings come back from git without any manual step except the first `hermes profile create worker`.
9. Docs updated: `cluster/apps/ai/hermes-agent/README.md`, `docs/src/k8s/agent-workspaces.md`, `docs/src/k8s/ai-gateway.md`, `AGENTS.md`, `.agents/policy/permissions.md`, the `hermes-merge-policy.md` file, and the stale Hermes memory note.

## Rollback

- Stop auto-merging: `merge_enabled: false` (one-line PR), or pause the cron job (`hermes cron pause renovate-daily`, consent-gated).
- Revert to today's behaviour: revert the hermes-agent chart PRs. Seeded files that are no longer listed stay on the PVC but are inert, because the overlays no longer reference them. Restore the PVC from the VolSync backup taken in T4 if the upgrade damages state.
- Workspaces: `coder delete` removes their PVCs (backups stay in restic). Remove the allowlist entries afterwards.

## Status

Draft, waiting for the owner's approval. Owner prerequisites: `tasks.md` section 0.
