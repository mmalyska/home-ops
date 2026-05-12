# WoW Server — Solo Modules Plan

> **Cross-session context**: Self-contained. Load at the start of any new session working on this.

---

## Context

The WoW server (AzerothCore WoTLK 3.3.5a) is fully deployed and running. The original
module set (mod-solocraft, mod-ah-bot, mod-individual-progression) has been replaced with
a better solo-play set. The image build commit is already pushed to `mmalyska/containers`;
this plan tracks the remaining home-ops work.

**User decisions confirmed:**
- Add: **mod-transmog**, **mod-solo-lfg**
- Remove: **mod-individual-progression** (user wants free content access, no gating)
- Keep: **mod-solocraft**, **mod-ah-bot**
- Bots deferred: all bot systems require a custom AC fork; user wants **npc-bots via
  `trickerer/AzerothCore-wotlk-with-NPCBots`** in a future session when ready to commit to
  that fork change

**Why individual-progression was removed safely:** its SQL was never applied (no tables
found in any database), so removal has zero DB impact.

---

## What Was Already Done

### `mmalyska/containers` repo (commit `34f2f1e`, pushed 2026-05-12)
- `apps/azerothcore-worldserver/Dockerfile` — swapped `mod-individual-progression` for
  `mod-transmog` + `mod-solo-lfg` in the cmake module clones
- `apps/azerothcore-db-import/Dockerfile` — swapped to clone `mod-transmog` only
  (mod-solo-lfg is code-only, no SQL)
- `apps/azerothcore-db-import/import-with-modules.sh` — replaced individual-progression
  SQL block with mod-transmog (db-auth, db-characters, db-world)

### `mmalyska/home-ops` repo
- `cluster/apps/games/wow/README.md` — updated module list; added transmog/solo-lfg usage
  notes; added future npc-bots note (commit `df8923d9`)

---

## Remaining Work

### 1. Bump image digests (after CI publishes new images)

CI in `mmalyska/containers` triggers on the `34f2f1e` commit. Once it completes:

- Update `controllers.worldserver.containers.worldserver.image.tag` in
  `cluster/apps/games/wow/values.yaml`
- Update the db-import image tag in `cluster/apps/games/wow/templates/db-import-job.yaml`

### 2. Verify module SQL applied correctly after ArgoCD sync

After sync, the db-import PostSync job runs with the new image and applies transmog SQL.
Verify:
```bash
kubectl exec -n wow statefulset/mysql -- bash -c '
  mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW TABLES FROM acore_world LIKE \"%transmog%\";"'
```

### 3. In-game verification

- Find Transmogrifier NPC (Orgrimmar/Stormwind) — confirms mod-transmog active
- Open LFG tool (I key), queue solo — confirms mod-solo-lfg active
- Confirm mod-individual-progression is gone from worldserver logs:
  `kubectl logs -n wow deploy/wow-worldserver | grep -i individual`

---

## Module SQL Paths (verified)

| Module | SQL paths in import script | Status |
|---|---|---|
| mod-ah-bot | `data/sql/db-world/` | ✅ Applied — 3 rows in `mod_auctionhousebot` |
| mod-solocraft | `data/sql/db-world/`, `data/sql/db-characters/` | ✅ Applied — `custom_solocraft_character_stats` exists |
| mod-individual-progression | `data/sql/world/base+updates/`, `auth/updates/`, `characters/updates/` | ❌ Never applied — paths didn't match repo layout |
| mod-transmog | `data/sql/db-auth/`, `data/sql/db-characters/`, `data/sql/db-world/` | Pending — new image not yet deployed |
| mod-solo-lfg | (none — code-only module) | N/A |

---

## Future: npc-bots

When the user is ready to add bots:
- Switch worldserver build base to `trickerer/AzerothCore-wotlk-with-NPCBots` (pre-patched
  AzerothCore fork, updated weekly)
- mod-autobalance **cannot** be used alongside npc-bots (known conflict Issue #208); keep
  mod-solocraft for difficulty scaling
- npc-bots SQL lives in the fork source under `sql/` — verify paths before writing
  db-import Dockerfile
