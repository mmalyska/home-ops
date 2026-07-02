# Nextcloud + OnlyOffice OneDrive Replacement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy self-hosted Nextcloud (file sync/management) + OnlyOffice Document Server (Community, document editing) on the home-ops cluster, replacing OneDrive, then migrate ~600GB of family data off US-hosted cloud storage one family member at a time.

**Architecture:** Nextcloud (official Helm chart, `fpm-alpine`) with a small Ceph-backed PVC for app state and a QNAP-NFS-backed PVC (native `persistence.nextcloudData`) for the 600GB+ user data directory. Postgres via the local `pgsql-cnpg` chart. OnlyOffice Document Server (Community) as a small local Helm chart, internal-only, connected via Nextcloud's ONLYOFFICE connector app over ClusterIP with a shared JWT secret. Auth via Keycloak SSO (`user_oidc` app). Exposed externally via `envoy-external` + Cloudflare tunnel. Design doc: `docs/superpowers/specs/2026-07-02-nextcloud-onedrive-replacement-design.md`.

**Tech Stack:** Helm (OCI + local charts), ArgoCD ApplicationSet (`appSubfolder` pattern), CloudNativePG (`pgsql-cnpg`), External Secrets Operator (Bitwarden `ClusterSecretStore`), NFS (QNAP), Envoy Gateway (Gateway API), Volsync, Keycloak OIDC.

## Global Constraints

- Never commit secret values — gitleaks pre-commit hook enforces this. Mark any Bitwarden UUID reference with `#gitleaks:allow #KEY_NAME`.
- Secret in K8s `Secret` `data`/`stringData` → `ExternalSecret`. Secret/token in any other field (hostnames, config values) → `<secret:key>` token + `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`.
- Never mutate live cluster state (`kubectl apply`, ArgoCD sync/enable, `kubectl exec` that changes app state) without explicit user confirmation — this plan flags every such step.
- Never push to `main` directly — all changes via PR on a `feat/` branch. This plan continues on the existing branch `feat/nextcloud-onedrive-replacement`.
- After any manifest/values change: render before committing (`helm template` / `kubectl kustomize` as applicable, plus `task lint:all`).
- Namespace for all resources in this plan: `nextcloud`.

---

### Task 1: QNAP NFS export + static Kubernetes PV/PVC for Nextcloud data

**Files:**
- Create (manual, on QNAP, not git): NFS share `/nextcloud-data` on the QNAP TS-251D (192.168.50.8)
- Create: `cluster/apps/default/nfs-mounts/resources/nfs-nextcloud-data.yaml`
- Modify: `cluster/apps/default/nfs-mounts/kustomization.yaml`

**Interfaces:**
- Produces: PVC `nfs-nextcloud-data-pvc` in namespace `nfs-mounts`, storage class `nextcloud-data`, NFS-backed. Task 5 references this indirectly — the Nextcloud app's own PVC (Task 5) binds to a **separate** static PV pointing at the same NFS path but claimed from the `nextcloud` namespace (PVs are cluster-scoped but PVCs are namespaced, and Nextcloud's pod runs in `nextcloud`, not `nfs-mounts`). So this task actually creates the PV/PVC pair directly in the `nextcloud` namespace instead of `nfs-mounts`, to keep it colocated with the app that uses it — see corrected file path below.

**Corrected files:**
- Create: `cluster/apps/default/nextcloud/app/templates/nfs-data-pv.yaml`

- [ ] **Step 1: Create the NFS share on the QNAP NAS (manual, non-git)**

In the QNAP web UI (Control Panel → Shared Folders), create a new shared folder named `nextcloud-data`, NFS-enabled, with the same host permissions as the existing `movies`/`tv-series`/`ebooks` shares (read/write for the cluster node subnet `192.168.48.0/24`). Note the export path — it should be `/nextcloud-data`.

- [ ] **Step 2: Write the static PV/PVC manifest**

Create `cluster/apps/default/nextcloud/app/templates/nfs-data-pv.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: nextcloud-data-pv
spec:
  storageClassName: nextcloud-data
  claimRef:
    name: nextcloud-data-pvc
    namespace: nextcloud
  capacity:
    storage: 2000Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: qnap.<secret:private-domain>
    path: "/nextcloud-data"
  mountOptions:
    - nfsvers=4.2
    - tcp
    - intr
    - hard
    - noatime
    - nodiratime
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nextcloud-data-pvc
  namespace: nextcloud
spec:
  volumeName: nextcloud-data-pv
  accessModes:
    - ReadWriteOnce
  storageClassName: nextcloud-data
  resources:
    requests:
      storage: 2000Gi
```

