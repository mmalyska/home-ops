---
status: draft
owner: repository owner
profile: DEEP
topology: SOLO
base_sha: 26f1c0d99675c02b6b3d466b7420ef630d019ec3
branch: feat/hermes-orchestration-plan
worktree: .worktrees/feat/hermes-orchestration-plan
pr: "#6176"
started: 2026-11-06
updated: 2026-11-08
---

# Plan: Hermes orchestration

## Objective and non-goals

- **Spec:** [spec.md](spec.md), accepted and merged in #6148. It owns the behaviour, the gates and the decisions; this
  plan does not restate them.
- **Objective:** deliver the spec in small PRs, each merged by the owner, ending with Hermes triaging Renovate PRs daily
  and running spec-driven work.
- **Non-goals:** everything under "Out of scope" in the spec, and the third `worker-lite` profile.
- **Acceptance:** the spec's success criteria, mapped to tasks under "Quality gates".

## Design decisions made here

The spec left these to the plan. They are proposals until this PR is merged.

| #   | Decision                                                                                                                           | Why                                                                                                      |
| --- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| P1  | "Non-archived repositories" means the 12 source repositories. The 9 forks are excluded.                                            | Forks hold upstream code and get no bot PRs                                                              |
| P2  | The label workflow acts only on PRs opened by `bendo-bot[bot]`.                                                                    | On a spec or plan PR it would replace `triage/owner` and hide the PR from the owner                      |
| P3  | Hermes configuration is seeded from git by the existing init containers, extended per task.                                        | Spec requires a rebuild from git; the seeders already exist                                              |
| P4  | Skills and SOUL files live in `cluster/apps/ai/hermes-agent/{skills,files}` and overwrite the copies on the volume at every start. | Git stays the only source                                                                                |
| P5  | Fallback lists, written in full: `main-cheap: [main, cheap, local]`, `main-lite: [main-cheap, main, cheap, local]`.                | Each falls to the next model up, then to the existing last resorts, without relying on chained fallbacks |
| P6  | New-repository requirements live in `docs/src/contributing/new-repository.md`.                                                     | One place, published with the other contributing docs                                                    |
| P7  | One PR per repository carries its CODEOWNERS, label workflow caller and Renovate changes.                                          | Twelve small reviewable PRs instead of three rounds of twelve                                            |

## Scope and ownership

The build actor is one agent working SOLO and is the integrator. The owner does T01 and every merge.

| Boundary                                                                        | Change                                       | Tasks                   |
| ------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------- |
| `cluster/apps/ai/litellm`, `docs/src/k8s/ai-gateway.md`                         | Two model aliases                            | T02                     |
| `cluster/apps/core/argocd/patches/argocd-cm.yaml`                               | 30-minute reconcile                          | T03                     |
| `cluster/apps/ai/hermes-agent/**`                                               | Upgrade, credentials, profiles, skills, cron | T04, T09, T10, T12, T14 |
| `.github/renovate/**`, `.github/labels.yaml`, `.github/CODEOWNERS`              | Renovate, labels, code owners                | T05, T16                |
| `cluster/apps/ai/coder/workspace-template-agent-workspace/**`                   | Git identity and signing                     | T06                     |
| `cluster/apps/ai/agent-workspaces/values.yaml`                                  | Allowlist                                    | T07                     |
| `AGENTS.md`, `.agents/policy/**`                                                | Merge policy                                 | T13                     |
| `mmalyska/github-workflows`, `mmalyska/renovate-config`, the other repositories | Label workflow, presets, protection          | T15, T16                |
| `docs/**`, `.claude/memory/**`, the Hermes README                               | Docs                                         | T17                     |

## Tasks and dependencies

Task records are in [tasks.md](tasks.md). SOLO runs them one at a time.

```text
T01 --> T07, T08, T09, T14                T02 --> T10, T14
T03 (independent)                         T04 --> T05, T09
T06 --> T07 --> T08, T10                  T09 --> T10 --> T11 --> T12 --> T14
T08, T15 --> T16 --> T14, T17             T13 --> T14
T14, T17 --> T18 --> T19 --> T20
```

## Quality gates

Results are filled in during Build. Everything is NOT RUN today.

