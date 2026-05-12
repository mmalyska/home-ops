# WoW Modules — Tasks

> Context: Adding mod-transmog + mod-solo-lfg, removing mod-individual-progression.
> Image build already pushed to `mmalyska/containers` (commit `34f2f1e`).
> Full plan: [plan.md](plan.md)

---

- [x] Update `mmalyska/containers` worldserver Dockerfile — swap individual-progression for transmog + solo-lfg
- [x] Update `mmalyska/containers` db-import Dockerfile — swap to mod-transmog (solo-lfg has no SQL)
- [x] Update `import-with-modules.sh` — replace individual-progression SQL block with transmog
- [x] Push containers repo changes and trigger CI build
- [x] Update `cluster/apps/games/wow/README.md` — new module list + future bots note
- [x] Wait for CI to publish new image digests to `ghcr.io/mmalyska/` — bendo-bot PR #3870 merged (commit 4f1648d0)
- [x] Bump worldserver image digest in `cluster/apps/games/wow/values.yaml` — updated to `ee45ea5b...` by PR #3870
- [x] Bump db-import image digest in `cluster/apps/games/wow/templates/db-import-job.yaml` — updated to `6a1c44632b...` by PR #3870
- [x] Commit + push digest bumps — merged via PR #3870
- [x] Verify transmog tables in DB — `custom_transmogrification` + `custom_transmogrification_sets` exist in `acore_characters`
- [x] Verify mod-transmog loaded on worldserver — `transmog.conf` loaded, appearance cache loaded
- [x] Verify mod-solo-lfg loaded on worldserver — `SoloLfg.conf` loaded, 22 LFG entrances, 15 dungeon rewards
- [x] Verify mod-individual-progression absent from worldserver logs — confirmed absent
- [x] Verify in-game: spawned Transmogrifier NPC (`.npc add 190010`), confirmed transmog UI works; queued and entered dungeon solo via LFG as lvl 80 — mod-solo-lfg confirmed working
