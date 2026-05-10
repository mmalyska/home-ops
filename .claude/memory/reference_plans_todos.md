---
name: Plans and TODOs location
description: Where to find implementation plans, tasks, and ad-hoc TODO items in the home-ops repo
type: reference
originSessionId: a742ffea-1464-49ac-b0ef-da200ae16541
---
## Active plans

- `.plans/list.md` — index of all active plans (one line per plan)
- `.plans/{plan-name}/plan.md` — full context, decisions, architecture; enough detail for a new session to continue
- `.plans/{plan-name}/tasks.md` — self-contained checkbox task list; executable without reading plan.md

## Completed plans

- `.archive/.plans/list.md` — index of all completed plans
- `.archive/.plans/{plan-name}/` — same structure as active plans, kept as read-only history

## Ad-hoc backlog

- `.plans/TODO.md` — Claude's scratchpad for out-of-scope ideas worth doing later; not modified by the plan workflow