| Spec success criterion                       | Method                                  | Task |
| -------------------------------------------- | --------------------------------------- | ---- |
| Both workspaces healthy                      | `coder list`, `kubectl get deploy`      | T07  |
| Commands run in the right workspace          | `hostname` through each profile         | T10  |
| Own account, HTTPS push, verified commit     | Scratch commit per account              | T08  |
| `agent-rosie` cannot merge alone             | Throwaway PR, that approval only        | T16  |
| Three report-only runs by 07:00              | Summaries and PR labels                 | T18  |
| 0 wrong "clean" verdicts in those runs       | Owner review, recorded in `evidence.md` | T18  |
| Clean PR merged and checked; denylisted asks | First runs with merging on              | T19  |
| Unchanged diff causes no worker task         | Second run, kanban board                | T18  |
| Spec, plan, implementation flow              | One real small piece of work            | T20  |
| Restored after a pod restart                 | Restart, then re-run the checks above   | T20  |

Every PR also runs the matching rows of `.agents/policy/validation.md`, and reports PASS, FAIL, NOT RUN or N/A.

## Authorization and runtime impact

- **Authority for this PR:** the owner's instruction to write the plan as a separate PR once #6148 was merged.
- **This plan grants nothing.** Merging it does not authorize Build. Each push, PR, merge and live change needs the
  owner's instruction when it happens, under `AGENTS.md`.
- **Merges that deploy:** T02, T03, T04, T07, T09, T10, T12, T14. Merges that change Renovate behaviour (GITOPS_TRIGGER):
  T05, T16. T13 and T17 deploy nothing. T19 deploys nothing itself, but from then on Hermes merges without the owner.
- **Live changes needing fresh consent** are in `consent-gated` blocks in the tasks.
- **Missing today:** everything in T01, and a logged-in `coder` CLI for T07.

## Rollout and rollback

Rollout follows the dependencies, not the task numbers. Merging stays off until T19. The rulesets arrive late (T16),
because from then on no PR merges without an approval. The daily job (T14) follows them, so its first run finds the
policy and the labels.

| What to undo            | How                                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------------- |
| Auto-merging            | One-line PR setting `merge_enabled: false`, or `hermes cron pause renovate-daily`         |
| Hermes behaviour        | Revert the chart PRs; restore the volume from the backup taken in T04 if state is damaged |
| Workspaces              | `coder delete` removes their volumes; restic backups stay. Then remove the allowlist IDs  |
| Rulesets and CODEOWNERS | Owner bypasses at once; delete the ruleset per repository                                 |
| Renovate automerge      | Revert the T16 PRs                                                                        |

A revert cannot undo what a merged update already did to the cluster. That has its own revert PR, per the spec.

## Status and next action

Completed: none. The plan is a draft for the owner to verify.

Exact next action: the owner reviews this PR. After it merges, Build starts at T01, on the owner's instruction.

The first plan draft (`e403e963`) was reconciled into these tasks. New since then: T03, T15, the label and new-repository
parts of T16, `main-lite`, read-only Kubernetes for both workspaces, and batch post-merge checks.

## Plan review

Distinct local validation pass on 2026-11-08 by the same agent, so it is not an independent review. Scope: the complete
first drafts of `plan.md` and `tasks.md` on base `26f1c0d9`, read against `spec.md`, the repository and read-only GitHub and
cluster queries.

| Finding                                                                                                        | Correction                                                 |
| -------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| The daily job (T14) could start before the policy and labels existed                                           | T14 now depends on T13 and T16                             |
| `worker` (T10) uses `main-cheap`, but did not depend on T02                                                    | Dependency added                                           |
| V7 check could be passed by a fallback                                                                         | `disable_fallbacks` added, as the gateway doc requires     |
| `#hermes-renovate` was missing from the channels that need no mention, so thread replies might be ignored      | T10 adds it                                                |
| T17 kept a note on old profiles; the spec removes them from docs                                               | Note dropped                                               |
| Classic protection details answer 403 without admin rights, so T08 had no working query for required checks    | T08 reads `branches/<default>`, tested on two repositories |
| `containers` and `argocd-secret-replacer` already have a CODEOWNERS line                                       | T16 replaces it                                            |
| The label workflow did not state its permissions                                                               | REST label endpoints and `pull-requests: write`            |
| Decisions from other Discord users were not excluded in the skills                                             | T12 rule added                                             |
| `cron_mode: deny` might block the merge command, which report-only runs cannot reveal                          | T19 stop condition added                                   |
| Placeholders and unclear text: ReplicationSource name, branch for evidence, garbled T07 line, build actor      | Fixed; evidence branch rule in the `tasks.md` header       |
| T11 claimed V9, which T10 runs; `terraform validate` needs `init`; profile must exist before its overlay lands | Corrected                                                  |

Also checked, no change needed: the Argo CD StatefulSet name, the LiteLLM pod label, the template's parameter names and size
default, and that no repository other than home-ops reserves merging in its `AGENTS.md`.

Limits: Hermes configuration keys are unverified until V9, and T15 and T16 behaviour is checked only when they run. No task
was executed.
