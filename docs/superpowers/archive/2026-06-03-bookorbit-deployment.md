# BookOrbit Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy BookOrbit v1.8.0 as a self-hosted ebook reader in the `bookorbit` namespace with CNPG PostgreSQL+pgvector, NFS ebook library, OIDC SSO via Keycloak, and Volsync/S3 backup.

**Architecture:** `app-template` chart wraps the BookOrbit container; `pgsql-cnpg` local chart provides a 2-replica CNPG cluster with pgvector and barman-cloud S3 backups; `volsync` local chart backs up the `/data` PVC via Restic; NFS PV/PVC and ExternalSecret are manual templates.

**Tech Stack:** Helm (app-template 5.0.1, pgsql-cnpg 1.3.2, volsync 1.0.0), ArgoCD ApplicationSet with `argocd-secret-replacer` CMP, Bitwarden ESO, CNPG operator, barman-cloud plugin, Envoy Gateway HTTPRoute.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `cluster/apps/default/bookorbit/app-config.yaml` | Create | ArgoCD ApplicationSet entry |
| `cluster/apps/default/bookorbit/Chart.yaml` | Create | Helm chart + 3 dependencies |
| `cluster/apps/default/bookorbit/values.yaml` | Create | All app, DB, backup, route config |
| `cluster/apps/default/bookorbit/templates/externalsecret.yaml` | Create | Bitwarden → `bookorbit-secrets` K8s Secret |
| `cluster/apps/default/bookorbit/templates/nfs-ebooks.yaml` | Create | NFS PV + PVC for `/books` mount |

---

## Task 1: Pre-deploy prerequisites (manual — no code)

Complete all steps before Task 2. Nothing to commit.

**Files:** None

- [ ] **Step 1: Generate and store JWT_SECRET in Bitwarden**

  In Bitwarden Secrets Manager, create a new secret:
  - Name: `BOOKORBIT_JWT_SECRET`
  - Value: `openssl rand -hex 32`

  Note the item UUID — needed in Task 4.

- [ ] **Step 2: Generate and store SETUP_BOOTSTRAP_TOKEN in Bitwarden**

  Create a second Bitwarden secret:
  - Name: `BOOKORBIT_SETUP_BOOTSTRAP_TOKEN`
  - Value: `openssl rand -hex 16`

  Note the item UUID.

- [ ] **Step 3: Create Keycloak OIDC client**

  In Keycloak admin (`https://keycloak.<domain>`):
  1. Realm → Clients → Create client
  2. Client type: `OpenID Connect`
  3. Client ID: `bookorbit`
  4. Client authentication: ON (confidential)
  5. Valid redirect URIs: `https://bookorbit.<domain>/api/v1/auth/oidc/callback`
  6. Web origins: `https://bookorbit.<domain>`
  7. Save → Credentials tab → copy the client secret

- [ ] **Step 4: Store OIDC credentials in Bitwarden**

  Create three Bitwarden secrets:
  - `BOOKORBIT_OIDC_CLIENT_ID` = `bookorbit`
  - `BOOKORBIT_OIDC_CLIENT_SECRET` = client secret from Step 3
  - `BOOKORBIT_OIDC_ISSUER_URL` = `https://keycloak.<domain>/realms/<realm-name>`

  Note the UUID for each.

- [ ] **Step 5: Record shared S3 Bitwarden item IDs (from honcho)**

  These items already exist — just note the IDs for use in Task 4:
  - `S3_ACCESS_KEY_ID`: `e00e1e38-ae37-479a-8b46-b409016331eb`
  - `S3_ACCESS_SECRET_KEY`: `4d5a418c-82ed-4b8e-bfbf-b40901634ea4`

---

## Task 2: Scaffold Chart.yaml and vendor dependencies

**Files:**
- Create: `cluster/apps/default/bookorbit/Chart.yaml`
- Create: `cluster/apps/default/bookorbit/Chart.lock` (generated)
- Create: `cluster/apps/default/bookorbit/charts/` (vendored tarballs)

- [ ] **Step 1: Create directory and Chart.yaml**

  ```bash
  mkdir -p cluster/apps/default/bookorbit/templates
  ```

  Create `cluster/apps/default/bookorbit/Chart.yaml`:

  ```yaml
  ---
  apiVersion: v2
  name: bookorbit
  type: application
  version: 1.0.0
  dependencies:
    - name: app-template
      version: 5.0.1
      repository: https://bjw-s-labs.github.io/helm-charts
    - name: pgsql-cnpg
      version: 1.3.2
      repository: file://../../../../charts/pgsql-cnpg/
    - name: volsync
      version: 1.0.0
      repository: file://../../../../charts/volsync/
  ```