Note: `2000Gi` in `capacity`/`requests` is documentation of intent, not an NFS-enforced quota (same as the existing `movies`/`tv-series`/`ebooks` PVs in this repo, all declared at `50Gi` regardless of actual share size). `accessModes: ReadWriteOnce` is sufficient — Nextcloud runs a single replica, so no need for `ReadWriteMany`.

- [ ] **Step 3: Verify manifest is valid YAML and matches existing NFS PV conventions**

Run: `yamllint cluster/apps/default/nextcloud/app/templates/nfs-data-pv.yaml`
Expected: no errors (this file doesn't exist as a Helm template yet in a chart with `templates/`, so this is a standalone kustomize-style check for now — it becomes part of the Helm chart's `templates/` in Task 5, so re-verify with `helm template` once Task 5's `Chart.yaml`/`values.yaml` exist).

- [ ] **Step 4: Commit**

```bash
git add cluster/apps/default/nextcloud/app/templates/nfs-data-pv.yaml
git commit -m "feat(nextcloud): add static NFS PV/PVC for user data on QNAP"
```

---

### Task 2: Bitwarden secrets + app scaffold

**Files:**
- Create (manual, in Bitwarden Secrets Manager, not git): 5 new secret entries (see table below)
- Create: `cluster/apps/default/nextcloud/app-config.yaml`

**Interfaces:**
- Produces: two ArgoCD Application entries (`nextcloud-onlyoffice`, `nextcloud-app` per the ApplicationSet's `{{.values.appName}}-{{.appSubfolder}}` naming), both targeting namespace `nextcloud`. All later tasks assume this file exists with `enabled: "true"` for both.
- Produces: Bitwarden UUIDs referenced by Task 3 (S3 creds), Task 4 (OnlyOffice JWT), Task 5 (admin creds), Task 6 (OIDC client secret).

- [ ] **Step 1: Create Bitwarden secret entries (manual, non-git)**

In Bitwarden Secrets Manager, create these entries and note each UUID — they're needed verbatim in later tasks:

| Bitwarden entry name | Used by |
|---|---|
| `nextcloud-admin-username` | Task 5 (Nextcloud admin bootstrap user) |
| `nextcloud-admin-password` | Task 5 (Nextcloud admin bootstrap user) |
| `nextcloud-s3-access-key-id` | Task 3 (CNPG backup to QNAP S3) |
| `nextcloud-s3-secret-access-key` | Task 3 (CNPG backup to QNAP S3) |
| `nextcloud-onlyoffice-jwt-secret` | Task 4 + Task 9 (shared JWT between OnlyOffice and the connector app) |
| `nextcloud-oidc-client-secret` | Task 6 (Keycloak client secret) |

- [ ] **Step 2: Write `app-config.yaml`**

Create `cluster/apps/default/nextcloud/app-config.yaml`:

```yaml
- enabled: "true"
  appSubfolder: onlyoffice
  namespace: nextcloud
  syncWave: "1"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
- enabled: "true"
  appSubfolder: app
  namespace: nextcloud
  syncWave: "2"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

`onlyoffice` syncs first (`syncWave: "1"`) so its ClusterIP Service exists before the `app` subfolder's Nextcloud connector tries to reach it — DNS/Service existence, not pod-readiness, is all that's required at sync time.

- [ ] **Step 3: Verify against the appSubfolder pattern**

Run: `yamllint cluster/apps/default/nextcloud/app-config.yaml`
Expected: no errors. Cross-check against `cluster/apps/core/rook-ceph/app-config.yaml` — structure (list of entries, each with `appSubfolder`/`syncWave`/`syncPolicy`/`plugin`) should match.

- [ ] **Step 4: Commit**

```bash
git add cluster/apps/default/nextcloud/app-config.yaml
git commit -m "feat(nextcloud): add ArgoCD app-config for nextcloud+onlyoffice"
```

---

### Task 3: Postgres database (pgsql-cnpg) + S3 backup

**Files:**
- Create: `cluster/apps/default/nextcloud/app/Chart.yaml`
- Create: `cluster/apps/default/nextcloud/app/values.yaml` (Postgres section only — Nextcloud app section added in Task 5)
- Create: `cluster/apps/default/nextcloud/app/templates/s3-externalsecret.yaml`

**Interfaces:**
- Produces: CNPG cluster `nextclouddb-cnpg` with services `nextclouddb-cnpg-rw` (read-write) and app credentials Secret `nextclouddb-cnpg-app` (keys `username`, `password`) — Task 5's `externalDatabase` block consumes these exact names.

- [ ] **Step 1: Write `Chart.yaml`**

Create `cluster/apps/default/nextcloud/app/Chart.yaml`:

```yaml
---
apiVersion: v2
name: nextcloud-subchart
type: application
version: 1.0.0
appVersion: "34.0.1"
dependencies:
  - name: nextcloud
    version: 9.2.0
    repository: https://nextcloud.github.io/helm/
  - name: pgsql-cnpg
    version: 1.3.2
    repository: file://../../../../../charts/pgsql-cnpg/
```

- [ ] **Step 2: Write the Postgres section of `values.yaml`**

Create `cluster/apps/default/nextcloud/app/values.yaml` with (Nextcloud-specific keys added in Task 5):

```yaml
pgsql-cnpg:
  name: nextclouddb
  imageName: ghcr.io/cloudnative-pg/postgresql:15.10-standard-bookworm
  instances: 2
  storage:
    size: 10Gi
  resources:
    requests:
      memory: 200Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  monitoring:
    enablePodMonitor: true
  retentionPolicy: "10d"
  objectStore:
    destinationPath: "s3://k8s-at-home-backup/cnpg/nextcloud"
    endpointURL: <secret:s3_endpoint>
    s3Credentials:
      accessKeyId:
        name: nextcloud-s3-secret
        key: S3_ACCESS_KEY_ID
      secretAccessKey:
        name: nextcloud-s3-secret
        key: S3_ACCESS_SECRET_KEY
  instanceSidecarConfiguration:
    env:
      - name: AWS_REQUEST_CHECKSUM_CALCULATION
        value: when_required
      - name: AWS_RESPONSE_CHECKSUM_VALIDATION
        value: when_required
  scheduledBackups:
    - name: nextclouddb-cnpg-backup
      spec:
        immediate: true
        schedule: "15 0 0 * * *"
        backupOwnerReference: self
```

`AWS_REQUEST_CHECKSUM_CALCULATION`/`AWS_RESPONSE_CHECKSUM_VALIDATION` are required for every CNPG cluster backing up to this QNAP S3 endpoint (botocore ≥1.34 checksum incompatibility) — same workaround as every other CNPG cluster in this repo. Backup schedule offset by 10 minutes from gitea's (`5 0 0 * * *`) to avoid both hitting the NAS at once.

- [ ] **Step 3: Write the S3 credentials ExternalSecret**

Create `cluster/apps/default/nextcloud/app/templates/s3-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nextcloud-s3-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: nextcloud-s3-secret
    creationPolicy: Owner
  data:
    - secretKey: S3_ACCESS_KEY_ID
      remoteRef:
        key: "<BITWARDEN_UUID_nextcloud-s3-access-key-id>" #gitleaks:allow #NEXTCLOUD_S3_ACCESS_KEY
    - secretKey: S3_ACCESS_SECRET_KEY
      remoteRef:
        key: "<BITWARDEN_UUID_nextcloud-s3-secret-access-key>" #gitleaks:allow #NEXTCLOUD_S3_SECRET_KEY
```

Replace both `<BITWARDEN_UUID_...>` placeholders with the actual UUIDs noted in Task 2 Step 1 before committing.

- [ ] **Step 4: Render and verify**

Run: `helm dependency update cluster/apps/default/nextcloud/app && helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml`
Expected: renders without error; output includes a `Cluster` resource named `nextclouddb-cnpg` (from `pgsql-cnpg/templates/cnpg.yaml`) and an `ExternalSecret` named `nextcloud-s3-secret`.

- [ ] **Step 5: Commit**

```bash
git add cluster/apps/default/nextcloud/app/Chart.yaml cluster/apps/default/nextcloud/app/values.yaml cluster/apps/default/nextcloud/app/templates/s3-externalsecret.yaml
git commit -m "feat(nextcloud): add Postgres (CNPG) with S3 backup"
```

---

### Task 4: OnlyOffice Document Server (local chart)

**Files:**
- Create: `charts/onlyoffice-documentserver/Chart.yaml`
- Create: `charts/onlyoffice-documentserver/values.yaml`
- Create: `charts/onlyoffice-documentserver/templates/deployment.yaml`
- Create: `charts/onlyoffice-documentserver/templates/service.yaml`
- Create: `charts/onlyoffice-documentserver/templates/pvc.yaml`
- Create: `cluster/apps/default/nextcloud/onlyoffice/Chart.yaml`
- Create: `cluster/apps/default/nextcloud/onlyoffice/values.yaml`
- Create: `cluster/apps/default/nextcloud/onlyoffice/templates/jwt-externalsecret.yaml`

**Interfaces:**
- Produces: Service `onlyoffice` on port 80 in namespace `nextcloud`, reachable at `onlyoffice.nextcloud.svc.cluster.local` — Task 9's `occ config:app:set onlyoffice DocumentServerInternalUrl` consumes this exact DNS name.
- Produces: Secret `onlyoffice-jwt-secret` with key `JWT_SECRET` — consumed by this task's own Deployment env and by Task 9's `occ config:app:set onlyoffice jwt_secret`.

- [ ] **Step 1: Write the local chart's `Chart.yaml`**

Create `charts/onlyoffice-documentserver/Chart.yaml`:

```yaml
apiVersion: v2
name: onlyoffice-documentserver
description: OnlyOffice Document Server (Community Edition)
type: application
version: 1.0.0
appVersion: "9.0.0"
```

- [ ] **Step 2: Write the local chart's `values.yaml`**

Create `charts/onlyoffice-documentserver/values.yaml`:

```yaml
namespace: nextcloud
image:
  repository: onlyoffice/documentserver
  tag: 9.0.0
port: 80
jwt:
  secretName: onlyoffice-jwt-secret
  secretKey: JWT_SECRET
storage:
  storageClass: ceph-block
  size: 5Gi
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: "1"
    memory: 1Gi
```

- [ ] **Step 3: Write the Deployment template**

Create `charts/onlyoffice-documentserver/templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: onlyoffice
  namespace: {{ .Values.namespace }}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: onlyoffice
  template:
    metadata:
      labels:
        app: onlyoffice
    spec:
      containers:
        - name: onlyoffice
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.port }}
          env:
            - name: JWT_ENABLED
              value: "true"
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.jwt.secretName }}
                  key: {{ .Values.jwt.secretKey }}
            - name: JWT_HEADER
              value: "Authorization"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /healthcheck
              port: {{ .Values.port }}
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /healthcheck
              port: {{ .Values.port }}
            initialDelaySeconds: 60
            periodSeconds: 30
          volumeMounts:
            - name: data
              mountPath: /var/www/onlyoffice/Data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: onlyoffice-data
