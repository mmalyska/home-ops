# Usenet media stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy SABnzbd, Prowlarr, Sonarr, Radarr, Lidarr, Bazarr and Recyclarr in a new `media` ArgoCD category, writing to one QNAP `/media` share, and move Jellyfin onto that share without changing its library paths.

**Architecture:** A new `media` AppProject + ApplicationSet discovers `cluster/apps/media/*/app-config.yaml`. Every component is its own bjw-s `app-template` app in namespace `media`; all mount one shared NFS PVC (`media`, from the `media-storage` app) at `/data` so downloads and libraries sit on one filesystem. Config lives on per-app ceph-block PVCs backed up by the local `volsync` chart.

**Tech Stack:** ArgoCD ApplicationSets, Helm (bjw-s `app-template` 5.3.0, local `charts/volsync`), External Secrets (Bitwarden `ClusterSecretStore`), Gateway API HTTPRoute, NFS PV/PVC on QNAP, Reloader.

**Spec:** `.plans/superpowers/specs/2026-10-15-usenet-media-stack-design.md`

## Global Constraints

- Namespace `media`; category dir `cluster/apps/media/`; one ArgoCD app per component.
- Run as `1001:1001`, `fsGroup: 1001`, `fsGroupChangePolicy: OnRootMismatch`, `TZ: CET`.
- Images from `ghcr.io/home-operations/*`, pinned `tag@digest` (values in Task 3-6 and 8-9).
- NFS mount options: `nfsvers=4.1, tcp, intr, hard, noatime, nodiratime`; `storageClassName: nfs-qnap`; `ReadWriteMany`; `persistentVolumeReclaimPolicy: Retain`; server `qnap.<secret:private-domain>`; export path `/media`.
- All containers mount the media PVC at `/data`. SABnzbd incomplete dir is `/incomplete` (ceph-block PVC `sabnzbd-incomplete`, 100Gi, not backed up).
- Routes: HTTPRoute on `envoy-internal` (`namespace: envoy-gateway`, `sectionName: https`), hostname `<app>.<secret:private-domain>`, annotation `external-dns.alpha.kubernetes.io/controller: dns-controller`. No Cloudflare, no LoadBalancer IP.
- Forms login with authentication **required** (not `DisabledForLocalAddresses`).
- `app-config.yaml` for every app: `enabled: "true"`, `namespace: media`, `syncPolicy {enabled: true, selfHeal: true, prune: false}`, plugin env `SECRET_PROVIDER: cluster-secrets`.
- volsync chart: `restore.bootstrap: false` for new apps (no backup exists yet; `true` leaves the PVC pending).
- Deployment strategy `Recreate`; memory limit set, no CPU limit.
- Never commit secret values or private domain literals. Bitwarden UUID lines carry `#gitleaks:allow #KEY_NAME`.
- Branches `feat/` prefixed, PR per group, no Claude attribution, no push to `main`. Cluster mutations (sync, kubectl apply/delete/scale, Jellyfin pause) need explicit user confirmation at that moment.
- Work in a linked worktree under `.worktrees/<branch>`; never in the primary checkout.

## Review Focus

1. **Hardlinks silently degrade to copy** over QNAP NFS: expected behavior is same inode between `usenet/complete` and `tv-series`. Tested in Task 7.
2. **SABnzbd "Access denied - Hostname verification failed"** behind the route: expected UI loads at `sabnzbd.<private-domain>`. Tested in Task 3.
3. **Jellyfin subPath directory missing on the export**: kubelet creates it as root, Jellyfin can't write. Expected: directories pre-exist, owned 1001. Tested in Task 11.
4. **Unauthenticated first-run window** on new *arr UIs: expected `AUTH__REQUIRED=Enabled` already set so first visit forces user creation. Tested in Task 4.
5. **Recyclarr with an unreachable or key-mismatched *arr**: expected a failed Job, not a broken app, and a clear log. Tested in Task 9.

---

## PR / branch plan

| PR | Branch | Tasks |
|---|---|---|
| A | `feat/media-stack-core` | 1-6, 7 (verification, after QNAP step), 8 |
| B | `feat/media-stack-extras` | 9, 10 |
| C | `feat/jellyfin-media-share` | 11 |

Create each branch with `git worktree add .worktrees/<branch> -b <branch> origin/main` from `/workspaces/home-ops`.

---

