---
name: project-plans-location-convention
description: "Where plans, specs and archived plans live: .plans/superpowers/ for active superpowers work, .archive/.plans/superpowers/ once finished or dropped"
metadata:
  node_type: memory
  type: project
  originSessionId: 53b99d55-4515-45c2-96f6-816184aba86e
---

Active superpowers specs and plans live in `.plans/superpowers/specs/YYYY-MM-DD-<topic>-design.md` and `.plans/superpowers/plans/YYYY-MM-DD-<topic>.md` (helper files in `.plans/superpowers/plans/artifacts/`), with a row per plan in `.plans/list.md`. Older plan folders (`plan.md` + `tasks.md`) sit in `.archive/.plans/`. Finished or dropped superpowers work is moved verbatim to `.archive/.plans/superpowers/{specs,plans,research}/` and listed in `.archive/.plans/list.md`. CLAUDE.md's Plans section documents all of this.

**Why:** the superpowers skills were adopted after the `.plans/{name}/` convention, so plans had drifted into `docs/superpowers/` and an extra `docs/superpowers/archive/`. On 2026-10-20 everything finished was archived and the active ones moved under `.plans/superpowers/` so plans have one home.

**How to apply:** when `superpowers:brainstorming` / `superpowers:writing-plans` default to `docs/superpowers/`, write to `.plans/superpowers/` instead. When a plan is done or dropped, move its spec, plan and artifacts to `.archive/.plans/superpowers/` and rewrite every link to them (full repo-root paths are used everywhere, so a path replace is enough), then update both `list.md` files. See [[feedback_update_docs]].