```

- [ ] **Step 4: Write the Service and PVC templates**

Create `charts/onlyoffice-documentserver/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: onlyoffice
  namespace: {{ .Values.namespace }}
spec:
  selector:
    app: onlyoffice
  ports:
    - port: 80
      targetPort: {{ .Values.port }}
```

Create `charts/onlyoffice-documentserver/templates/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: onlyoffice-data
  namespace: {{ .Values.namespace }}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: {{ .Values.storage.storageClass }}
  resources:
    requests:
      storage: {{ .Values.storage.size }}
```

- [ ] **Step 5: Wire the app's `Chart.yaml`, `values.yaml`, and JWT `ExternalSecret`**

Create `cluster/apps/default/nextcloud/onlyoffice/Chart.yaml`:

```yaml
apiVersion: v2
name: onlyoffice-subchart
type: application
version: 1.0.0
appVersion: "9.0.0"
dependencies:
  - name: onlyoffice-documentserver
    version: 1.0.0
    repository: file://../../../../../charts/onlyoffice-documentserver/
```

Create `cluster/apps/default/nextcloud/onlyoffice/values.yaml`:

```yaml
onlyoffice-documentserver:
  namespace: nextcloud
```

Create `cluster/apps/default/nextcloud/onlyoffice/templates/jwt-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: onlyoffice-jwt-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: onlyoffice-jwt-secret
    creationPolicy: Owner
  data:
    - secretKey: JWT_SECRET
      remoteRef:
        key: "<BITWARDEN_UUID_nextcloud-onlyoffice-jwt-secret>" #gitleaks:allow #ONLYOFFICE_JWT_SECRET