### Task 1: `media` category (AppProject + ApplicationSet)

**Files:**
- Create: `cluster/appsets/appset-media.yaml`
- Create: `cluster/projects/media.yaml`
- Modify: `CLAUDE.md` (category list in the Repository Structure block)

**Interfaces:**
- Produces: ArgoCD project `media`; ApplicationSet that turns each `cluster/apps/media/<app>/app-config.yaml` into an Application in project `media`.

- [ ] **Step 1: Generate the files from the games category**

```bash
cp cluster/appsets/appset-games.yaml cluster/appsets/appset-media.yaml
cp cluster/projects/games.yaml cluster/projects/media.yaml
sed -i 's/appset-games/appset-media/; s#cluster/apps/games/#cluster/apps/media/#; s/project: games/project: media/' cluster/appsets/appset-media.yaml
sed -i 's/^  name: games$/  name: media/; s/Main games project/Media acquisition project/' cluster/projects/media.yaml
```

- [ ] **Step 2: Verify the only differences from the games files are the intended ones**

Run: `diff cluster/appsets/appset-games.yaml cluster/appsets/appset-media.yaml; diff cluster/projects/games.yaml cluster/projects/media.yaml`
Expected: appset differs on 3 lines (name, generator path, project); project differs on 2 lines (name, description). No `games` left in the media files: `grep -n games cluster/appsets/appset-media.yaml cluster/projects/media.yaml` prints nothing.

- [ ] **Step 3: Add `media` to the CLAUDE.md category list**

Change `# Applications by category: core, system, default, games, home-automation` to `# Applications by category: core, system, default, games, home-automation, media`.

- [ ] **Step 4: Lint**

Run: `task lint:yaml`
Expected: no errors for the two new files.

- [ ] **Step 5: Commit**

```bash
git add cluster/appsets/appset-media.yaml cluster/projects/media.yaml CLAUDE.md
git commit -m "feat(media): add media ArgoCD category"
```

---

### Task 2: `media-storage` app (shared `/media` PV + PVC)

**Files:**
- Create: `cluster/apps/media/media-storage/app-config.yaml`
- Create: `cluster/apps/media/media-storage/kustomization.yaml`
- Create: `cluster/apps/media/media-storage/media.yaml`

**Interfaces:**
- Produces: PVC `media` in namespace `media` (RWX, 50Gi nominal), bound to PV `media`. Consumed by Tasks 3-6, 8, 9 as `existingClaim: media`.

- [ ] **Step 1: Write `app-config.yaml`**

```yaml
- enabled: "true"
  namespace: media
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Step 2: Write `kustomization.yaml`**

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - media.yaml
```

- [ ] **Step 3: Write `media.yaml`**

```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: media
spec:
  storageClassName: nfs-qnap
  claimRef:
    name: media
    namespace: media
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: qnap.<secret:private-domain>
    path: "/media"
  mountOptions:
    - nfsvers=4.1
    - tcp
    - intr
    - hard
    - noatime
    - nodiratime
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: media
  namespace: media
spec:
  volumeName: media
  storageClassName: nfs-qnap
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
```

- [ ] **Step 4: Render and lint**

Run: `kubectl kustomize cluster/apps/media/media-storage && task lint:yaml`
Expected: one PV and one PVC rendered, no lint errors.

- [ ] **Step 5: Commit**

```bash
git add cluster/apps/media/media-storage
git commit -m "feat(media): add shared media NFS volume"
```

---

### Task 3: SABnzbd

**Files:**
- Create: `cluster/apps/media/sabnzbd/{app-config.yaml,Chart.yaml,values.yaml}`

**Interfaces:**
- Consumes: PVC `media` (Task 2); volsync chart `file://../../../../charts/volsync/`.
- Produces: Service `sabnzbd` port 8080 in `media`; route `sabnzbd.<secret:private-domain>`; download root `/data/usenet/complete/{tv,movies,music}`; incomplete `/incomplete`.

- [ ] **Step 1: `app-config.yaml`** — identical to Task 2 Step 1.

- [ ] **Step 2: `Chart.yaml`**

```yaml
---
apiVersion: v2
name: sabnzbd
type: application
version: 1.0.0
dependencies:
  - name: app-template
    version: 5.3.0
    repository: https://bjw-s-labs.github.io/helm-charts
  - name: volsync
    version: 1.0.0
    repository: file://../../../../charts/volsync/
```

