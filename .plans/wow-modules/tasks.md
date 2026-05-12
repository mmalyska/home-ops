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
- [ ] Wait for CI to publish new image digests to `ghcr.io/mmalyska/`
- [ ] Bump worldserver image digest in `cluster/apps/games/wow/values.yaml`
- [ ] Bump db-import image digest in `cluster/apps/games/wow/templates/db-import-job.yaml`
- [ ] Commit + push digest bumps
- [ ] Verify after ArgoCD sync: transmog table exists in DB (`SHOW TABLES FROM acore_world LIKE "%transmog%"`)
- [ ] Verify in-game: Transmogrifier NPC accessible, LFG solo queue works
- [ ] Verify mod-individual-progression absent from worldserver logs