```

Replace `<BITWARDEN_UUID_nextcloud-onlyoffice-jwt-secret>` with the UUID from Task 2 Step 1.

- [ ] **Step 6: Render and verify**

Run: `helm dependency update charts/onlyoffice-documentserver && helm dependency update cluster/apps/default/nextcloud/onlyoffice && helm template onlyoffice cluster/apps/default/nextcloud/onlyoffice -f cluster/apps/default/nextcloud/onlyoffice/values.yaml`
Expected: renders a `Deployment`, `Service`, `PersistentVolumeClaim` (all named `onlyoffice`/`onlyoffice-data`) and an `ExternalSecret` named `onlyoffice-jwt-secret`, all in namespace `nextcloud`, no errors.

- [ ] **Step 7: Commit**

```bash
git add charts/onlyoffice-documentserver cluster/apps/default/nextcloud/onlyoffice
git commit -m "feat(nextcloud): add OnlyOffice Document Server (Community)"
```

---

### Task 5: Nextcloud Helm release wiring

**Files:**
- Modify: `cluster/apps/default/nextcloud/app/values.yaml`
- Create: `cluster/apps/default/nextcloud/app/templates/admin-externalsecret.yaml`

**Interfaces:**
- Consumes: `nextclouddb-cnpg-rw` / `nextclouddb-cnpg-app` (Task 3), `nextcloud-data-pvc` (Task 1), `onlyoffice.nextcloud.svc.cluster.local` (Task 4, referenced in comments only — actual connector wiring happens at runtime in Task 9).
- Produces: Nextcloud Deployment + Service `nextcloud` (chart default naming) and native `HTTPRoute` (chart-managed, not a hand-written template) at `nextcloud.<private-domain>`.

- [ ] **Step 1: Write the admin credentials ExternalSecret**

Create `cluster/apps/default/nextcloud/app/templates/admin-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nextcloud-admin-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: nextcloud-admin-secret
    creationPolicy: Owner
  data:
    - secretKey: nextcloud-username
      remoteRef:
        key: "<BITWARDEN_UUID_nextcloud-admin-username>" #gitleaks:allow #NEXTCLOUD_ADMIN_USERNAME
    - secretKey: nextcloud-password
      remoteRef:
        key: "<BITWARDEN_UUID_nextcloud-admin-password>" #gitleaks:allow #NEXTCLOUD_ADMIN_PASSWORD