- [ ] **Step 3: `values.yaml`**

```yaml
app-template:
  controllers:
    sabnzbd:
      strategy: Recreate
      pod:
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          runAsNonRoot: true
          fsGroup: 1001
          fsGroupChangePolicy: OnRootMismatch
      containers:
        app:
          image:
            repository: ghcr.io/home-operations/sabnzbd
            tag: 5.1.3@sha256:b1795982db498ed5691a7b1231f0fac7eed2a1d53e9c81b8e834d02695e76104
            pullPolicy: IfNotPresent
          env:
            TZ: CET
            SABNZBD__HOST_WHITELIST_ENTRIES: sabnzbd.<secret:private-domain>
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              memory: 2Gi

  service:
    app:
      ports:
        http:
          port: 8080

  route:
    app:
      kind: HTTPRoute
      annotations:
        external-dns.alpha.kubernetes.io/controller: dns-controller
      parentRefs:
        - name: envoy-internal
          namespace: envoy-gateway
          sectionName: https
      hostnames:
        - sabnzbd.<secret:private-domain>
      rules:
        - backendRefs:
            - identifier: app
              port: 8080

  persistence:
    config:
      existingClaim: sabnzbd
      advancedMounts:
        sabnzbd:
          app:
            - path: /config
    incomplete:
      existingClaim: sabnzbd-incomplete
      advancedMounts:
        sabnzbd:
          app:
            - path: /incomplete
    media:
      existingClaim: media
      advancedMounts:
        sabnzbd:
          app:
            - path: /data
    tmp:
      type: emptyDir
      advancedMounts:
        sabnzbd:
          app:
            - path: /tmp

volsync:
  pvc:
    capacity: 2Gi
    storageClass: ceph-block
    volumeSnapshotClass: csi-ceph-blockpool
  volsync:
    moverSecurityContext:
      runAsUser: 1001
      runAsGroup: 1001
      fsGroup: 1001
    backup:
      schedule: "10 */12 * * *"
      pruneIntervalDays: 14
      retain:
        hourly: 24
        daily: 7
        weekly: 4
        monthly: 2
    restore:
      bootstrap: false
```

- [ ] **Step 4: Add the `incomplete` PVC** in `templates/incomplete-pvc.yaml`

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: sabnzbd-incomplete
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
  storageClassName: ceph-block
