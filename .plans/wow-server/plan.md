# WoW WotLK Single-Player Server — Implementation Plan

> **Cross-session context**: This plan is self-contained. Load it at the start of any new session working on this feature.

---

## Context & Decisions (from design session 2026-05-09)

**Goal**: Deploy a personal WoW WotLK (3.3.5a) private server to the home-ops Kubernetes cluster for single-player use, accessible on LAN and externally via home router VPN.

**User decisions confirmed**:
- External access: via VPN on home router → LAN IP (no Cloudflare Spectrum needed)
- Database: Dedicated MySQL 8.4 StatefulSet in `wow` namespace
- Individual Progression module: `ZhengPeiRu21/mod-individual-progression`
- DB admin UI: Adminer via `envoy-internal` (internal HTTPS only)
- Backup: Volsync Restic (same pattern as minecraft-bedrock)
- Images: Must be built in `mmalyska/containers` repo, no in-cluster builds

**Server software**: [AzerothCore](https://www.azerothcore.org/) — open-source WotLK server  
**Reference Docker docs**: https://www.azerothcore.org/wiki/install-with-docker

---

## Cluster Context (do not re-research)

**Repository root**: `/workspaces/home-ops/`

**IP pool**: Cilium IPAM `192.168.48.20–50`  
**Used IPs**: .20 (envoy-internal), .21 (envoy-external), .22 (jellyfin), .23 (minecraft), .27 (ollama/ha), .28 (vintagestory)  
**Assign to WoW**: `192.168.48.29`

**Storage class**: `ceph-block` (RWO) — used by all game apps

**Secrets**: Bitwarden via ClusterSecretStore `bitwarden`; tokens in non-injectable fields use `SECRET_PROVIDER: cluster-secrets` plugin

**Backup (Volsync Restic)** — reuse these existing Bitwarden UUIDs (same across all apps):
```
VOLSYNC_RESTIC_REPOSITORY_TEMPLATE  → 39b92426-09c4-4a74-8285-b40a00d62b4d  #gitleaks:allow
VOLSYNC_RESTIC_PASSWORD             → 07d70a7a-a6d9-4b0b-af1f-b40a00d649a9  #gitleaks:allow
VOLSYNC_RESTIC_AWS_ACCESS_KEY_ID    → adb66319-d083-4379-afd5-b40a00d66963  #gitleaks:allow
VOLSYNC_RESTIC_AWS_SECRET_ACCESS_KEY → 70ebd8f2-8270-46d8-8953-b40a00d6854f #gitleaks:allow
```
The Restic repo path suffix is the app name (e.g. `$(REPOSITORY_TEMPLATE)/wow-mysql`).

**Key reference files** (read these before implementing to match patterns exactly):
- `cluster/apps/games/vintagestory/values.yaml` — bjw-s common v5 controller/service/persistence pattern
- `cluster/apps/games/vintagestory/templates/volsync.yaml` — Volsync ExternalSecret + ReplicationSource pattern
- `cluster/apps/games/minecraft-bedrock/templates/volsync.yaml` — alternate Volsync pattern (with Helm labels)
- `cluster/apps/games/minecraft-bedrock/templates/pvc.yaml` — standalone PVC template
- `cluster/apps/games/minecraft-bedrock/app-config.yaml` — app-config with SECRET_PROVIDER plugin
- `cluster/apps/games/vintagestory/Chart.yaml` — bjw-s common v5 chart dependency

**bjw-s common chart**: `version: 5.0.0, repository: https://bjw-s-labs.github.io/helm-charts`  
Schema ref: `https://raw.githubusercontent.com/bjw-s/helm-charts/refs/tags/app-template-3.6.1/charts/other/app-template/values.schema.json`

**HTTPRoute internal pattern** (envoy-internal, AdGuard DNS):
```yaml
parentRefs:
  - name: envoy-internal
    namespace: envoy-gateway
    sectionName: https
annotations:
  external-dns.alpha.kubernetes.io/controller: dns-controller
```

**DNSEndpoint internal-only** (adguard-dns processes `controller: internal`):
```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/controller: internal
```

---

## Architecture

| Component | Kubernetes Kind | Image | Notes |
|---|---|---|---|
| MySQL 8.4 | StatefulSet | `mysql:8.4` | wow namespace, dedicated |
| authserver | Deployment (bjw-s controller) | `ghcr.io/mmalyska/azerothcore-authserver` | Port 3724 TCP |
| worldserver | Deployment (bjw-s controller) | `ghcr.io/mmalyska/azerothcore-worldserver` | Port 8085 + 7878 TCP |
| db-import | Job (manual template) | `ghcr.io/mmalyska/azerothcore-db-import` | PostSync hook, waits for MySQL |
| client-data | Init container on worldserver | `acore/ac-wotlk-client-data:master` | Downloads ~30GB game data to PVC |
| Adminer | Deployment (bjw-s controller) | `adminer:latest` | Port 8080, internal HTTPS |

**WoW modules to compile in** (all must be in `modules/` at build time):
- `https://github.com/azerothcore/mod-solocraft` — dungeon difficulty scaling for solo
- `https://github.com/azerothcore/mod-ah-bot` — auction house bot (buyer + seller)
- `https://github.com/ZhengPeiRu21/mod-individual-progression` — per-player progression

---

## Phase 1 — Custom Docker Images (`mmalyska/containers` repo)

**Pattern to follow**: `apps/vintagestory/` in that repo (Dockerfile + metadata.json + ci/).

### `apps/azerothcore-worldserver/`

**Dockerfile** — multi-stage:
```dockerfile
# Stage 1: build with modules
FROM acore/ac-wotlk-dev:master AS builder
WORKDIR /azerothcore
RUN git clone --depth 1 https://github.com/azerothcore/mod-solocraft modules/mod-solocraft \
 && git clone --depth 1 https://github.com/azerothcore/mod-ah-bot modules/mod-ah-bot \
 && git clone --depth 1 https://github.com/ZhengPeiRu21/mod-individual-progression modules/mod-individual-progression
RUN cmake -S . -B build -DCMAKE_INSTALL_PREFIX=/azerothcore/env/dist \
      -DAPPS_BUILD=worldserver \
      -DSCRIPTS=static -DMODULES=static \
 && cmake --build build --target install -j$(nproc)

# Stage 2: runtime
FROM acore/ac-wotlk-worldserver:master
COPY --from=builder /azerothcore/env/dist/bin/worldserver /azerothcore/env/dist/bin/worldserver
COPY --from=builder /azerothcore/env/dist/etc/modules/ /azerothcore/env/dist/etc/modules/
```

> **Note**: AzerothCore's exact cmake flags need to be verified against their build system. The `acore/ac-wotlk-dev:master` image includes all C++ build dependencies. Adjust if the build system differs — check `https://github.com/azerothcore/azerothcore-wotlk/blob/master/Dockerfile-dev`.

**metadata.json**:
```json
{
  "app": "azerothcore-worldserver",
  "channels": [{ "name": "stable", "platforms": ["linux/amd64"], "stable": true }]
}
```

### `apps/azerothcore-authserver/`

Thin wrapper — exists to pin digest and publish under mmalyska registry:
```dockerfile
FROM acore/ac-wotlk-authserver:master
```

### `apps/azerothcore-db-import/`

Adds module SQL into the import paths:
```dockerfile
FROM acore/ac-wotlk-db-import:master AS builder-solocraft
RUN git clone --depth 1 https://github.com/azerothcore/mod-solocraft /tmp/mod-solocraft
RUN git clone --depth 1 https://github.com/azerothcore/mod-ah-bot /tmp/mod-ah-bot
RUN git clone --depth 1 https://github.com/ZhengPeiRu21/mod-individual-progression /tmp/mod-ipp

FROM acore/ac-wotlk-db-import:master
COPY --from=builder-solocraft /tmp/mod-solocraft/data/sql /azerothcore/data/sql/custom/
COPY --from=builder-solocraft /tmp/mod-ah-bot/data/sql /azerothcore/data/sql/custom/
COPY --from=builder-solocraft /tmp/mod-ipp/data/sql /azerothcore/data/sql/custom/
```

> **Note**: Verify the exact SQL path structure in each module repo before writing the final Dockerfile. Module SQL usually lives under `data/sql/` or `sql/`.

---

## Phase 2 — Cluster App (`cluster/apps/games/wow/`)

### File tree to create

```
cluster/apps/games/wow/
├── README.md
├── app-config.yaml
├── Chart.yaml
├── values.yaml
└── templates/
    ├── mysql-statefulset.yaml
    ├── mysql-service.yaml
    ├── mysql-pvc.yaml
    ├── client-data-pvc.yaml
    ├── db-import-job.yaml
    ├── mysql-externalsecret.yaml
    ├── adminer-httproute.yaml
    ├── dns-endpoint.yaml
    └── volsync.yaml
```

### `app-config.yaml`

```yaml
- enabled: "true"
  namespace: wow
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

### `Chart.yaml`

```yaml
apiVersion: v2
name: wow
type: application
version: 1.0.0
dependencies:
  - name: common
    version: 5.0.0
    repository: https://bjw-s-labs.github.io/helm-charts
```

### `values.yaml` (key sections)

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s/helm-charts/refs/tags/app-template-3.6.1/charts/other/app-template/values.schema.json
---
controllers:
  authserver:
    type: deployment
    replicas: 1
    containers:
      authserver:
        image:
          repository: ghcr.io/mmalyska/azerothcore-authserver
          tag: <TAG>@sha256:<DIGEST>
        env:
          AC_LOGINSERVER__DATABASE__INFO: "mysql;3306;acore;<secret-from-k8s>;acore_auth"
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            memory: 256Mi

  worldserver:
    type: deployment
    replicas: 1
    initContainers:
      client-data:
        image:
          repository: acore/ac-wotlk-client-data
          tag: master
        volumeMounts:
          - name: client-data
            mountPath: /azerothcore/env/dist/data
    containers:
      worldserver:
        image:
          repository: ghcr.io/mmalyska/azerothcore-worldserver
          tag: <TAG>@sha256:<DIGEST>
        env:
          AC_DATA_DIR: /azerothcore/env/dist/data
          AC_LOGS_DIR: /azerothcore/env/dist/logs
          AC_LOGIN_DATABASE_INFO: "mysql;3306;acore;<secret>;acore_auth"
          AC_WORLD_DATABASE_INFO: "mysql;3306;acore;<secret>;acore_world"
          AC_CHARACTER_DATABASE_INFO: "mysql;3306;acore;<secret>;acore_characters"
        resources:
          requests:
            cpu: 1000m
            memory: 2Gi
          limits:
            memory: 4Gi

  adminer:
    type: deployment
    replicas: 1
    containers:
      adminer:
        image:
          repository: adminer
          tag: latest
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 128Mi

service:
  authserver:
    controller: authserver
    annotations:
      lbipam.cilium.io/ips: "192.168.48.29"
    type: LoadBalancer
    ports:
      auth:
        protocol: TCP
        port: 3724
  worldserver:
    controller: worldserver
    annotations:
      lbipam.cilium.io/ips: "192.168.48.29"
    type: LoadBalancer
    ports:
      world:
        protocol: TCP
        port: 8085
      soap:
        protocol: TCP
        port: 7878
  adminer:
    controller: adminer
    type: ClusterIP
    ports:
      http:
        protocol: TCP
        port: 8080

persistence:
  client-data:
    enabled: true
    type: persistentVolumeClaim
    existingClaim: wow-client-data
    globalMounts:
      - path: /azerothcore/env/dist/data
```

> **Note on dual LB Services sharing one IP**: Cilium IPAM supports multiple Services sharing the same `lbipam.cilium.io/ips` annotation IP as long as each Service uses different ports. Auth on 3724 and world on 8085 don't conflict.

> **Note on DB credentials in env**: Mount MySQL password from `wow-mysql-secret` as `secretKeyRef` in the container env for `AC_*_DATABASE_INFO` values.

### `templates/mysql-statefulset.yaml`

Standard MySQL 8.4 StatefulSet. Key points:
- `image: mysql:8.4`
- Env: `MYSQL_ROOT_PASSWORD` + `MYSQL_DATABASE=acore_auth` + `MYSQL_USER=acore` + `MYSQL_PASSWORD` from Secret `wow-mysql-secret`
- Also create `acore_world` and `acore_characters` databases — use an initdb ConfigMap or SQL script
- Liveness probe: `exec: mysqladmin ping -h localhost -u root -p$MYSQL_ROOT_PASSWORD`
- PVC claim on `wow-mysql` (10Gi, ceph-block)
- Service name: `mysql` (used by authserver/worldserver env vars)

### `templates/mysql-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wow-mysql
spec:
  storageClassName: ceph-block
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
```

### `templates/client-data-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wow-client-data
spec:
  storageClassName: ceph-block
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 40Gi
```

### `templates/mysql-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: wow-mysql
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: wow-mysql-secret
    creationPolicy: Owner
  data:
    - secretKey: MYSQL_ROOT_PASSWORD
      remoteRef:
        key: "<BITWARDEN-UUID-ROOT>" #gitleaks:allow #WOW_MYSQL_ROOT_PASSWORD
    - secretKey: MYSQL_PASSWORD
      remoteRef:
        key: "<BITWARDEN-UUID-ACORE>" #gitleaks:allow #WOW_MYSQL_ACORE_PASSWORD
```

**Before implementing**: Create two new secrets in Bitwarden Secrets Manager, note their UUIDs, substitute into the above.

### `templates/db-import-job.yaml`

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: wow-db-import
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: wait-for-mysql
          image: mysql:8.4
          command: ['sh', '-c', 'until mysqladmin ping -h mysql -u root -p$MYSQL_ROOT_PASSWORD --silent; do echo waiting; sleep 5; done']
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: wow-mysql-secret
                  key: MYSQL_ROOT_PASSWORD
      containers:
        - name: db-import
          image: ghcr.io/mmalyska/azerothcore-db-import:<TAG>
          env:
            - name: AC_DATA_DIR: /azerothcore/env/dist/data
            - name: DB_HOST: mysql
            # ... same AC_ env vars as worldserver for DB connection
```

### `templates/adminer-httproute.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wow-adminer
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - wow-adminer.<secret:private-domain>
  rules:
    - backendRefs:
        - name: wow-adminer
          port: 8080
```

### `templates/dns-endpoint.yaml`

A record for the game server IP itself (for `realmlist.wtf` human-readable name and AdGuard):

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: wow-game
  annotations:
    external-dns.alpha.kubernetes.io/controller: internal
spec:
  endpoints:
    - dnsName: wow.<secret:private-domain>
      recordType: A
      targets:
        - "192.168.48.29"
```

### `templates/volsync.yaml`

Restic backup for MySQL PVC. Pattern verbatim from `cluster/apps/games/vintagestory/templates/volsync.yaml` — reuse same 4 Bitwarden UUIDs:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: wow-restic
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  target:
    name: wow-restic-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        RESTIC_REPOSITORY: '{{`{{ .REPOSITORY_TEMPLATE }}`}}/wow-mysql'
        RESTIC_PASSWORD: '{{`{{ .RESTIC_PASSWORD }}`}}'
        AWS_ACCESS_KEY_ID: '{{`{{ .AWS_ACCESS_KEY_ID }}`}}'
        AWS_SECRET_ACCESS_KEY: '{{`{{ .AWS_SECRET_ACCESS_KEY }}`}}'
  data:
    - secretKey: REPOSITORY_TEMPLATE
      remoteRef:
        key: "39b92426-09c4-4a74-8285-b40a00d62b4d" #gitleaks:allow #VOLSYNC_RESTIC_REPOSITORY_TEMPLATE
    - secretKey: RESTIC_PASSWORD
      remoteRef:
        key: "07d70a7a-a6d9-4b0b-af1f-b40a00d649a9" #gitleaks:allow #VOLSYNC_RESTIC_PASSWORD
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: "adb66319-d083-4379-afd5-b40a00d66963" #gitleaks:allow #VOLSYNC_RESTIC_AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: "70ebd8f2-8270-46d8-8953-b40a00d6854f" #gitleaks:allow #VOLSYNC_RESTIC_AWS_SECRET_ACCESS_KEY
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: wow-mysql
spec:
  sourcePVC: wow-mysql
  trigger:
    schedule: "0 */12 * * *"
  restic:
    copyMethod: Snapshot
    repository: wow-restic-secret
    pruneIntervalDays: 14
    retain:
      daily: 6
      weekly: 4
      monthly: 2
```

---

## Phase 3 — Post-Deploy Manual Steps

After ArgoCD syncs and all pods are Running:

**1. Create admin game account** (via worldserver console):
```bash
kubectl exec -n wow deploy/wow-worldserver -it -- /bin/bash
# Inside container, worldserver accepts commands on stdin or via SOAP
# Use rcon or the worldserver interactive console
```
Commands:
```
account create admin <password>
account set gmlevel admin 3 -1
```

**2. Fix realmlist DB entry** (players connect to the LB IP):
```bash
kubectl exec -n wow deploy/wow-mysql-0 -- mysql -u root -p$MYSQL_ROOT_PASSWORD acore_auth \
  -e "UPDATE realmlist SET address='192.168.48.29' WHERE id=1;"
```

**3. Create AHBot account + character**:
- Create account: `account create ahbot ahbot`
- Log into WoW client as `ahbot`, create a character named `Auctioneer`, enter world once, log out
- Get character GUID: `SELECT guid FROM acore_characters.characters WHERE name='Auctioneer';`
- Update AHBot config: set `AuctionHouseBot.Account` and `AuctionHouseBot.Guid` in `mod_ahbot.conf`

**4. WoW client setup**:
- WoW version required: **3.3.5a (build 12340)**
- Edit `Data/enUS/realmlist.wtf`: `set realmlist wow.<private-domain>` (or `192.168.48.29`)
- External access: connect home router VPN first, then launch client

---

## `README.md` Content Outline (`cluster/apps/games/wow/README.md`)

Write a full README covering:

1. **What this is** — AzerothCore WotLK 3.3.5a, single-player, modules: mod-solocraft, mod-ah-bot, mod-individual-progression
2. **Client setup** — WoW version, realmlist.wtf value, VPN requirement for external access
3. **First-time setup** — account creation commands, AHBot setup steps, realmlist DB update SQL (see Phase 3 above)
4. **Module configuration**
   - mod-solocraft: `mod_solocraft.conf` — difficulty scaling by dungeon size
   - mod-ah-bot: `mod_ahbot.conf` — enable/disable buyer/seller, item quotas by rarity; AHBot account setup
   - mod-individual-progression: `mod_individual_progression.conf` — progression stages
5. **Day-to-day**
   - Stop server: `kubectl scale deploy/wow-worldserver -n wow --replicas=0`
   - Start server: `kubectl scale deploy/wow-worldserver -n wow --replicas=1`
   - Worldserver console: `kubectl exec -n wow deploy/wow-worldserver -it -- bash`
   - DB admin UI: `https://wow-adminer.<private-domain>` (internal network only)
6. **Updates**
   - AzerothCore/module updates: update Dockerfile in `mmalyska/containers`, rebuild images, bump tag + digest in `values.yaml`
7. **Backup**
   - Volsync backs up MySQL PVC every 12h to Restic (S3)
   - Check: `kubectl get replicationsource -n wow`
   - Manual trigger: `kubectl annotate replicationsource wow-mysql volsync.backube/trigger-immediate=true -n wow`
8. **Disaster recovery**
   - Full cluster rebuild: re-add Bitwarden secrets → sync ArgoCD app → MySQL PVC restores from Restic via `ReplicationDestination`
   - Client data: re-downloaded automatically by init container on worldserver pod start
   - MySQL restore procedure: create a `ReplicationDestination` resource pointing to `wow-restic-secret`, destination PVC `wow-mysql`, then restore from snapshot; example YAML included in README
