# WoW WotLK Server — Tasks

> Context: AzerothCore WotLK 3.3.5a single-player server on home-ops cluster.  
> Full plan: [plan.md](plan.md) — includes architecture, YAML templates, cluster context.  
> IP: `192.168.48.29`, namespace: `wow`, storage: `ceph-block`.

---

## Phase 1 — Custom Docker Images (`mmalyska/containers` repo)

- [ ] `apps/azerothcore-worldserver/` — multi-stage Dockerfile: build with mod-solocraft, mod-ah-bot, mod-individual-progression; runtime from `acore/ac-wotlk-worldserver:master`
- [ ] `apps/azerothcore-authserver/` — thin wrapper `FROM acore/ac-wotlk-authserver:master`
- [ ] `apps/azerothcore-db-import/` — base `acore/ac-wotlk-db-import:master` + copy module SQL files from all 3 modules
- [ ] CI passes and all 3 images publish to `ghcr.io/mmalyska/`

## Phase 2 — Cluster App (`cluster/apps/games/wow/`)

- [ ] Create 2 Bitwarden secrets (MySQL root password + acore user password), note UUIDs for `mysql-externalsecret.yaml`
- [ ] `app-config.yaml` — namespace `wow`, selfHeal true, prune false, SECRET_PROVIDER plugin enabled
- [ ] `Chart.yaml` — bjw-s common v5 dependency
- [ ] `values.yaml` — authserver + worldserver + adminer controllers; authserver + worldserver as LoadBalancer on `192.168.48.29`; adminer as ClusterIP; client-data init container on worldserver; persistence for client-data PVC
- [ ] `templates/mysql-statefulset.yaml` — MySQL 8.4, env from `wow-mysql-secret`, initdb script for `acore_world` + `acore_characters` DBs, liveness probe
- [ ] `templates/mysql-service.yaml` — ClusterIP service named `mysql`
- [ ] `templates/mysql-pvc.yaml` — 10Gi ceph-block PVC named `wow-mysql`
- [ ] `templates/client-data-pvc.yaml` — 40Gi ceph-block PVC named `wow-client-data`
- [ ] `templates/db-import-job.yaml` — PostSync ArgoCD hook Job; init container waits for MySQL; runs `azerothcore-db-import` image
- [ ] `templates/mysql-externalsecret.yaml` — ExternalSecret from ClusterSecretStore `bitwarden`; creates `wow-mysql-secret` with root + acore passwords
- [ ] `templates/adminer-httproute.yaml` — HTTPRoute on `envoy-internal`, hostname `wow-adminer.<secret:private-domain>`
- [ ] `templates/dns-endpoint.yaml` — DNSEndpoint `wow.<secret:private-domain>` → `192.168.48.29`, controller `internal`
- [ ] `templates/volsync.yaml` — ExternalSecret for restic credentials (reuse 4 shared Bitwarden UUIDs from plan.md) + ReplicationSource for `wow-mysql` PVC, schedule `0 */12 * * *`
- [ ] `README.md` — client setup, first-time account creation, AHBot setup, day-to-day ops, backup/DR

## Phase 3 — Post-Deploy Manual Steps

- [ ] Create in-game admin account: `account create admin <password>` + `account set gmlevel admin 3 -1` via worldserver console (`kubectl exec -n wow deploy/wow-worldserver -it -- bash`)
- [ ] Create AHBot account + character ingame (`ahbot` account, `Auctioneer` character); run setup SQL; update `mod_ahbot.conf` with account + GUID
- [ ] Update realmlist DB entry: `UPDATE realmlist SET address='192.168.48.29' WHERE id=1;` in `acore_auth`
- [ ] Configure WoW 3.3.5a client `realmlist.wtf`: `set realmlist wow.<private-domain>`
- [ ] Verify all three modules load in worldserver logs (grep `mod-solocraft`, `mod-ah-bot`, `mod-individual-progression`)
- [ ] Confirm Volsync first backup completes: `kubectl get replicationsource -n wow`