```

Before committing, check ceph free space with `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph df` (read-only). If less than ~300Gi free, stop and ask the user to confirm the size.

- [ ] **Step 5: Render**

Run:
```bash
cd cluster/apps/media/sabnzbd && helm dependency build && helm template sabnzbd . -f values.yaml | grep -E "^kind:|claimName|hostnames|image:" | sort | uniq -c
```
Expected: Deployment, Service, HTTPRoute, PVCs (`sabnzbd`, `sabnzbd-incomplete`), replication resources from volsync; image line shows the pinned digest. `Chart.lock` and `charts/` are git-ignored; do not add them.

- [ ] **Step 6: Verify env var name in the image** (the whitelist variable is unverified)

Run (read-only, after deploy in Task 7): `kubectl -n media exec deploy/sabnzbd -- grep -i host_whitelist /config/sabnzbd.ini`
Expected: the route hostname appears. If empty, the variable name is wrong; fix per the image's README and re-render.

- [ ] **Step 7: Commit**

```bash
git add cluster/apps/media/sabnzbd
git commit -m "feat(media): add SABnzbd"
```

---

### Task 4: *arr API-key secrets and the four *arr apps (Sonarr, Radarr, Lidarr, Prowlarr)

**Files (per app, `<app>` in sonarr, radarr, lidarr, prowlarr):**
- Create: `cluster/apps/media/<app>/{app-config.yaml,Chart.yaml,values.yaml}`
- Create: `cluster/apps/media/<app>/templates/externalsecret.yaml`

**Interfaces:**
- Consumes: PVC `media` (Task 2, except Prowlarr), volsync chart.
- Produces: Service `<app>` in `media` on the port below; Secret `<app>-secrets` with key `<APP>__AUTH__APIKEY`; routes `<app>.<secret:private-domain>`.

Parameter table (substitute into the templates below):

| `<app>` | `<APP>` | port | image tag@digest | config PVC | media mount | memory limit |
|---|---|---|---|---|---|---|
| sonarr | SONARR | 8989 | `4.0.20.3012@sha256:1f19eb5e0f421418c1a956bbe01310a0141423afe28bd9a4b1dcb8629ff2bce2` | 5Gi | `/data` | 1Gi |
| radarr | RADARR | 7878 | `6.4.4.10685@sha256:be53998a2d39cfa3c3315b70c7509a6a1f2a10c3aee9337653efc9f4c970430e` | 5Gi | `/data` | 1Gi |
| lidarr | LIDARR | 8686 | `3.1.6.5078@sha256:b4c60ae24ff264bcdfd8d5562982d99105c17b82c28a6986498f6fb215b7f42e` | 5Gi | `/data` | 1Gi |
| prowlarr | PROWLARR | 9696 | `2.6.5.5623@sha256:6152751c3ea2e7751564f5952173d5e83eed0e09f3fabd2cb6bdb58690c39e2f` | 2Gi | none | 512Mi |

Note: the Sonarr digests above were resolved on 2026-10-15 from the GHCR tag index. Sonarr `5.x` is still a prerelease upstream, so `4.0.20.3012` is the deliberate pin; the digests resolve a multi-arch index, so re-resolve rather than hand-edit if a tag moves.

- [x] **Step 1: Bitwarden secrets (done 2026-10-15)**

The four secrets exist in Bitwarden Secrets Manager (32-char values, never print them). UUIDs for the ExternalSecrets:

| Key | UUID |
|---|---|
| `SONARR_API_KEY` | `de6c7bb0-ca55-47dd-9fbd-b4e401035bad` |
| `RADARR_API_KEY` | `8b04c516-ab4b-446b-8721-b4e401036e8a` |
| `LIDARR_API_KEY` | `9613910b-d3dd-4ae1-afd8-b4e401037fc6` |
| `PROWLARR_API_KEY` | `06400109-7392-4b01-aa8c-b4e4010391b3` |

When listing secrets with `bws`, extract only `key` and `id`; `bws secret list` prints values.

- [ ] **Step 2: `app-config.yaml` and `Chart.yaml`** — same as Task 3 Steps 1-2 with `name: <app>`.

- [ ] **Step 3: `values.yaml` template** (omit the `media` persistence block for Prowlarr)

```yaml
app-template:
  controllers:
    <app>:
      strategy: Recreate
      annotations:
        secret.reloader.stakater.com/reload: "<app>-secrets"
      pod:
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          runAsNonRoot: true
          fsGroup: 1001
          fsGroupChangePolicy: OnRootMismatch
      containers:
        app:
          image:
            repository: ghcr.io/home-operations/<app>
            tag: <tag@digest>
            pullPolicy: IfNotPresent
          env:
            TZ: CET
            <APP>__APP__INSTANCENAME: <App>
            <APP>__SERVER__PORT: "<port>"
            <APP>__LOG__DBENABLED: "False"
            <APP>__AUTH__METHOD: Forms
            <APP>__AUTH__REQUIRED: Enabled
          envFrom:
            - secretRef:
                name: <app>-secrets
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              memory: <memory limit>

  service:
    app:
      ports:
        http:
          port: <port>

  route:
    app:
      kind: HTTPRoute
      annotations:
        external-dns.alpha.kubernetes.io/controller: dns-controller
      parentRefs:
        - name: envoy-internal
          namespace: envoy-gateway
          sectionName: https
      hostnames:
        - <app>.<secret:private-domain>
      rules:
        - backendRefs:
            - identifier: app
              port: <port>

  persistence:
    config:
      existingClaim: <app>
      advancedMounts:
        <app>:
          app:
            - path: /config
    media:
      existingClaim: media
      advancedMounts:
        <app>:
          app:
            - path: /data
    tmp:
      type: emptyDir
      advancedMounts:
        <app>:
          app:
            - path: /tmp

volsync:
  pvc:
    capacity: <config PVC>
    storageClass: ceph-block
    volumeSnapshotClass: csi-ceph-blockpool
  volsync:
    moverSecurityContext:
      runAsUser: 1001
      runAsGroup: 1001
      fsGroup: 1001
    backup:
      schedule: "<minute> */12 * * *"
      pruneIntervalDays: 14
      retain:
        hourly: 24
        daily: 7
        weekly: 4
        monthly: 2
    restore:
      bootstrap: false
