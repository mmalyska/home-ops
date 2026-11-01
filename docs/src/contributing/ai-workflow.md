# AI workflow in home-ops

How this repository applies the AI-assisted workflow: where the rules live, how to start a session, what is enforced and
what is only an instruction. A person should be able to onboard from this page alone.

Links to files outside the documentation site point at the `main` branch on GitHub.

## 1. What this page is and is not

This page is the **local application** of the workflow in `home-ops`, owned by this repository. It does not define the
workflow. The lifecycle, the process levels, the topologies and the plan, handoff and decision resources are owned by the
`mmalyska/claude-plugins` repository and are pinned here to the tag
[`ai-workflow-v0.1.0-preview.1`](https://github.com/mmalyska/claude-plugins/tree/ai-workflow-v0.1.0-preview.1). Read them
there; this page never restates them. The pin and the procedure to bump it are in
[`.agents/README.md`](https://github.com/mmalyska/home-ops/blob/main/.agents/README.md).

A process level never lowers a safety, permission, worktree or validation requirement, and no level authorizes another
actor. A general guide for adopting the workflow in any repository is planned in `claude-plugins`; it does not exist yet,
so it is not linked.

## 2. Where rules live

| Where                                                                              | Holds                                                                          |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [`AGENTS.md`](https://github.com/mmalyska/home-ops/blob/main/AGENTS.md)            | The shared, harness-neutral rules. Canonical; every harness reads it           |
| [`CLAUDE.md`](https://github.com/mmalyska/home-ops/blob/main/CLAUDE.md)            | Thin Claude Code adapter: imports `AGENTS.md`, adds Claude-only facts          |
| [`.agents/`](https://github.com/mmalyska/home-ops/tree/main/.agents)               | Adapter contract, policy files, scripts and the instruction tests              |
| [`.agents/skills/`](https://github.com/mmalyska/home-ops/tree/main/.agents/skills) | The project skills (domain procedures), canonical and the only place to edit   |
| [`.plans/`](https://github.com/mmalyska/home-ops/tree/main/.plans)                 | Active plans; finished plans move to `.archive/.plans/`                        |
| [`.claude/`](https://github.com/mmalyska/home-ops/tree/main/.claude)               | Claude Code data: settings, the generated `skills/` mirror, memory, statusline |

`.claude/skills/` is generated from `.agents/skills/` by `.agents/bin/sync-skills`, and CI fails when the two differ. Memory
files in `.claude/memory/` are dated notes: read the relevant one when it applies and verify it against the code and the
live state. A rule has a home in `AGENTS.md` or under `.agents/`, never only in memory. `.archive/` is history, not
instructions.

## 3. Onboarding

| Harness     | What is verified                                                                                                                             | What is not                                                                                                                                          |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Code | Loads `CLAUDE.md` and the `@AGENTS.md` import (N1). Project skills are visible. Permission rules and a write guard are technical enforcement | A directory symlink for `.claude/skills` (N6): not needed, the mirror is used                                                                        |
| Codex       | Reads `AGENTS.md` (N2) and discovers skills in `.agents/skills` (N3). A project rule file forbids skipping git hooks                         | Write guard in the primary checkout (instruction only); hook trust (N4); sandbox git writes in a linked worktree need user-level writable roots (N5) |
| OpenCode    | Nothing. Placeholder: read `AGENTS.md`, run the preflight by hand before the first write. No parity claim                                    | Everything                                                                                                                                           |

The IDs (N1 to N10) and the dated results are in the
[evidence file](https://github.com/mmalyska/home-ops/blob/main/.plans/hybrid-ai-workflow/evidence.md). A claim without a
result there is not verified. Windows checkout behaviour of repository symlinks (N10) is not verified either, which is why
the repository carries no symlink for skills.

To start: clone, open the devcontainer, run `pre-commit install` once (it also installs the commit-message hook), and ask
the agent to work in a worktree as described next.

## 4. Worktree-first

Work in a linked worktree, never in the primary checkout, which stays on `main` with a clean tree.

```sh
git worktree add .worktrees/<type>/<slug> -b <type>/<slug> origin/main
.agents/bin/worktree-preflight        # 0 = go, 3 = stop and create a worktree, 4 = could not tell (treat as stop)
```

`<type>` is `feat`, `fix`, `chore` or `docs`. What enforces the rule depends on the harness:

| Layer                              | Covers                                                            |
| ---------------------------------- | ----------------------------------------------------------------- |
| `AGENTS.md` rule and the preflight | Every harness; a model instruction                                |
| Claude project hook                | Claude file tools and common bypass commands, as a technical stop |
| `pre-commit` hook `worktree-first` | A commit from any harness in the primary checkout or on `main`    |
| CI and review                      | What reaches `main`                                               |

No layer stops a Codex edit in the primary checkout before it is committed. Break-glass (`HOME_OPS_BREAK_GLASS` with a
reason) is for a person at a terminal. An agent never sets it, never uses `--no-verify`, and never works around a denied
write.

## 5. Plans

A plan is a folder `.plans/<slug>/` with `plan.md` (front matter, goal, decisions, status) and `tasks.md` (self-contained
tasks). Each active plan has one row in `.plans/list.md`. When a plan ships or is dropped, a small `chore(plans)` PR moves it
to `.archive/.plans/`. Archived plans are history and are not followed as instructions. Run `.agents/bin/check-plans` after
touching `.plans/`. Layout, front matter and the archive procedure are in
[`.plans/README.md`](https://github.com/mmalyska/home-ops/blob/main/.plans/README.md). A plan never authorizes an action.

## 6. Validation

Every change type has a row in the
[validation matrix](https://github.com/mmalyska/home-ops/blob/main/.agents/policy/validation.md): what to run locally (L0),
what CI runs (L1), what can be checked read-only on the live cluster (L2) and what needs consent (L3). Report each check as
`PASS`, `FAIL`, `NOT RUN` (with the reason) or `N/A`. A check that was not executed is `NOT RUN`, even when it is expected to
pass; a tool missing locally and covered by CI is `NOT RUN: not installed locally, covered by CI`.

The PR description has a Validation table with one row per check and an Impact line. Read it as follows: a green CI run is
L1 evidence only; `task lint:*` always exits 0, so read its output; an L3 row without consent is `NOT RUN`.

## 7. Permission boundaries

Every action has a class: read, local check, repository write, delivery, secret access, GitOps trigger, runtime mutation,
destructive. The command lists are in the
[permission matrix](https://github.com/mmalyska/home-ops/blob/main/.agents/policy/permissions.md). Consent comes from the user
in the current session, names the action, the target and the effect, and covers that action once. Approving a plan or a PR
does not approve the next mutation.

A valid consent request for a runtime change:

> I will run `kubectl delete application <app> -n argocd`. Effect: the Application and everything ArgoCD applied for it is
> removed; PVCs created by a StatefulSet are not. Rollback: re-enable the app in git and sync. Do you approve this one
> command?

A valid impact statement before a merge, for a PR that changes `cluster/apps/<category>/<app>/`:

> Merging deploys. Paths: `cluster/apps/<category>/<app>/`. ArgoCD auto-syncs that Application (prune on or off, state which).
> No Terraform apply, no tuppr change. Rollback: revert PR, then a sync. Do you approve the merge of PR `#<number>`?

A merge is a production operation: `main` is what ArgoCD and HCP Terraform apply. Merging a change under `docs/` publishes
the public site.

## 8. Handoff

When work moves to another session or person, leave a note in `.plans/<slug>/handoff.md` with: the state (what is done and
verified), the base SHA, the branch, the worktree path, the next task, the open questions, and every `NOT RUN` item with its
reason. The note is text and authorizes nothing. The handoff shape and the topologies that use it are defined in
[`claude-plugins`](https://github.com/mmalyska/claude-plugins/tree/ai-workflow-v0.1.0-preview.1) at the pinned tag.

## 9. Troubleshooting

| Symptom                                        | Cause and fix                                                                                                                                                  |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The guard blocks a write                       | The target is in the primary checkout. Create a worktree and repeat the write there. Do not look for a way around the guard                                    |
| A hook does not run in a new worktree          | Hooks are installed per clone: run `pre-commit install` once. Check with `.agents/bin/worktree-preflight`                                                      |
| `@AGENTS.md` is not loaded                     | Claude Code only: `CLAUDE.md` must contain the line `@AGENTS.md`. `bash .agents/tests/run.sh` checks it. Other harnesses read `AGENTS.md` directly             |
| A skill is not discovered                      | Skills live in `.agents/skills/<name>/SKILL.md`. For Claude Code run `.agents/bin/sync-skills`; `sync-skills --check` shows the drift                          |
| `pre-commit` blocks on attribution or gitleaks | Fix the cause: remove the attribution line or the secret. Never use `--no-verify`, `SKIP=` or `core.hooksPath`                                                 |
| `check-plans` reports an error                 | Read the `ERROR <path>: <message>` line; the front matter and the index row must agree (see `.plans/README.md`)                                                |
| `Docs build` fails in CI                       | The strict MkDocs build found a broken nav entry, link or extension. Read the warning in the job log, fix the page, and keep relative links inside `docs/src/` |

Placeholders in examples (`<app>`, `<type>`, `<slug>`, `example.invalid`) stand for real values that are never written on
this public site: no private domain, hostname, address or identifier.