- [ ] **Step 2: Vendor dependencies**

  ```bash
  cd cluster/apps/default/bookorbit
  helm dependency update .
  ```

  Expected output: Saves `charts/app-template-5.0.1.tgz`, `charts/pgsql-cnpg-1.3.2.tgz`, `charts/volsync-1.0.0.tgz` and writes `Chart.lock`.

- [ ] **Step 3: Pin BookOrbit image digest**

  ```bash
  docker buildx imagetools inspect ghcr.io/bookorbit/bookorbit:v1.8.0 2>/dev/null | grep Digest
  ```

  Note the `sha256:...` value — you will use `v1.8.0@sha256:<digest>` as the image tag in Task 5.

- [ ] **Step 4: Commit**

  ```bash
  git add cluster/apps/default/bookorbit/Chart.yaml \
          cluster/apps/default/bookorbit/Chart.lock \
          cluster/apps/default/bookorbit/charts/
  git commit -m "feat(bookorbit): scaffold chart with app-template, pgsql-cnpg, volsync deps"
  ```

---

## Task 3: Create NFS PV/PVC template

**Files:**
- Create: `cluster/apps/default/bookorbit/templates/nfs-ebooks.yaml`

The `<secret:private-domain>` token is substituted at sync time by the `argocd-secret-replacer` CMP plugin (enabled via `SECRET_PROVIDER: cluster-secrets` in app-config.yaml). PVs are cluster-scoped; the PVC is namespace-scoped to `bookorbit`.

- [ ] **Step 1: Create templates/nfs-ebooks.yaml**

  ```yaml
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: bookorbit-ebooks-pv
  spec:
    storageClassName: ebooks
    claimRef:
      name: bookorbit-ebooks-pvc
      namespace: bookorbit
    capacity:
      storage: 50Gi
    accessModes:
      - ReadWriteMany
    persistentVolumeReclaimPolicy: Retain
    nfs:
      server: qnap.<secret:private-domain>
      path: "/ebooks"
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
    name: bookorbit-ebooks-pvc
    namespace: bookorbit
  spec:
    volumeName: bookorbit-ebooks-pv
    accessModes:
      - ReadWriteMany
    storageClassName: ebooks
    resources:
      requests:
        storage: 50Gi
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add cluster/apps/default/bookorbit/templates/nfs-ebooks.yaml
  git commit -m "feat(bookorbit): add NFS ebooks PV/PVC template"
  ```

---

## Task 4: Create ExternalSecret template

**Prerequisite:** All Bitwarden item UUIDs from Task 1 must be known.

**Files:**
- Create: `cluster/apps/default/bookorbit/templates/externalsecret.yaml`

- [ ] **Step 1: Create templates/externalsecret.yaml**

  Replace the `<UUID-...>` placeholders with the actual Bitwarden item UUIDs from Task 1:

  ```yaml
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: bookorbit-secrets
    namespace: bookorbit
  spec:
    secretStoreRef:
      kind: ClusterSecretStore
      name: bitwarden
    refreshInterval: 1h
    target:
      name: bookorbit-secrets
      creationPolicy: Owner
    data:
      - secretKey: JWT_SECRET
        remoteRef:
          key: "<UUID-BOOKORBIT_JWT_SECRET>" #gitleaks:allow #BOOKORBIT_JWT_SECRET
      - secretKey: SETUP_BOOTSTRAP_TOKEN
        remoteRef:
          key: "<UUID-BOOKORBIT_SETUP_BOOTSTRAP_TOKEN>" #gitleaks:allow #BOOKORBIT_SETUP_BOOTSTRAP_TOKEN
      - secretKey: OIDC_CLIENT_ID
        remoteRef:
          key: "<UUID-BOOKORBIT_OIDC_CLIENT_ID>" #gitleaks:allow #BOOKORBIT_OIDC_CLIENT_ID
      - secretKey: OIDC_CLIENT_SECRET
        remoteRef:
          key: "<UUID-BOOKORBIT_OIDC_CLIENT_SECRET>" #gitleaks:allow #BOOKORBIT_OIDC_CLIENT_SECRET
      - secretKey: OIDC_ISSUER_URL
        remoteRef:
          key: "<UUID-BOOKORBIT_OIDC_ISSUER_URL>" #gitleaks:allow #BOOKORBIT_OIDC_ISSUER_URL
      - secretKey: S3_ACCESS_KEY_ID
        remoteRef:
          key: "e00e1e38-ae37-479a-8b46-b409016331eb" #gitleaks:allow #S3_ACCESS_KEY
      - secretKey: S3_ACCESS_SECRET_KEY
        remoteRef:
          key: "4d5a418c-82ed-4b8e-bfbf-b40901634ea4" #gitleaks:allow #S3_SECRET_KEY
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add cluster/apps/default/bookorbit/templates/externalsecret.yaml
  git commit -m "feat(bookorbit): add ExternalSecret for Bitwarden credentials"
  ```

