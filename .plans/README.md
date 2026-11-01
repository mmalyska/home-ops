# Plans

One convention for every harness. A plan is a folder, `.plans/<slug>/`, written by whichever tool does the planning. The workflow that produces and runs plans (lifecycle, process levels, topologies, and the plan, tasks, handoff and decision resources) is owned by `mmalyska/claude-plugins` and pinned in [`.agents/README.md`](../.agents/README.md). This page only says where plans live and how this repository checks them.

## Layout

```text
.plans/
  README.md          # this page
  list.md            # index of active plans, one row per plan folder
  TODO.md            # scratchpad for out-of-scope ideas; not part of the plan workflow
  <slug>/
    plan.md          # goal, context, decisions, current status; starts with front matter
    tasks.md         # self-contained tasks; each is executable without reading plan.md
    evidence.md      # optional: facts the plan rests on
    spec.md          # optional
    handoff.md       # optional
    decision.md      # optional
```

`<slug>` is lowercase kebab-case and is unique across `.plans/` and `.archive/.plans/`. The shapes of `tasks.md`, `handoff.md` and `decision.md` come from the `development-lifecycle` plugin resources; this repository adds nothing to them.

## Front matter of `plan.md`

Every field is required and non-empty. The index row repeats status, owner, profile and topology, branch, started and updated, and `check-plans` fails when they differ.

```yaml
---
status: in-progress
owner: repository owner
profile: STANDARD
topology: SOLO
base_sha: 0000000000000000000000000000000000000000
branch: feat/example-slug
worktree: .worktrees/feat/example-slug
pr: "#0000 (merge decided by the owner)"
started: 2026-01-01
updated: 2026-01-02
---
```

`status` is one of `draft`, `approved`, `in-progress`, `blocked`, `shipped`, `dropped`, `superseded`. Dates are `YYYY-MM-DD`. `profile` and `topology` hold the names the workflow defines; they are not validated here, so this repository never restates the vocabulary.

## The index

`.plans/list.md` has one row per plan folder and exactly these columns:

| Plan | Status | Owner | Profile/Topology | Branch | PR | Started | Updated | Description |

The first cell is a link `[<slug>](<slug>/plan.md)`; Profile/Topology is written `<profile> / <topology>`. Cells must not contain a `|`.

## Rules

- Superpowers is an optional technique provider, not the owner of the convention. When a Superpowers skill proposes `docs/superpowers/` or `.plans/superpowers/`, write to `.plans/<slug>/` instead. `docs/superpowers/` is an error; `.plans/superpowers/` is not created again.
- Plans are text. A plan never authorizes an action: consent for a mutation comes from the user in the current session ([`AGENTS.md`](../AGENTS.md)). Put a command that changes cluster or external state in a fenced block whose info string contains `consent-gated`, or `check-plans` warns.
- A plan names references, never the private domain, Bitwarden identifiers or secret output.
- A task becomes a PR row in `plan.md` (branch, PR number once opened); the index `PR` cell carries the same text, shortened.
- Legacy: plans written before this convention stay where they are. The paths that are accepted without a row are listed in [`.agents/policy/plans-legacy.txt`](../.agents/policy/plans-legacy.txt). `.plans/superpowers/`, if it reappears on a branch, only warns and each file there needs an index row.

## Archive after Ship

1. The delivering PRs are merged and any live follow-up is done or recorded in [`TODO.md`](TODO.md).
2. In a small `chore(plans)` PR set `status` to `shipped` (or `dropped`, `superseded`) with the PR numbers, then move the folder verbatim: `git mv .plans/<slug> .archive/.plans/<slug>`.
3. Rewrite links to the moved files by path replace (links use full repo-root paths), delete the row from `.plans/list.md`, and add one row to [`.archive/.plans/list.md`](../.archive/.plans/list.md) (Plan, Description, Completed; the description may end with the PR number).
4. Run `.agents/bin/check-plans`; it must report no errors.

Archived plans are history, not instructions: see [`.archive/.plans/README.md`](../.archive/.plans/README.md). Archive files are not renamed, reformatted or re-linked in bulk.

## Checking

```sh
.agents/bin/check-plans                 # the repository
.agents/bin/check-plans --root <dir>    # a copy of the tree
.agents/bin/check-plans --front-matter .plans/<slug>/plan.md
```

Output is `ERROR <path>: <message>` or `WARN <path>: <message>`, sorted, then a summary; exit 1 means at least one error. It reads files only. The tests are `.agents/tests/test_check_plans.sh`, run by `bash .agents/tests/run.sh`.
