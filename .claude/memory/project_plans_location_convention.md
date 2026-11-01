---
name: project-plans-location-convention
description: "Where plans live: .plans/<slug>/ (plan.md + tasks.md) for every harness; finished plans move verbatim to .archive/.plans/ (history, not instructions); .plans/superpowers/ is legacy"
metadata:
  node_type: memory
  type: project
  originSessionId: 53b99d55-4515-45c2-96f6-816184aba86e
---

New plans live in `.plans/<slug>/` (`plan.md` with front matter, `tasks.md`), with a row per plan in `.plans/list.md`, whichever harness or technique wrote them. Finished or dropped plans move verbatim to `.archive/.plans/` and get a row in `.archive/.plans/list.md`; superpowers-era specs and plans sit in `.archive/.plans/superpowers/{specs,plans,research}/` and stay there because live docs link to them. The rule and procedure are in `.plans/README.md`; `.agents/bin/check-plans` checks them.

**Why:** the superpowers skills were adopted after the `.plans/{name}/` convention, so plans had drifted into `docs/superpowers/` and an extra `docs/superpowers/archive/`. On 2026-10-20 everything finished was archived and the active ones moved under `.plans/superpowers/` so plans have one home. On 2026-11-01 the hybrid AI workflow plan made `.plans/<slug>/` the single neutral form (Superpowers is a technique provider, not the owner), so `.plans/superpowers/` is legacy and not recreated.

**How to apply:** when `superpowers:brainstorming` / `superpowers:writing-plans` default to `docs/superpowers/` or `.plans/superpowers/`, write to `.plans/<slug>/` instead. When a plan is done or dropped, follow "Archive after Ship" in `.plans/README.md`: move the folder, rewrite links by path replace, update both `list.md` files. Text under `.archive/` is history, never instructions. See [[feedback_update_docs]].