---

## Task 5: Create values.yaml

**Files:**
- Create: `cluster/apps/default/bookorbit/values.yaml`

Replace `<sha256-digest>` with the digest from Task 2 Step 3.

The volsync chart auto-creates the `bookorbit` PVC via `ReplicationDestination` (chart derives PVC name from release name = `bookorbit`). The `existingClaim: bookorbit` in `persistence.data` references that PVC.

The CNPG cluster is named `bookorbdb-cnpg` (chart appends `-cnpg` to the `name` value). The operator creates service `bookorbdb-cnpg-rw` and app secret `bookorbdb-cnpg-app` (keys: `username`, `password`) — these cannot be loaded via `envFrom` since the keys differ from the `POSTGRES_*` env var names, so they are mapped individually via `valueFrom.secretKeyRef`.

- [ ] **Step 1: Create values.yaml**

  ```yaml
  app-template:
    controllers:
      bookorbit:
        pod:
          securityContext:
            runAsUser: 1001
            runAsGroup: 1001
            fsGroup: 1001
            fsGroupChangePolicy: OnRootMismatch
        containers:
          app:
            image:
              repository: ghcr.io/bookorbit/bookorbit
              tag: v1.8.0@sha256:<sha256-digest>
              pullPolicy: IfNotPresent
            env:
              NODE_ENV: production
              PORT: "3000"
              TZ: CET
              PUID: "1001"
              PGID: "1001"
              APP_URL: "https://bookorbit.<secret:private-domain>"
              POSTGRES_HOST: bookorbdb-cnpg-rw
              POSTGRES_PORT: "5432"
              POSTGRES_DB: app
              NODE_MAX_OLD_SPACE_SIZE: "2048"
              OIDC_ALLOW_LOCAL_ISSUERS: "true"
              POSTGRES_USER:
                valueFrom:
                  secretKeyRef:
                    name: bookorbdb-cnpg-app
                    key: username
              POSTGRES_PASSWORD:
                valueFrom:
                  secretKeyRef:
                    name: bookorbdb-cnpg-app
                    key: password
            envFrom:
              - secretRef:
                  name: bookorbit-secrets
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/v1/health
                    port: 3000
                  initialDelaySeconds: 30
                  periodSeconds: 30
                  failureThreshold: 3
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /api/v1/health
                    port: 3000
                  initialDelaySeconds: 20
                  periodSeconds: 10
                  failureThreshold: 3
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
            port: 3000

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
          - bookorbit.<secret:private-domain>
        rules:
          - backendRefs:
              - identifier: app
                port: 3000

    persistence:
      data:
        existingClaim: bookorbit
        advancedMounts:
          bookorbit:
            app:
              - path: /data
      books:
        existingClaim: bookorbit-ebooks-pvc
        advancedMounts:
          bookorbit:
            app:
              - path: /books

  volsync:
    pvc:
      capacity: 5Gi
      storageClass: ceph-block
      volumeSnapshotClass: csi-ceph-blockpool
    volsync:
      moverSecurityContext:
        runAsUser: 1001
        runAsGroup: 1001
        fsGroup: 1001
      backup:
        schedule: "0 */6 * * *"
        pruneIntervalDays: 14
        retain:
          hourly: 24
          daily: 7
          weekly: 4
          monthly: 2
      restore:
        bootstrap: true

  pgsql-cnpg:
    name: bookorbdb
    imageName: ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm
    instances: 2
    storage:
      size: 10Gi
    resources:
      requests:
        memory: 256Mi
        cpu: 100m
      limits:
        memory: 512Mi
        cpu: 500m
    bootstrap:
      initdb:
        postInitApplicationSQL:
          - CREATE EXTENSION IF NOT EXISTS vector
    monitoring:
      enablePodMonitor: true
    objectStore:
      destinationPath: "s3://k8s-at-home-backup/cnpg/bookorbit"
      endpointURL: <secret:s3_endpoint>
      s3Credentials:
        accessKeyId:
          name: bookorbit-secrets
          key: S3_ACCESS_KEY_ID
        secretAccessKey:
          name: bookorbit-secrets
          key: S3_ACCESS_SECRET_KEY
    retentionPolicy: "10d"
    scheduledBackups:
      - name: bookorbdb-cnpg-backup
        spec:
          immediate: true
          schedule: "5 0 0 * * *"
          backupOwnerReference: self
    externalClusters:
      - name: bookorbdb-cnpg-backup
        plugin:
          name: barman-cloud.cloudnative-pg.io
          parameters:
            barmanObjectName: bookorbdb-objectstore
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add cluster/apps/default/bookorbit/values.yaml
  git commit -m "feat(bookorbit): add full values.yaml configuration"
  ```