```

Stagger `<minute>`: sonarr `20`, radarr `25`, lidarr `30`, prowlarr `15` (sabnzbd `10`).

- [ ] **Step 4: `templates/externalsecret.yaml`** (use the UUID the user supplied)

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>-secrets
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: <app>-secrets
    creationPolicy: Owner
  data:
    - secretKey: <APP>__AUTH__APIKEY
      remoteRef:
        key: "<uuid from the Step 1 table>" #gitleaks:allow #<APP>_API_KEY
```

- [ ] **Step 5: Render each app**

Run per app: `cd cluster/apps/media/<app> && helm dependency build && helm template <app> . -f values.yaml | grep -E "^kind:|image:|claimName|port:" | sort | uniq -c`
Expected: Deployment (strategy Recreate), Service, HTTPRoute, ExternalSecret, volsync resources; no unrendered `<...>` placeholders: `helm template ... | grep -n '<app>\|<APP>\|<port>'` prints nothing.

- [ ] **Step 6: Verify env var names against the running config** (after deploy, Task 7; read-only)

Run: `kubectl -n media exec deploy/<app> -- cat /config/config.xml`
Expected: `<AuthenticationMethod>Forms</AuthenticationMethod>`, `<AuthenticationRequired>Enabled</AuthenticationRequired>`, `<ApiKey>` present, `<Port>` equals the table port. If a value is missing the variable name differs for that image; fix in `values.yaml`.

- [ ] **Step 7: Commit once per app**

```bash
git add cluster/apps/media/<app>
git commit -m "feat(media): add <App>"
```

---

### Task 5: lint and open PR A (without enabling anything live)

**Files:** none new.

- [ ] **Step 1: Full lint**

Run: `task lint:all`
Expected: pass. Fix findings in the owning task's files and amend that app's commit.

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feat/media-stack-core
gh pr create --base main --title "feat(media): usenet download stack core" --body "Adds the media category, shared /media volume, SABnzbd, Prowlarr, Sonarr, Radarr and Lidarr. Needs the QNAP /media share and NFS export before merge; see the runbook in the PR description."
```

PR body must list the QNAP prerequisites from Task 6.

---

### Task 6: QNAP share prerequisite (USER STEP, blocks merge of PR A)

**Files:** none.

- [ ] **Step 1: Ask the user to do these on the QNAP and confirm each**

1. Create shared folder `media` on the same volume as `tv-series`, `movies`, `music`. Do **not** enable Windows ACLs on it.
2. NFS export of `/media` allowed for `192.168.48.2`-`192.168.48.5`, read/write, squash settings that preserve UID 1001 (no "squash all users" to a different ID).
3. Create folders `usenet/complete/tv`, `usenet/complete/movies`, `usenet/complete/music`, `tv-series`, `movies`, `music` and set owner `1001:1001`.
4. Do not move existing media yet.

- [ ] **Step 2: Read-only check from the cluster once the user confirms** (needs user confirmation to run in-cluster)

Run: `kubectl -n media get pv media pvc media` after PR A syncs.
Expected: PV `media` and PVC `media` `Bound`.

---

### Task 7: Hardlink gate (CLUSTER STEP, needs user confirmation to run)

**Files:** none.

- [ ] **Step 1: Confirm with the user, then write a test file and hardlink it from the SABnzbd pod**

```bash
kubectl -n media exec deploy/sabnzbd -- sh -c 'echo test > /data/usenet/complete/.hl-src && ln /data/usenet/complete/.hl-src /data/tv-series/.hl-dst && stat -c "%i %h %n" /data/usenet/complete/.hl-src /data/tv-series/.hl-dst'
```
Expected: both lines show the **same inode** and link count `2`. `ln: Operation not permitted` or different inodes means hardlinks do not work: stop and report to the user (spec fallback: copy+delete).

- [ ] **Step 2: Clean up**

```bash
kubectl -n media exec deploy/sabnzbd -- rm -f /data/usenet/complete/.hl-src /data/tv-series/.hl-dst
```

- [ ] **Step 3: Verify SABnzbd hostname whitelist and *arr auth (Review Focus 2 and 4)**

Open `https://sabnzbd.<private-domain>` from the LAN: UI loads, no hostname-verification error. Open each *arr: the first screen is the "create admin user" form, not the dashboard. Ask the user to create the users now.

---

### Task 8: Documentation for PR A