```

Replace both placeholders with UUIDs from Task 2 Step 1.

- [ ] **Step 2: Add the Nextcloud section to `values.yaml`**

Append to `cluster/apps/default/nextcloud/app/values.yaml` (alongside the `pgsql-cnpg:` block from Task 3):

```yaml
nextcloud:
  image:
    flavor: fpm-alpine
  nextcloud:
    host: nextcloud.<secret:private-domain>
    existingSecret:
      enabled: true
      secretName: nextcloud-admin-secret
      usernameKey: nextcloud-username
      passwordKey: nextcloud-password
    trustedDomains:
      - nextcloud.<secret:private-domain>
    datadir: /var/www/html/data
    persistence:
      subPath:
    mail:
      enabled: false
    configs:
      proxy.config.php: |-
        <?php
        $CONFIG = array (
          'check_data_directory_permissions' => false,
          'forwarded_for_headers' => array('HTTP_X_FORWARDED_FOR'),
          'mail_smtpmode' => 'null',
          'trusted_proxies' => array(
            0 => '127.0.0.1',
            1 => '10.244.0.0/16',
          ),
        ); ?>
  phpClientHttpsFix:
    enabled: true
    protocol: https
  externalDatabase:
    enabled: true
    type: postgresql
    host: nextclouddb-cnpg-rw
    database: app
    existingSecret:
      enabled: true
      secretName: nextclouddb-cnpg-app
      usernameKey: username
      passwordKey: password
  redis:
    enabled: true
    auth:
      enabled: true
      password: "changeme-see-existingSecret-below"
  externalRedis:
    enabled: true
    host: nextcloud-redis-master
    existingSecret:
      enabled: true
      secretName: nextcloud-redis
      passwordKey: redis-password
  nginx:
    enabled: true
  persistence:
    enabled: true
    accessMode: ReadWriteOnce
    size: 5Gi
    storageClass: ceph-block
    nextcloudData:
      enabled: true
      existingClaim: nextcloud-data-pvc
  cronjob:
    enabled: true
    type: sidecar
  httpRoute:
    enabled: true
    hostnames:
      - nextcloud.<secret:private-domain>
    parentRefs:
      - name: envoy-external
        namespace: envoy-gateway
        sectionName: https
    rules:
      - matches:
          - path:
              type: PathPrefix
              value: "/"
        filters:
          - type: ResponseHeaderModifier
            responseHeaderModifier:
              add:
                - name: strict-transport-security
                  value: max-age=31536000
