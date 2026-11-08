# Plans

One convention for every harness. A plan is a folder, `.plans/<slug>/`, written by whichever tool does the planning. The workflow that produces and runs plans (lifecycle, process levels, topologies, and the plan, tasks, handoff and decision resources) is owned by `mmalyska/claude-plugins`, see [`.agents/README.md`](../.agents/README.md). This page only says where plans live and how this repository checks them.

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
    spec.md          # optional; the only required file until the plan is written
    handoff.md       # optional
    decision.md      # optional
```

`<slug>` is lowercase kebab-case and is unique across `.plans/` and `.archive/.plans/`. The shapes of `tasks.md`, `handoff.md` and `decision.md` come from the `development-lifecycle` plugin resources; this repository adds nothing to them.

A spec can be reviewed before its plan exists: the folder then holds `spec.md` alone, with no front matter and no row in the index. Adding the plan adds `plan.md` with its front matter, `tasks.md` and the row.

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
pr: not-opened
started: 2026-01-01
updated: 2026-01-02
---
```

`status` is one of `draft`, `approved`, `in-progress`, `blocked`, `shipped`, `dropped`, `superseded`. Dates are `YYYY-MM-DD`. `pr` is `not-opened` until the PR exists, then the PR number (`"#1234"`, quoted because `#` starts a YAML comment) or URL; several PRs are separated by `, `. Anything else is an error. `profile` and `topology` hold the names the workflow defines; they are not validated here, so this repository never restates the vocabulary.

## The index

`.plans/list.md` has one row per plan folder that holds a plan, and exactly these columns:

| Plan | Status | Owner | Profile/Topology | Branch | PR | Started | Updated | Description |

The first cell is a link `[<slug>](<slug>/plan.md)`; Profile/Topology is written `<profile> / <topology>`. Cells must not contain a `|`.

## Rules

- Superpowers is an optional technique provider, not the owner of the convention. When a Superpowers skill proposes `docs/superpowers/` or `.plans/superpowers/`, write to `.plans/<slug>/` instead. `docs/superpowers/` is an error; `.plans/superpowers/` is not created again.
- Plans are text. A plan never authorizes an action: consent for a mutation comes from the user in the current session ([`AGENTS.md`](../AGENTS.md)). Put a command that changes cluster or external state in a fenced block whose info string contains `consent-gated`, or `check-plans` warns.
- A plan names references, never the private domain, Bitwarden identifiers or secret output.
- `pr` lifecycle: a plan is written with `pr: not-opened` and the index `PR` cell `—`. After the PR is opened, set `pr` to the number or URL in `plan.md` and the same text in the index, in the same branch. `check-plans` rejects an empty or free-text `pr` and any index cell that differs.
- Legacy: plans written before this convention stay where they are. The paths that are accepted without a row are listed in [`.agents/policy/plans-legacy.txt`](../.agents/policy/plans-legacy.txt). `.plans/superpowers/`, if it reappears on a branch, only warns and each file there needs an index row.

## Extract knowledge before archiving

Archived text is history that agents are told not to follow, so anything still useful must leave it first. Before a plan or TODO item is archived, read it for:

- **A finding or method that a later task will need** (measurements, causes, rejected options and why, a procedure that worked): write it into the doc for that area under `docs/`, and link the archive path as the source.
- **A gotcha that applies beyond this one change**: add it to the skill for that area in `.agents/skills/`, then run `.agents/bin/sync-skills`.
- **A domain context needed in 2 or more sessions** with no skill yet: ask the owner whether to create one ("Skills" in `AGENTS.md`); do not create it unasked.
- **A non-obvious fact about the owner's setup or preferences**: a memory note in `.claude/memory/`.

Record the outcome in the archive PR description: what was extracted and where, or "nothing worth extracting". Do not copy whole items; the doc states the lesson, the archive keeps the history.

## Archive after Ship

1. The delivering PRs are merged and any live follow-up is done or recorded in [`TODO.md`](TODO.md).
2. Do "Extract knowledge before archiving" above.
3. In a small `chore(plans)` PR set `status` to `shipped` (or `dropped`, `superseded`) with the PR numbers, then move the folder verbatim: `git mv .plans/<slug> .archive/.plans/<slug>`.
4. Rewrite links to the moved files by path replace (links use full repo-root paths), delete the row from `.plans/list.md`, and add one row to [`.archive/.plans/list.md`](../.archive/.plans/list.md) (Plan, Description, Completed; the description may end with the PR number).
5. Run `.agents/bin/check-plans`; it must report no errors.

Archived plans are history, not instructions: see [`.archive/.plans/README.md`](../.archive/.plans/README.md). Archive files are not renamed, reformatted or re-linked in bulk.

## Archive a TODO item

`TODO.md` holds open items only. Move an item out when it is done, or postponed or dropped by a decision of the owner.

1. Do "Extract knowledge before archiving" above.
2. Append the item verbatim to [`.archive/TODO.md`](../.archive/TODO.md) under a `## Moved <date>` heading (a new heading per move, newest last). Say in one sentence per heading what was done and what was postponed or dropped; do not rewrite the item.
3. A done parent with open children: archive the parent with its done children, and keep each open child in `TODO.md` as its own top-level item that names the archive file.
4. Update the "Last reviewed" date at the top of `TODO.md`.
5. Run `.agents/bin/check-plans`; it must report no errors. It does not read `TODO.md`, so check by eye that no open item was moved.

## Checking

```sh
.agents/bin/check-plans                 # the repository
.agents/bin/check-plans --root <dir>    # a copy of the tree
.agents/bin/check-plans --front-matter .plans/<slug>/plan.md
```

Output is `ERROR <path>: <message>` or `WARN <path>: <message>`, sorted, then a summary; exit 1 means at least one error. It reads files only.