**Files:**
- Create: `docs/src/k8s/media.md`
- Modify: the mkdocs nav (find it with `find . -maxdepth 2 -name mkdocs.yml -not -path "./.git*"`)

- [ ] **Step 1: Write `docs/src/k8s/media.md`** with sections: layout of `/media`, app roles and hostnames (`<app>.<private-domain>`), how paths map (`/data/...` identical in every pod), SABnzbd categories (`tv`, `movies`, `music` -> `/data/usenet/complete/<category>`), incomplete dir, the hardlink test command from Task 7, API keys live in Bitwarden (`SONARR_API_KEY` etc.) with the ExternalSecret path, and the first-run setup order: SABnzbd servers (primary priority 0, backup higher number) -> Prowlarr indexers -> register Sonarr/Radarr/Lidarr in Prowlarr -> add SABnzbd as download client in each *arr -> root folders `/data/tv-series`, `/data/movies`, `/data/music` -> enable hardlinks -> follow TRaSH naming. Never write the private domain literally; use `<private-domain>`.

- [ ] **Step 2: Add the page to the nav, lint**

Run: `task lint:markdown && task lint:prettier:check`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add docs/src/k8s/media.md mkdocs.yml
git commit -m "docs(media): document the usenet stack layout and setup"
```

---

### Task 9: Bazarr (PR B)

**Files:**
- Create: `cluster/apps/media/bazarr/{app-config.yaml,Chart.yaml,values.yaml}`

**Interfaces:**
- Consumes: PVC `media`; Sonarr/Radarr service DNS `sonarr.media.svc.cluster.local:8989`, `radarr.media.svc.cluster.local:7878`.
- Produces: Service `bazarr` port 6767, route `bazarr.<secret:private-domain>`.

- [ ] **Step 1: Files** — `app-config.yaml` and `Chart.yaml` as in Task 3 with name `bazarr`. `values.yaml` is the Task 4 Step 3 template with: no `envFrom`, no `<APP>__*` env except `TZ: CET`; image `ghcr.io/home-operations/bazarr` tag `1.6.2@sha256:17dc1cff22e99694ffbfb06555526cb47a66b362b4d6c982f06b557f7caae2bb`; port `6767`; config PVC `2Gi`; memory limit `512Mi`; volsync schedule `"35 */12 * * *"`; no ExternalSecret and no Reloader annotation.

- [ ] **Step 2: Render**

Run: `cd cluster/apps/media/bazarr && helm dependency build && helm template bazarr . -f values.yaml | grep -E "^kind:|image:|port:" | sort | uniq -c`
Expected: Deployment, Service, HTTPRoute, volsync resources; `port: 6767`.

- [ ] **Step 3: Commit**

```bash
git add cluster/apps/media/bazarr
git commit -m "feat(media): add Bazarr"
```

---

### Task 10: Recyclarr (PR B)

**Files:**
- Create: `cluster/apps/media/recyclarr/{app-config.yaml,Chart.yaml,values.yaml}`
- Create: `cluster/apps/media/recyclarr/templates/externalsecret.yaml`

**Interfaces:**
- Consumes: Sonarr/Radarr service DNS; Bitwarden secrets `SONARR_API_KEY`, `RADARR_API_KEY` (same UUIDs as Task 4).
- Produces: a daily CronJob syncing TRaSH quality profiles and custom formats.

- [ ] **Step 1: List valid TRaSH template IDs before writing config**

Run: `docker run --rm ghcr.io/recyclarr/recyclarr:8.8.0 config list templates --sonarr; docker run --rm ghcr.io/recyclarr/recyclarr:8.8.0 config list templates --radarr`
Expected: template names printed. Use the entries for WEB-1080p (Sonarr) and HD Bluray + WEB (Radarr) plus the matching quality-definition templates. If Docker is unavailable, ask the user which profile they want and use the IDs from the Recyclarr config-templates repository.

- [ ] **Step 2: `app-config.yaml`, `Chart.yaml`** as Task 3 with `name: recyclarr`, app-template dependency only (no volsync: state is a cache).

- [ ] **Step 3: `templates/externalsecret.yaml`** — Task 4 Step 4 shape with `name: recyclarr-secrets` and two data entries: `SONARR_API_KEY` and `RADARR_API_KEY`, each with the same UUID used in Task 4 and `#gitleaks:allow #SONARR_API_KEY` / `#RADARR_API_KEY`.

- [ ] **Step 4: `values.yaml`**