```

Notes:
- `redis.auth.password` is a chart-required field even though `externalRedis.existingSecret` is what Nextcloud's app container actually reads at runtime — the bundled Bitnami Redis subchart generates its own real secret (`nextcloud-redis`) regardless of this value; it's not used in practice but the chart's schema requires a non-empty string.
- `persistence.nextcloudData.existingClaim: nextcloud-data-pvc` binds to the static PV/PVC from Task 1 — this is the chart's native split-storage mechanism (`persistence.enabled` PVC handles `/var/www/html`, `persistence.nextcloudData` handles the datadir), no postRenderer patch needed.
- `cronjob.type: sidecar` runs Nextcloud's background jobs as a sidecar container (requires root) rather than a separate CronJob resource — simpler for a single-instance family deployment.

- [ ] **Step 3: Render and inspect the Redis wiring**

Run: `helm dependency update cluster/apps/default/nextcloud/app && helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml | grep -A3 REDIS_HOST`
Expected: the rendered Nextcloud Deployment/StatefulSet has `REDIS_HOST=nextcloud-redis-master` and a `REDIS_HOST_PASSWORD` env sourced from `secretKeyRef: nextcloud-redis`/`redis-password`. If these envs are missing or point elsewhere, inspect the chart's `templates/deployment.yaml` (`helm template ... --show-only charts/nextcloud/templates/deployment.yaml`) to find the actual conditional and adjust `externalRedis.host` to match the real Bitnami Redis subchart service name before proceeding.

- [ ] **Step 4: Render and verify the datadir mount**

Run: `helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml | grep -B5 -A5 nextcloud-data-pvc`
Expected: a `volumeMounts` entry mounting a volume backed by `claimName: nextcloud-data-pvc` at the datadir path (`/var/www/html/data`), separate from the `persistence`-PVC-backed `/var/www/html` mount.

- [ ] **Step 5: Full render + lint**

Run: `helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml > /dev/null && task lint:all`
Expected: no errors from either command.

- [ ] **Step 6: Commit**

```bash
git add cluster/apps/default/nextcloud/app/values.yaml cluster/apps/default/nextcloud/app/templates/admin-externalsecret.yaml
git commit -m "feat(nextcloud): wire Nextcloud Helm release (storage, db, redis, httproute)"
```

---

### Task 6: Keycloak OIDC client

**Files:**
- Create (manual, in Keycloak admin console, not git): OIDC client `nextcloud` in the `home` realm
- Create: `cluster/apps/default/nextcloud/app/templates/oidc-externalsecret.yaml`

**Interfaces:**
- Produces: Secret `nextcloud-oidc-secret` with key `client_secret` — consumed by Task 9's `occ user_oidc:provider` command (read via `kubectl get secret ... -o jsonpath`, not injected as an env var, since `user_oidc` provider registration happens via one-time CLI, not `config.php`).

- [ ] **Step 1: Register the Keycloak client (manual, non-git)**

In the Keycloak admin console (realm `home`, same realm Harbor uses per `harbor-oidc-externalsecret.yaml`): Clients → Create client → Client ID `nextcloud`, Client authentication: On (confidential), Standard flow: enabled. Redirect URIs: `https://nextcloud.<private-domain>/apps/user_oidc/code`. Save, then copy the generated Client Secret from the Credentials tab.

- [ ] **Step 2: Store the client secret in Bitwarden and write the ExternalSecret**

Add the copied secret value to the Bitwarden entry `nextcloud-oidc-client-secret` created in Task 2 Step 1 (or create it now if skipped earlier), then create `cluster/apps/default/nextcloud/app/templates/oidc-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nextcloud-oidc-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: nextcloud-oidc-secret
    creationPolicy: Owner
  data:
    - secretKey: client_secret
      remoteRef:
        key: "<BITWARDEN_UUID_nextcloud-oidc-client-secret>" #gitleaks:allow #NEXTCLOUD_OIDC_CLIENT_SECRET
```

- [ ] **Step 3: Render and verify**

Run: `helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml | grep -A10 "name: nextcloud-oidc-secret"`
Expected: the `ExternalSecret` renders with `secretKey: client_secret`.

- [ ] **Step 4: Commit**

```bash
git add cluster/apps/default/nextcloud/app/templates/oidc-externalsecret.yaml
git commit -m "feat(nextcloud): add Keycloak OIDC client secret"
```

---

### Task 7: Volsync backup for app-state PVC

**Files:**
- Create: `cluster/apps/default/nextcloud/app/templates/volsync-restic-externalsecret.yaml`
- Create: `cluster/apps/default/nextcloud/app/templates/volsync.yaml`

**Interfaces:**
- Consumes: the `persistence`-backed PVC from Task 5 (chart-managed name — verify exact claim name via the Task 5 Step 5 render output before writing `sourcePVC`, since the official chart, unlike the local `pgsql-cnpg`/`gitea-subchart` pattern, generates its own PVC name rather than taking `existingClaim` by default when `persistence.enabled: true` with no `existingClaim` set).

- [ ] **Step 1: Confirm the app-state PVC name**