---

## Task 6: Create app-config.yaml

**Files:**
- Create: `cluster/apps/default/bookorbit/app-config.yaml`

Start with `enabled: "false"` — enable only after Bitwarden secrets are confirmed present (Task 8).

- [ ] **Step 1: Create app-config.yaml**

  ```yaml
  - enabled: "false"
    namespace: bookorbit
    syncPolicy:
      enabled: true
      selfHeal: true
      prune: false
    plugin:
      env:
        - name: SECRET_PROVIDER
          value: cluster-secrets
  ```

- [ ] **Step 2: Commit**

  ```bash
  git add cluster/apps/default/bookorbit/app-config.yaml
  git commit -m "feat(bookorbit): add ArgoCD app-config (disabled until secrets ready)"
  ```

---

## Task 7: Render and lint validation

**Files:** None modified

- [ ] **Step 1: Render Helm templates**

  ```bash
  cd cluster/apps/default/bookorbit
  helm template bookorbit . -f values.yaml 2>&1 | head -100
  ```

  Expected: YAML output including a `Deployment`, `Service`, `HTTPRoute`, CNPG `Cluster`, `ObjectStore`, `ScheduledBackup`, `ReplicationSource`, `ReplicationDestination`, two `ExternalSecret` resources (volsync + bookorbit-secrets), and the raw NFS PV/PVC from templates/. No errors.

- [ ] **Step 2: Run full lint suite**

  ```bash
  cd /workspaces/home-ops
  task lint:all
  ```

  Expected: All checks pass (yamllint, helmlint, prettier). Fix any errors before continuing.

- [ ] **Step 3: Commit lint fixes if needed**

  ```bash
  git add cluster/apps/default/bookorbit/
  git commit -m "fix(bookorbit): lint corrections"
  ```

  Skip if Step 2 passed with no errors.

---

## Task 8: Enable app, deploy, and verify

**Files:**
- Modify: `cluster/apps/default/bookorbit/app-config.yaml`

**Prerequisite:** All 5 Bitwarden secrets from Task 1 must be created before enabling.

- [ ] **Step 1: Enable the app**

  Edit `cluster/apps/default/bookorbit/app-config.yaml`, change:
  ```yaml
  - enabled: "false"
  ```
  to:
  ```yaml
  - enabled: "true"
  ```

- [ ] **Step 2: Commit and open PR**

  ```bash
  git add cluster/apps/default/bookorbit/app-config.yaml
  git commit -m "feat(bookorbit): enable BookOrbit deployment"
  ```

  Then use the `git-workflows:pr` skill to push the branch and open a PR.

- [ ] **Step 3: After PR merge, verify ArgoCD sync**

  ```bash
  argocd app get bookorbit --refresh
  argocd app wait bookorbit --health --timeout 300
  ```

  Expected: All resources `Synced` and `Healthy`. If CNPG pods are pending, check `kubectl describe pod -n bookorbit -l cnpg.io/cluster=bookorbdb-cnpg` for storage or image pull errors.

- [ ] **Step 4: Verify ExternalSecret synced**

  ```bash
  kubectl get externalsecret -n bookorbit bookorbit-secrets -o jsonpath='{.status.conditions}' | python3 -m json.tool
  ```

  Expected: `"type": "Ready"` with `"status": "True"`. If not, check BWS item UUIDs in `templates/externalsecret.yaml` match the Bitwarden items from Task 1.

- [ ] **Step 5: Complete initial setup wizard**

  Open `https://bookorbit.<domain>/auth/setup` in browser.

  Use the `SETUP_BOOTSTRAP_TOKEN` value (from the Bitwarden item created in Task 1 Step 2) to:
  1. Create the admin user account
  2. Go to Settings → Authentication → OIDC and configure the Keycloak provider using the OIDC credentials from Task 1
  3. Add a library: path = `/books`, scan all formats
  4. Trigger initial library scan