```yaml
app-template:
  controllers:
    recyclarr:
      type: cronjob
      cronjob:
        schedule: "30 4 * * *"
        concurrencyPolicy: Forbid
        backoffLimit: 1
        successfulJobsHistory: 1
        failedJobsHistory: 3
      annotations:
        secret.reloader.stakater.com/reload: "recyclarr-secrets"
      pod:
        restartPolicy: Never
        securityContext:
          runAsUser: 1001
          runAsGroup: 1001
          runAsNonRoot: true
          fsGroup: 1001
      containers:
        app:
          image:
            repository: ghcr.io/recyclarr/recyclarr
            tag: 8.8.0@sha256:b1fbb929ba718fdbdac2c1fc25b32b0ae916d7a5a0892c2068c9bfae6f1a9209
            pullPolicy: IfNotPresent
          args: ["sync"]
          env:
            TZ: CET
          envFrom:
            - secretRef:
                name: recyclarr-secrets
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 25m
              memory: 128Mi
            limits:
              memory: 256Mi

  configMaps:
    config:
      data:
        recyclarr.yml: |
          sonarr:
            series:
              base_url: http://sonarr.media.svc.cluster.local:8989
              api_key: !env_var SONARR_API_KEY
              include:
                - template: <sonarr quality-definition template from Step 1>
                - template: <sonarr WEB-1080p quality-profile template from Step 1>
                - template: <sonarr WEB-1080p custom-formats template from Step 1>
          radarr:
            movies:
              base_url: http://radarr.media.svc.cluster.local:7878
              api_key: !env_var RADARR_API_KEY
              include:
                - template: <radarr quality-definition template from Step 1>
                - template: <radarr HD Bluray + WEB quality-profile template from Step 1>
                - template: <radarr HD Bluray + WEB custom-formats template from Step 1>

  persistence:
    config:
      type: emptyDir
      advancedMounts:
        recyclarr:
          app:
            - path: /config
    config-file:
      type: configMap
      identifier: config
      advancedMounts:
        recyclarr:
          app:
            - path: /config/recyclarr.yml
              subPath: recyclarr.yml
              readOnly: true
```

Replace the three `<...from Step 1>` entries per app with the exact template IDs printed in Step 1 before committing; a render that still contains `<` in `recyclarr.yml` is a failure.

- [ ] **Step 5: Render and lint**

Run: `cd cluster/apps/media/recyclarr && helm dependency build && helm template recyclarr . -f values.yaml | grep -nE "kind: CronJob|schedule|template:|<" `
Expected: a `CronJob`, schedule `30 4 * * *`, template lines with real IDs, no stray `<`.

- [ ] **Step 6: After deploy, trigger once and read the log (Review Focus 5; needs user confirmation)**

```bash
kubectl -n media create job --from=cronjob/recyclarr recyclarr-manual
kubectl -n media logs job/recyclarr-manual
```
Expected: sync completes with created/updated profiles. With an unreachable *arr the Job fails with a connection error and nothing else is affected. Delete the manual job afterwards.

- [ ] **Step 7: Commit, push, open PR B**

```bash
git add cluster/apps/media/recyclarr
git commit -m "feat(media): add Recyclarr with TRaSH profiles"
git push -u origin feat/media-stack-extras
gh pr create --base main --title "feat(media): add Bazarr and Recyclarr" --body "Adds Bazarr and a daily Recyclarr sync of TRaSH profiles for Sonarr and Radarr. Requires PR A applied and the *arr API keys in Bitwarden."
```

---

### Task 11: Jellyfin cutover (PR C, maintenance window)

**Files:**
- Modify: `cluster/apps/default/jellyfin/values.yaml` (volumes, volumeMounts, nfsMounts)
- Modify: `cluster/apps/default/jellyfin/templates/pvc-extra.yaml`

**Interfaces:**
- Consumes: QNAP export `/media` with `tv-series`, `movies`, `music` populated by the user.
- Produces: PV/PVC `jellyfin-media` in namespace `jellyfin`; container paths `/data/tvshows`, `/data/movies`, `/data/music` unchanged.

- [ ] **Step 1: Pre-flight with the user (BLOCKING)**

