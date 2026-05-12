# WoW WotLK Server — Tasks

> Context: AzerothCore WotLK 3.3.5a single-player server on home-ops cluster.  
> Full plan: [plan.md](plan.md) — includes architecture, YAML templates, cluster context.  
> IP: `192.168.48.29`, namespace: `wow`, storage: `ceph-block`.

---

## Phase 1 — Custom Docker Images (`mmalyska/containers` repo)

- [x] `apps/azerothcore-worldserver/` — multi-stage Dockerfile: build with mod-solocraft, mod-ah-bot, mod-individual-progression; runtime from `acore/ac-wotlk-worldserver:master`
- [x] `apps/azerothcore-authserver/` — thin wrapper `FROM acore/ac-wotlk-authserver:master`
- [x] `apps/azerothcore-db-import/` — base `acore/ac-wotlk-db-import:master` + copy module SQL files from all 3 modules
- [x] CI passes and all 3 images publish to `ghcr.io/mmalyska/`

## Phase 2 — Cluster App (`cluster/apps/games/wow/`)

- [x] Create 2 Bitwarden secrets (MySQL root password + acore user password), note UUIDs for `mysql-externalsecret.yaml`
- [x] `app-config.yaml` — namespace `wow`, selfHeal true, prune false, SECRET_PROVIDER plugin enabled
- [x] `Chart.yaml` — bjw-s common v5 dependency
- [x] `values.yaml` — authserver + worldserver + adminer controllers; authserver + worldserver as LoadBalancer on `192.168.48.29` with `lbipam.cilium.io/sharing-key: wow`; adminer as ClusterIP; client-data init container on worldserver; persistence for client-data PVC; sync waves 4 on game servers
- [x] `templates/mysql-statefulset.yaml` — MySQL 8.4, env from `wow-mysql-secret`, initdb script for `acore_world` + `acore_characters` DBs, liveness probe; sync wave 2
- [x] `templates/mysql-service.yaml` — ClusterIP service named `mysql`
- [x] `templates/mysql-pvc.yaml` — 10Gi ceph-block PVC named `wow-mysql`
- [x] `templates/client-data-pvc.yaml` — 40Gi ceph-block PVC named `wow-client-data`
- [x] `templates/db-import-job.yaml` — Sync hook (wave 3) ArgoCD Job; init container waits for MySQL; runs `azerothcore-db-import` image
- [x] `templates/mysql-externalsecret.yaml` — ExternalSecret from ClusterSecretStore `bitwarden`; creates `wow-mysql-secret` with root + acore passwords; sync wave 1
- [x] `templates/adminer-httproute.yaml` — HTTPRoute on `envoy-internal`
- [x] `templates/dns-endpoint.yaml` — DNSEndpoint `wow.<secret:private-domain>` → `192.168.48.29`
- [x] `templates/volsync.yaml` — ExternalSecret for restic credentials + ReplicationSource for `wow-mysql` PVC
- [x] Pin new worldserver image digest in `values.yaml` after boost-fix CI build completes
- [x] `README.md` — client setup, first-time account creation, AHBot setup, day-to-day ops, backup/DR
- [x] Open and merge cluster PR (`feat/wow-server`)

## Phase 3 — Post-Deploy Manual Steps

- [x] Create in-game admin account: `account create admin <password>` + `account set gmlevel admin 3 -1` via worldserver console (`kubectl exec -n wow deploy/wow-worldserver -it -- bash`)
- [x] Create AHBot account + character ingame (`ahbot` account, `Auctioneer` character); run setup SQL; update `mod_ahbot.conf` with account + GUID
- [x] Update realmlist DB entry: `UPDATE realmlist SET address='192.168.48.29' WHERE id=1;` in `acore_auth`
- [x] Configure WoW 3.3.5a client `realmlist.wtf`: `set realmlist wow.<private-domain>`
- [x] Verify all three modules load in worldserver logs (grep `mod-solocraft`, `mod-ah-bot`, `mod-individual-progression`)
- [x] Confirm backup works (changed from Volsync ReplicationSource to mysql dump + restic upload)
