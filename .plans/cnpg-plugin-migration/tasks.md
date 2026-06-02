# CNPG plugin-barman-cloud Migration — Tasks

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate all five CNPG clusters from deprecated `system-bookworm`/plain-tag images to `standard-bookworm` images backed by the `plugin-barman-cloud` operator, in a single PR.

**Architecture:** Add `plugin-barman-cloud` (chart v0.6.0) as a dependency to the existing `cloudnative-pg` ArgoCD app. Bump the local `pgsql-cnpg` chart from v1.2.0 to v1.3.0, replacing inline `backup.barmanObjectStore` on the `Cluster` spec with an `ObjectStore` CR + `spec.plugins` reference. All five apps get updated image tags and a new `objectStore:` values block in place of `backup:`.

**Tech Stack:** CloudNativePG 1.29.1, plugin-barman-cloud v0.12.0 (chart 0.6.0), Helm, ArgoCD, S3/Barman

---

## File Map

| File | Change |
|------|--------|
| `cluster/apps/system/cloudnative-pg/Chart.yaml` | Add `plugin-barman-cloud 0.6.0` dep |
| `charts/pgsql-cnpg/Chart.yaml` | Version `1.2.0 → 1.3.0` |
| `charts/pgsql-cnpg/templates/cnpg.yaml` | Add ObjectStore CR; replace `backup:` with `spec.plugins`; inject plugin fields into ScheduledBackup |
| `cluster/apps/ai/honcho/Chart.yaml` | pgsql-cnpg dep `1.2.0 → 1.3.0` |
| `cluster/apps/ai/honcho/Chart.lock` | Regenerate |
| `cluster/apps/ai/honcho/charts/` | Replace `pgsql-cnpg-1.2.0.tgz` with `pgsql-cnpg-1.3.0.tgz` |
| `cluster/apps/ai/honcho/values.yaml` | Image tag; `externalClusters` → plugin format; `backup:` → `objectStore:` |
| `cluster/apps/ai/litellm/Chart.yaml` | pgsql-cnpg dep `1.2.0 → 1.3.0` |
| `cluster/apps/ai/litellm/Chart.lock` | Regenerate |
| `cluster/apps/ai/litellm/charts/` | Replace `pgsql-cnpg-1.2.0.tgz` with `pgsql-cnpg-1.3.0.tgz` |
| `cluster/apps/ai/litellm/values.yaml` | Image tag; `backup:` → `objectStore:` |
| `cluster/apps/default/gitea/Chart.yaml` | pgsql-cnpg dep `1.2.0 → 1.3.0` |
| `cluster/apps/default/gitea/values.yaml` | Image tag; `backup:` → `objectStore:`; update commented recovery block |
| `cluster/apps/system/keycloak/Chart.yaml` | pgsql-cnpg dep `1.2.0 → 1.3.0` |
| `cluster/apps/system/keycloak/values.yaml` | Image tag; `backup:` → `objectStore:`; update commented recovery block |
| `cluster/apps/home-automation/home-assistant/Chart.yaml` | pgsql-cnpg dep `1.2.0 → 1.3.0` |
| `cluster/apps/home-automation/home-assistant/values.yaml` | Add `imageName`; `backup:` → `objectStore:` |

---

## Task 1: Create feature branch

- [ ] **Create branch**

```bash
git checkout -b feat/cnpg-plugin-barman-cloud-migration
```

---

## Task 2: Add plugin-barman-cloud to cloudnative-pg app

**Files:**
- Modify: `cluster/apps/system/cloudnative-pg/Chart.yaml`

- [ ] **Add the plugin-barman-cloud dependency**

Replace the contents of `cluster/apps/system/cloudnative-pg/Chart.yaml` with:

```yaml
---
apiVersion: v2
name: cloudnative-pg-subchart
type: application
version: 1.0.0
appVersion: "1.29.1"
dependencies:
  - name: cloudnative-pg
    version: 0.28.2
    repository: https://cloudnative-pg.github.io/charts
  - name: plugin-barman-cloud
    version: 0.6.0
    repository: https://cloudnative-pg.github.io/charts
```

- [ ] **Commit**

```bash
git add cluster/apps/system/cloudnative-pg/Chart.yaml
git commit -m "feat(cnpg): add plugin-barman-cloud 0.6.0 to cloudnative-pg app"
```

---

## Task 3: Rewrite pgsql-cnpg chart template and bump version