Run: `helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml | grep -B3 "kind: PersistentVolumeClaim" | grep name:`
Expected output includes a PVC named `nextcloud` (chart's release-name default) alongside the static `nextcloud-data-pvc` from Task 1 — use whichever name appears for the Ceph-backed (non-NFS) claim as `sourcePVC` in Step 3 below.

- [ ] **Step 2: Write the restic repository ExternalSecret**

Create `cluster/apps/default/nextcloud/app/templates/volsync-restic-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nextcloud-restic
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  target:
    name: nextcloud-restic-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        RESTIC_REPOSITORY: '{{`{{ .REPOSITORY_TEMPLATE }}`}}/nextcloud'
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
```

These four UUIDs are the same shared Volsync/restic credentials Gitea uses (`cluster/apps/default/gitea/templates/volsync.yaml`) — reused across apps, not per-app secrets, since they're just the repository/prefix + shared restic password.

- [ ] **Step 3: Write the ReplicationSource**

Create `cluster/apps/default/nextcloud/app/templates/volsync.yaml`, replacing `<PVC_NAME_FROM_STEP_1>` with the actual name found in Step 1:

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: nextcloud
spec:
  sourcePVC: <PVC_NAME_FROM_STEP_1>
  trigger:
    schedule: "40 */12 * * *"
  restic:
    copyMethod: Snapshot
    pruneIntervalDays: 14
    repository: nextcloud-restic-secret
    retain:
      daily: 6
      weekly: 4
      monthly: 2
```

Note: this backs up **only** the small Ceph-backed app-state PVC (config, installed apps) — not the 600GB NFS datadir, which relies on QNAP-native snapshots per the design doc's decision to skip offsite backup for user data.

- [ ] **Step 4: Render and verify**

Run: `helm template nextcloud cluster/apps/default/nextcloud/app -f cluster/apps/default/nextcloud/app/values.yaml | grep -A5 "kind: ReplicationSource"`
Expected: renders with the correct `sourcePVC` value (not the placeholder).

- [ ] **Step 5: Commit**

```bash
git add cluster/apps/default/nextcloud/app/templates/volsync-restic-externalsecret.yaml cluster/apps/default/nextcloud/app/templates/volsync.yaml
git commit -m "feat(nextcloud): add Volsync backup for app-state PVC"
```

---

### Task 8: Deploy (requires explicit user confirmation)

**Files:** none (cluster state change only)

**Interfaces:**
- Consumes: everything from Tasks 1-7, committed and pushed.

- [ ] **Step 1: Push branch and open PR**

```bash
git push -u origin feat/nextcloud-onedrive-replacement
gh pr create --title "feat(nextcloud): self-hosted Nextcloud + OnlyOffice (OneDrive replacement)" --body "$(cat <<'EOF'
## Summary
- Nextcloud + OnlyOffice Document Server (Community), split storage (Ceph app-state + QNAP NFS user data)
- Keycloak SSO, Cloudflare-tunneled external access, CNPG Postgres with S3 backup, Volsync for app state
- Design: docs/superpowers/specs/2026-07-02-nextcloud-onedrive-replacement-design.md

## Test plan
- [ ] `helm template` renders clean for both `app` and `onlyoffice` subfolders
- [ ] `task lint:all` passes
- [ ] ArgoCD sync succeeds for both Applications
- [ ] Nextcloud login page loads at https://nextcloud.<private-domain>
EOF
)"
```

- [ ] **Step 2: STOP — get explicit user confirmation before this step**

Do not proceed past this point without the user explicitly confirming. Merging the PR and letting ArgoCD auto-sync (since `syncPolicy.enabled: true` was set in Task 2) will create real cluster resources, provision a real Postgres cluster, and mount the real QNAP NFS share. Ask: "PR is up, ready to merge and let ArgoCD sync both apps?"

- [ ] **Step 3: After confirmation — merge and watch sync**

```bash
gh pr merge --squash
kubectl -n argocd get applications nextcloud-onlyoffice nextcloud-app -w
```
Expected: both Applications reach `Synced`/`Healthy` within a few minutes. If `nextcloud-app` fails health checks, check `kubectl -n nextcloud get pods` and `kubectl -n nextcloud logs deploy/nextcloud -c nextcloud` first — most likely causes at this stage are the Redis env mismatch flagged in Task 5 Step 3, or the CNPG cluster not yet reporting ready (`kubectl -n nextcloud get cluster nextclouddb-cnpg`).

---

### Task 9: Post-deploy runtime configuration (requires explicit user confirmation)

**Files:** none (runtime `occ` configuration only, not GitOps-managed — Nextcloud app config lives in its database, not in a file this repo tracks)

**Interfaces:**
- Consumes: `nextcloud-oidc-secret` (Task 6), `onlyoffice-jwt-secret` (Task 4), running `nextcloud` Deployment (Task 8).

- [ ] **Step 1: STOP — get explicit user confirmation before running any command in this task**

These are live `kubectl exec` commands that change application state (enable apps, register the OIDC provider, write the OnlyOffice connector config) — not declarative, not reviewable via `git diff`. Confirm with the user before running each block.

- [ ] **Step 2: Enable the required Nextcloud apps**

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ app:enable user_oidc
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ app:enable onlyoffice
```
Expected: both commands print `<app> enabled`.

- [ ] **Step 3: Register the Keycloak OIDC provider**

```bash
CLIENT_SECRET=$(kubectl -n nextcloud get secret nextcloud-oidc-secret -o jsonpath='{.data.client_secret}' | base64 -d)
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ user_oidc:provider keycloak \
  --clientid="nextcloud" \
  --clientsecret="$CLIENT_SECRET" \
  --discoveryuri="https://l.<private-domain>/realms/home/.well-known/openid-configuration" \
  --unique-uid=0 \
  --scope="openid email profile"
```
Expected: prints the created provider's identifier and ID. Verify: `kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ user_oidc:provider:list` shows the `keycloak` provider.