Confirm: (a) PR A and B are merged and stable, (b) Task 7 hardlink gate passed, (c) the user has a maintenance window. Ask the user to stop Jellyfin via git (see Step 2) before moving content, then move the contents of the old `tv-series`, `movies`, `music` shares into `/media/tv-series`, `/media/movies`, `/media/music` and confirm ownership is `1001:1001` and the three directories exist and are non-empty (Review Focus 3: a missing subPath directory would be created root-owned by kubelet).

- [ ] **Step 2: Pause Jellyfin through git** (selfHeal reverts a plain scale-down)

In `cluster/apps/default/jellyfin/values.yaml` set `jellyfin.replicaCount: 0`, commit `chore(jellyfin): pause for media share migration`, PR, merge. Confirm Argo shows 0 replicas before the user moves data.

- [ ] **Step 3: Replace `pvc-extra.yaml`** with a single PV/PVC

```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jellyfin-media
spec:
  storageClassName: nfs-qnap
  claimRef:
    name: jellyfin-media
    namespace: jellyfin
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: {{ .Values.nfsMedia.nfsServer }}
    path: {{ .Values.nfsMedia.nfsPath | quote }}
  mountOptions:
    - nfsvers=4.1
    - tcp
    - intr
    - hard
    - noatime
    - nodiratime
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jellyfin-media
  namespace: jellyfin
spec:
  volumeName: jellyfin-media
  storageClassName: nfs-qnap
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 50Gi
```

- [ ] **Step 4: Edit `values.yaml`**

Replace the `nfsMounts:` list with:

```yaml
nfsMedia:
  nfsPath: /media
  nfsServer: qnap.<secret:private-domain>
```

Replace the three NFS volumes (`tv-shows`, `movies`, `music`) with one, keeping `transcoding`:

```yaml
  volumes:
    - name: media
      persistentVolumeClaim:
        claimName: jellyfin-media
    - name: transcoding
      emptyDir: {}
```

and the mounts with:

```yaml
  volumeMounts:
    - name: media
      mountPath: /data/tvshows
      subPath: tv-series
    - name: media
      mountPath: /data/movies
      subPath: movies
    - name: media
      mountPath: /data/music
      subPath: music
    - name: transcoding
      mountPath: /transcoding
```

Set `jellyfin.replicaCount` back to its previous value (remove the pause line).

- [ ] **Step 5: Render**

Run: `cd cluster/apps/default/jellyfin && helm dependency build && helm template jellyfin . -f values.yaml | grep -nE "subPath|claimName|path: /media|kind: PersistentVolume"`
Expected: one PV `jellyfin-media`, three `subPath` mounts, container paths unchanged, no references to `jellyfin-tv-shows`, `jellyfin-movies`, `jellyfin-music`.

- [ ] **Step 6: Commit, push, open PR C**

```bash
git add cluster/apps/default/jellyfin
git commit -m "feat(jellyfin): mount libraries from the shared media share"
git push -u origin feat/jellyfin-media-share
gh pr create --base main --title "feat(jellyfin): mount libraries from the shared media share" --body "Swaps the three library NFS volumes for one /media volume with subPath mounts at the same container paths. Old PVs/PVCs are deleted manually afterwards; old shares stay for two weeks."
```

- [ ] **Step 7: Verify after merge (needs user confirmation for each cluster action)**

1. `kubectl -n jellyfin get pod,pvc` — pod Running, PVC `jellyfin-media` Bound.
2. In Jellyfin: libraries still list items, a movie plays, watch history intact, a library scan completes without re-importing everything.
3. Old objects: with the user's confirmation `kubectl delete pvc -n jellyfin jellyfin-tv-shows jellyfin-movies jellyfin-music` then `kubectl delete pv jellyfin-tv-shows jellyfin-movies jellyfin-music` (PVs are `Retain`; this only removes the cluster objects, not data).
4. Record the date; the old QNAP shares and exports are deleted two weeks after verification.

---

## Self-review notes

- Spec coverage: category (Task 1), storage (2), SABnzbd (3), *arrs and Prowlarr (4), Lidarr within 4, Bazarr (9), Recyclarr (10), rollout steps (6, 7, 11), docs (8), risks (Review Focus + Tasks 3, 4, 7, 11).
- Unverified until deploy, each with a read-only check: env-var names (Tasks 3 and 4), Recyclarr template IDs (Task 10 Step 1), Sonarr v5 stays out until stable.
- Not in this plan: metrics/alerts, Seerr, external access, deleting old QNAP shares (two weeks after Task 11).