**Files:**
- Modify: `charts/pgsql-cnpg/Chart.yaml`
- Modify: `charts/pgsql-cnpg/templates/cnpg.yaml`

- [ ] **Bump chart version in `charts/pgsql-cnpg/Chart.yaml`**

```yaml
---
apiVersion: v2
name: pgsql-cnpg
type: application
version: 1.3.0
```

- [ ] **Rewrite `charts/pgsql-cnpg/templates/cnpg.yaml`**

Replace the entire file with:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ printf "%s-%s" .Values.name "cnpg" }}
  {{- with .Values.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  instances: {{ .Values.instances }}
  {{- if .Values.imageName }}
  imageName: {{ .Values.imageName }}
  {{- end }}
  primaryUpdateStrategy: unsupervised
  storage:
    size: {{ .Values.storage.size }}
  {{- with .Values.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  postgresql:
    parameters:
      pgaudit.log: "all, -misc"
      pgaudit.log_catalog: "off"
      pgaudit.log_parameter: "on"
      pgaudit.log_relation: "on"
  {{- with .Values.bootstrap }}
  bootstrap:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.externalClusters }}
  externalClusters:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  affinity:
    podAntiAffinityType: required
    topologyKey: kubernetes.io/hostname
  monitoring:
    enablePodMonitor: {{ .Values.monitoring.enablePodMonitor }}
  {{- if .Values.objectStore }}
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: {{ printf "%s-objectstore" .Values.name }}
  {{- end }}
{{- if .Values.objectStore }}
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: {{ printf "%s-objectstore" .Values.name }}
spec:
  configuration:
    barmanObjectStore:
      {{- toYaml .Values.objectStore | nindent 6 }}
  {{- if .Values.retentionPolicy }}
  retentionPolicy: {{ .Values.retentionPolicy }}
  {{- end }}
{{- end }}
{{ range $k, $v := .Values.scheduledBackups }}
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: {{ $v.name }}
spec:
  cluster:
    name: {{ printf "%s-%s" $.Values.name "cnpg" }}
  {{- if $.Values.objectStore }}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  {{- end }}
  {{- with $v.spec }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{ end }}
```

- [ ] **Commit**

```bash
git add charts/pgsql-cnpg/Chart.yaml charts/pgsql-cnpg/templates/cnpg.yaml
git commit -m "feat(pgsql-cnpg): v1.3.0 — ObjectStore CR + plugin-barman-cloud integration"
```

---

## Task 4: Update honcho values and rebuild deps

**Files:**
- Modify: `cluster/apps/ai/honcho/Chart.yaml`
- Modify: `cluster/apps/ai/honcho/values.yaml`
- Modify: `cluster/apps/ai/honcho/Chart.lock` (regenerated)
- Modify: `cluster/apps/ai/honcho/charts/` (tarball replaced)

- [ ] **Bump pgsql-cnpg version in `cluster/apps/ai/honcho/Chart.yaml`**

```yaml
---
apiVersion: v2
name: honcho
type: application
version: 1.0.0
dependencies:
  - name: pgsql-cnpg
    version: 1.3.0
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Replace the `pgsql-cnpg:` block in `cluster/apps/ai/honcho/values.yaml`**

Find the section starting at `pgsql-cnpg:` and replace it with:

```yaml
pgsql-cnpg:
  name: honchodb
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm
  instances: 2
  storage:
    size: 30Gi
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
  # Uncomment to restore from S3 backup (requires at least one successful backup to exist):
  # bootstrap:
  #   recovery:
  #     source: honchodb-cnpg-backup
  externalClusters:
    - name: honchodb-cnpg-backup
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: honchodb-objectstore
  monitoring:
    enablePodMonitor: true
  retentionPolicy: "10d"
  objectStore:
    destinationPath: "s3://k8s-at-home-backup/cnpg/honcho"
    endpointURL: <secret:s3_endpoint>
    s3Credentials:
      accessKeyId:
        name: honcho-secrets
        key: S3_ACCESS_KEY_ID
      secretAccessKey:
        name: honcho-secrets
        key: S3_ACCESS_SECRET_KEY
  scheduledBackups:
    - name: honchodb-cnpg-backup
      spec:
        immediate: true
        schedule: "10 0 0 * * *"
        backupOwnerReference: self
```

- [ ] **Rebuild chart dependencies**

```bash
cd cluster/apps/ai/honcho
helm dependency update
cd /workspaces/home-ops
```

Expected: `charts/pgsql-cnpg-1.3.0.tgz` is created, `pgsql-cnpg-1.2.0.tgz` is removed, `Chart.lock` is updated.

- [ ] **Verify rendered output contains ObjectStore and plugin method**

```bash
cd cluster/apps/ai/honcho
helm template honcho . -f values.yaml | grep -E "^kind:|barmanObjectName:|^  method:|standard-bookworm"
cd /workspaces/home-ops
```

Expected output:
```
kind: Cluster
kind: ObjectStore
kind: ScheduledBackup
    barmanObjectName: honchodb-objectstore
  method: plugin
    tag: 17.6-standard-bookworm   # or imageName line
```

- [ ] **Commit**

```bash
git add cluster/apps/ai/honcho/
git commit -m "feat(honcho): migrate CNPG to standard-bookworm + plugin-barman-cloud"
```

---

## Task 5: Update litellm values and rebuild deps

**Files:**
- Modify: `cluster/apps/ai/litellm/Chart.yaml`
- Modify: `cluster/apps/ai/litellm/values.yaml`
- Modify: `cluster/apps/ai/litellm/Chart.lock` (regenerated)
- Modify: `cluster/apps/ai/litellm/charts/` (tarball replaced)

- [ ] **Bump pgsql-cnpg version in `cluster/apps/ai/litellm/Chart.yaml`**

Change the pgsql-cnpg version from `1.2.0` to `1.3.0`:

```yaml
  - name: pgsql-cnpg
    version: 1.3.0
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Replace the `pgsql-cnpg:` block in `cluster/apps/ai/litellm/values.yaml`**

Find the section starting at `pgsql-cnpg:` (around line 59) and replace it with:

```yaml
pgsql-cnpg:
  name: litellmdb
  imageName: ghcr.io/cloudnative-pg/postgresql:17.4-standard-bookworm
  instances: 2
  storage:
    size: 15Gi
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  # Uncomment to restore from S3 backup (requires at least one successful backup to exist):
  # bootstrap:
  #   recovery:
  #     source: litellmdb-cnpg-backup
  # externalClusters:
  #   - name: litellmdb-cnpg-backup
  #     plugin:
  #       name: barman-cloud.cloudnative-pg.io
  #       parameters:
  #         barmanObjectName: litellmdb-objectstore
  monitoring:
    enablePodMonitor: true
  retentionPolicy: "10d"
  objectStore:
    destinationPath: "s3://k8s-at-home-backup/cnpg/litell"
    endpointURL: <secret:s3_endpoint>
    s3Credentials:
      accessKeyId:
        name: litellm-secrets
        key: S3_ACCESS_KEY_ID
      secretAccessKey:
        name: litellm-secrets
        key: S3_ACCESS_SECRET_KEY
  scheduledBackups:
    - name: litelldb-cnpg-backup
      spec:
        immediate: true
        schedule: "5 0 0 * * *"
        backupOwnerReference: self
```

- [ ] **Rebuild chart dependencies**

```bash
cd cluster/apps/ai/litellm
helm dependency update
cd /workspaces/home-ops
```

Expected: `charts/pgsql-cnpg-1.3.0.tgz` created, `pgsql-cnpg-1.2.0.tgz` removed, `Chart.lock` updated.

- [ ] **Verify rendered output**

```bash
cd cluster/apps/ai/litellm
helm template litellm . -f values.yaml | grep -E "^kind:|barmanObjectName:|^  method:"
cd /workspaces/home-ops
```

Expected:
```
kind: Cluster
kind: ObjectStore
kind: ScheduledBackup
    barmanObjectName: litellmdb-objectstore
  method: plugin
```

- [ ] **Commit**

```bash
git add cluster/apps/ai/litellm/
git commit -m "feat(litellm): migrate CNPG to standard-bookworm + plugin-barman-cloud"
```

---

## Task 6: Update gitea values

**Files:**
- Modify: `cluster/apps/default/gitea/Chart.yaml`
- Modify: `cluster/apps/default/gitea/values.yaml`

*(No charts/ dir — ArgoCD resolves deps at sync time for this app.)*

- [ ] **Bump pgsql-cnpg version in `cluster/apps/default/gitea/Chart.yaml`**

Change the pgsql-cnpg version from `1.2.0` to `1.3.0`:

```yaml
  - name: pgsql-cnpg
    version: 1.3.0
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Replace the `pgsql-cnpg:` block in `cluster/apps/default/gitea/values.yaml`**

Find the section starting at `pgsql-cnpg:` (around line 94) and replace it with:

```yaml
pgsql-cnpg:
  name: giteadb
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
    destinationPath: "s3://k8s-at-home-backup/cnpg/gitea"
    endpointURL: <secret:s3_endpoint>
    s3Credentials:
      accessKeyId:
        name: gitea-secrets
        key: S3_ACCESS_KEY_ID
      secretAccessKey:
        name: gitea-secrets
        key: S3_ACCESS_SECRET_KEY
  scheduledBackups:
    - name: giteadb-cnpg-backup
      spec:
        immediate: true
        schedule: "5 0 0 * * *"
        backupOwnerReference: self
  # Uncomment to restore from S3 backup (requires at least one successful backup to exist):
  # bootstrap:
  #   recovery:
  #     source: giteadb-cnpg-backup
  # externalClusters:
  #   - name: giteadb-cnpg-backup
  #     plugin:
  #       name: barman-cloud.cloudnative-pg.io
  #       parameters:
  #         barmanObjectName: giteadb-objectstore
```

- [ ] **Verify rendered output**

```bash
cd cluster/apps/default/gitea
helm dependency build 2>/dev/null || true
helm template gitea . -f values.yaml | grep -E "^kind:|barmanObjectName:|^  method:"
cd /workspaces/home-ops
```

Expected:
```
kind: Cluster
kind: ObjectStore
kind: ScheduledBackup
    barmanObjectName: giteadb-objectstore
  method: plugin
```

- [ ] **Commit**

```bash
git add cluster/apps/default/gitea/
git commit -m "feat(gitea): migrate CNPG to standard-bookworm + plugin-barman-cloud"
```

---

## Task 7: Update keycloak values

**Files:**
- Modify: `cluster/apps/system/keycloak/Chart.yaml`
- Modify: `cluster/apps/system/keycloak/values.yaml`

*(No charts/ dir — ArgoCD resolves deps at sync time for this app.)*

- [ ] **Bump pgsql-cnpg version in `cluster/apps/system/keycloak/Chart.yaml`**

Change the pgsql-cnpg version from `1.2.0` to `1.3.0`:

```yaml
  - name: pgsql-cnpg
    version: 1.3.0
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Replace the `pgsql-cnpg:` block in `cluster/apps/system/keycloak/values.yaml`**

Find the section starting at `pgsql-cnpg:` (around line 75) and replace it with:

```yaml
pgsql-cnpg:
  name: keycloakdb
  imageName: ghcr.io/cloudnative-pg/postgresql:16.6-standard-bookworm
  instances: 2
  storage:
    size: 2Gi
  resources:
    requests:
      memory: 200Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  # Uncomment to restore from S3 backup (requires at least one successful backup to exist):
  # bootstrap:
  #   recovery:
  #     source: keycloakdb-cnpg-backup
  # externalClusters:
  #   - name: keycloakdb-cnpg-backup
  #     plugin:
  #       name: barman-cloud.cloudnative-pg.io
  #       parameters:
  #         barmanObjectName: keycloakdb-objectstore
  monitoring:
    enablePodMonitor: true
  retentionPolicy: "10d"
  objectStore:
    destinationPath: "s3://k8s-at-home-backup/cnpg/keycloak"
    endpointURL: <secret:s3_endpoint>
    s3Credentials:
      accessKeyId:
        name: keycloakdb-secrets
        key: S3_ACCESS_KEY_ID
      secretAccessKey:
        name: keycloakdb-secrets
        key: S3_ACCESS_SECRET_KEY
  scheduledBackups:
    - name: keycloakdb-cnpg-backup
      spec:
        immediate: true
        schedule: "55 0 0 * * *"
        backupOwnerReference: self
```

- [ ] **Verify rendered output**

```bash
cd cluster/apps/system/keycloak
helm dependency build 2>/dev/null || true
helm template keycloak . -f values.yaml | grep -E "^kind:|barmanObjectName:|^  method:"
cd /workspaces/home-ops
```

Expected:
```
kind: Cluster
kind: ObjectStore
kind: ScheduledBackup
    barmanObjectName: keycloakdb-objectstore
  method: plugin
```

- [ ] **Commit**

```bash
git add cluster/apps/system/keycloak/
git commit -m "feat(keycloak): migrate CNPG to standard-bookworm + plugin-barman-cloud"
```

---

## Task 8: Update home-assistant values

**Files:**
- Modify: `cluster/apps/home-automation/home-assistant/Chart.yaml`
- Modify: `cluster/apps/home-automation/home-assistant/values.yaml`

*(No charts/ dir — ArgoCD resolves deps at sync time for this app.)*

- [ ] **Bump pgsql-cnpg version in `cluster/apps/home-automation/home-assistant/Chart.yaml`**

Change the pgsql-cnpg version from `1.2.0` to `1.3.0`:

```yaml
  - name: pgsql-cnpg
    version: 1.3.0
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Replace the `pgsql-cnpg:` block in `cluster/apps/home-automation/home-assistant/values.yaml`**

Find the section starting at `pgsql-cnpg:` (lines 1–27) and replace it with:

```yaml
pgsql-cnpg:
  name: home-assistant
  imageName: ghcr.io/cloudnative-pg/postgresql:17-standard-bookworm
  instances: 2
  storage:
    size: 5Gi
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  monitoring:
    enablePodMonitor: true
  retentionPolicy: "10d"
  objectStore:
    destinationPath: "s3://k8s-at-home-backup/cnpg/home-assistant"
    endpointURL: <secret:s3_endpoint>
    s3Credentials:
      accessKeyId:
        name: home-assistant-secrets
        key: S3_ACCESS_KEY_ID
      secretAccessKey:
        name: home-assistant-secrets
        key: S3_ACCESS_SECRET_KEY
  scheduledBackups:
    - name: home-assistant-cnpg-backup
      spec:
        immediate: true
        schedule: "52 0 0 * * *"
        backupOwnerReference: self
```

- [ ] **Verify rendered output**

```bash
cd cluster/apps/home-automation/home-assistant
helm dependency build 2>/dev/null || true
helm template home-assistant . -f values.yaml | grep -E "^kind:|barmanObjectName:|^  method:"
cd /workspaces/home-ops
```

Expected:
```
kind: Cluster
kind: ObjectStore
kind: ScheduledBackup
    barmanObjectName: home-assistant-objectstore
  method: plugin
```

- [ ] **Commit**

```bash
git add cluster/apps/home-automation/home-assistant/
git commit -m "feat(home-assistant): migrate CNPG to standard-bookworm + plugin-barman-cloud"
```

---

## Task 9: Full lint and final render check

- [ ] **Run full lint suite**

```bash
task lint:all
```

Expected: all checks pass with no errors.

- [ ] **Spot-check that no `barmanObjectStore` remains under a `Cluster` `backup:` key**

```bash
grep -r "barmanObjectStore" cluster/apps/*/*/values.yaml charts/pgsql-cnpg/
```

Expected: no matches (all barman config is now in ObjectStore CRs, rendered by the chart — the values files have only `objectStore:` keys, not `backup.barmanObjectStore`).

- [ ] **Commit any lint fixes, then confirm clean status**

```bash
git status
```

Expected: clean (nothing to commit).

---

## Task 10: Open PR

- [ ] **Push branch**

```bash
git push -u origin feat/cnpg-plugin-barman-cloud-migration
```

- [ ] **Open PR**

```bash
gh pr create \
  --title "feat(cnpg): migrate all clusters to standard-bookworm + plugin-barman-cloud" \
  --body "$(cat <<'EOF'
## Summary
- Adds `plugin-barman-cloud 0.6.0` as a dependency to the `cloudnative-pg` ArgoCD app
- Bumps local `pgsql-cnpg` chart to v1.3.0: backup config moves from inline `Cluster.backup.barmanObjectStore` to a dedicated `ObjectStore` CR; `spec.plugins` wires the cluster to the plugin; `ScheduledBackup` injects `method: plugin`
- Migrates all 5 CNPG clusters to `standard-bookworm` images (honcho: 17.6, litellm: 17.4, gitea: 15.10, keycloak: 16.6, home-assistant: 17)
- PITR continuity with old S3 backups is intentionally broken; old backups can be cleared separately

## Test plan
- [ ] All `helm template` renders produce `kind: ObjectStore` and `method: plugin` in `ScheduledBackup`
- [ ] `task lint:all` passes clean
- [ ] After ArgoCD sync: `plugin-barman-cloud` pod running in `cnpg` namespace
- [ ] After ArgoCD sync: each cluster reports healthy in `kubectl get clusters -A`
- [ ] After first scheduled backup: verify a new backup object appears in S3 at the configured `destinationPath`
EOF
)"
```
