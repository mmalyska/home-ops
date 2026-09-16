---
name: project-plans-location-convention
description: "Where plans actually go in practice — docs/superpowers/, not the .plans/ folder CLAUDE.md documents"
metadata:
  node_type: memory
  type: project
  originSessionId: 53b99d55-4515-45c2-96f6-816184aba86e
---

CLAUDE.md documents a `.plans/{name}/plan.md` + `tasks.md` + `.plans/list.md` convention, but the three most recent real plans in this repo (rabbitmq-operator, nextcloud-onedrive-replacement, coder-sandbox, and dragonfly-operator as of 2026-07-08) all live under `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` and `docs/superpowers/plans/YYYY-MM-DD-<topic>.md` instead, following the superpowers `brainstorming`/`writing-plans` skills' own default location. `.plans/list.md` is empty (no active entries) despite this ongoing work. Older completed plans (`wow-server`, `cnpg-plugin-migration`, `ai-project`, etc.) do use the `.plans/`-style `plan.md`/`tasks.md` pair, now sitting in `.archive/.plans/`.

**Why:** the superpowers skills were adopted after CLAUDE.md's `.plans/` section was written, and nobody has gone back to reconcile the two documented conventions or backfill `.plans/list.md` for the newer work.

**How to apply:** when starting a new plan via `superpowers:brainstorming`/`superpowers:writing-plans`, follow the `docs/superpowers/specs/` + `docs/superpowers/plans/` convention (matching actual recent precedent), not CLAUDE.md's `.plans/` instructions — don't create parallel/duplicate entries in `.plans/list.md` for skill-driven plans. If the user asks to revise CLAUDE.md's Plans section to match reality, that's a legitimate follow-up (see [[feedback_update_docs]]).