- [ ] **Step 4: Wire the OnlyOffice connector**

```bash
JWT_SECRET=$(kubectl -n nextcloud get secret onlyoffice-jwt-secret -o jsonpath='{.data.JWT_SECRET}' | base64 -d)
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ config:app:set onlyoffice DocumentServerInternalUrl --value="http://onlyoffice.nextcloud.svc.cluster.local/"
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ config:app:set onlyoffice StorageUrl --value="https://nextcloud.<private-domain>/"
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ config:app:set onlyoffice jwt_secret --value="$JWT_SECRET"
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ config:app:set onlyoffice jwt_header --value="Authorization"
```
Expected: each `config:app:set` prints confirmation of the value set.

- [ ] **Step 5: Verify end-to-end**

Open `https://nextcloud.<private-domain>` in a browser. Expected: login page shows a "Log in with Keycloak" (or "keycloak") button in addition to the local login form. Log in via Keycloak, confirm the account auto-provisions. Create a test `.docx` file and confirm it opens in the OnlyOffice editor in-browser without an error banner.

- [ ] **Step 6: Disable local login for non-admin flows (optional hardening)**

No git change — this is a Nextcloud admin-UI setting (Settings → Security) to restrict the login form to OIDC only, if desired, once OIDC is confirmed working for at least one account.

---

### Task 10: Per-user OneDrive migration (runbook, repeat per family member)

**Files:** none (operational runbook, not a code change — record progress by checking off family members below as you go, editing this file directly and committing the checkbox updates)

**Interfaces:**
- Consumes: a working Nextcloud instance from Tasks 8-9, an `rclone` install on a workstation with LAN access to the QNAP, and one OneDrive `rclone` remote configured per family member (`rclone config`, type `onedrive`, done once per person outside this plan — OAuth device-code flow, non-git).

- [ ] **Step 1: Mount the QNAP NFS share on your migration workstation**

```bash
sudo mkdir -p /mnt/nextcloud-data
sudo mount -t nfs -o nfsvers=4.2 qnap.<private-domain>:/nextcloud-data /mnt/nextcloud-data
```

- [ ] **Step 2: Pick the first family member and confirm their Nextcloud account exists**

Have them log in once via Keycloak SSO (Task 9 Step 5) so their Nextcloud user + home folder (`/mnt/nextcloud-data/<username>/`) is provisioned, then confirm:

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ user:list | grep <username>
ls -la /mnt/nextcloud-data/<username>/files/
```
Expected: user appears in `occ user:list`; `files/` directory exists (auto-created on first login).

- [ ] **Step 3: Sync that user's OneDrive**

```bash
rclone sync onedrive-<username>:/ /mnt/nextcloud-data/<username>/files/ --progress --transfers 8 --checkers 16
```
Expected: completes without `rclone` errors. Re-run once more (idempotent) to confirm a clean second pass with zero transfers.

- [ ] **Step 4: Index the synced files into Nextcloud**

```bash
kubectl -n nextcloud exec deploy/nextcloud -c nextcloud -- php occ files:scan --path="/<username>/files"
```
Expected: prints a summary (`X folders / Y files`) with no errors.

- [ ] **Step 5: Spot-check**

Log in as `<username>` at `https://nextcloud.<private-domain>`. Confirm folder structure matches OneDrive. Open 2-3 files with long names, special characters, or nested deep paths specifically (these are the most common `occ files:scan` failure mode coming from OneDrive) — confirm they opened correctly and, for a `.docx`/`.xlsx`, that OnlyOffice can open them.

- [ ] **Step 6: Mark this family member done, move to the next**

Family members migrated (edit this checklist as you go, commit after each):
- [ ] `<family-member-1>`
- [ ] `<family-member-2>`
- [ ] `<family-member-3>`
- [ ] `<family-member-4>`

```bash
git add docs/superpowers/plans/2026-07-02-nextcloud-onedrive-replacement.md
git commit -m "docs(nextcloud): mark <family-member> migration complete"
```

Repeat Steps 2-6 for each remaining family member. Once everyone is migrated and spot-checked, this plan is complete — move it to `.archive/.plans/` per the repo's plan-completion convention (note: this plan lives under `docs/superpowers/plans/`, not `.plans/`, per the brainstorming/writing-plans skill convention used for this feature — no `.plans/list.md` entry was created for it).

## Not covered by this plan

- **Cloudflare rate limiting** on `/login` and `/index.php/login/v2` (design doc, Networking & Exposure section) — recommended hardening now that this is internet-facing family data, but it's a `provision/terraform/cloudflare/` change independent of the cluster deploy. Worth a follow-up once the app is live and login patterns are understood.
- **QNAP snapshot schedule** — already enabled per the user's confirmation during brainstorming; no action needed here.
