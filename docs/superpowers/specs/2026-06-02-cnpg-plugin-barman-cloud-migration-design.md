# CNPG Migration: system images → standard + plugin-barman-cloud

**Date:** 2026-06-02
**Status:** Approved

## Goal

Migrate all five CNPG clusters away from deprecated `system-bookworm` and plain rolling image tags to `standard-bookworm` images backed by the `plugin-barman-cloud` operator. All changes ship in a single PR.

## Context

CloudNativePG deprecated the `system` image flavour (which bundled barman tools inside the database container) and plain numeric rolling tags (e.g. `17.4`, `15.10`). The new model separates concerns: `standard-bookworm` images are lean (no barman), and the `plugin-barman-cloud` operator handles backup/restore as a sidecar/webhook.

### Current state

| Cluster | Namespace | Image | Status |
|---------|-----------|-------|--------|
| `honchodb-cnpg` | `honcho` | `17.6-system-bookworm` | live — worst offender |
| `litellmdb-cnpg` | `litellm` | `17.4` | live — plain rolling tag |
| `giteadb-cnpg` | `gitea` | `15.10` | live — plain rolling tag |
| `keycloakdb-cnpg` | `identity` | `16.6` | live — plain rolling tag |
| `home-assistant-cnpg` | `ha-home-assistant` | *(operator default)* | **disabled** — not deployed |

All five use `backup.barmanObjectStore` inline in the `Cluster` spec (old approach). All five use the local `charts/pgsql-cnpg` chart at v1.2.0.

### Constraints

- PITR continuity break is acceptable — old S3 backups can be cleared after migration.
- All clusters migrate in a single PR.
- `plugin-barman-cloud` is bundled into the existing `cloudnative-pg` ArgoCD app (not a new app).

## Architecture

**Before:** Backup logic lives inside the database pod. The `Cluster` spec carries `backup.barmanObjectStore` inline. The database image (`system-bookworm` or plain tag) includes barman tooling.

**After:** The `plugin-barman-cloud` operator runs as a separate deployment in the `cnpg` namespace. Database pods use lean `standard-bookworm` images. Backup config moves to an `ObjectStore` CR (`barmancloud.cnpg.io/v1`) per cluster namespace. The `Cluster` spec references the plugin via `spec.plugins`.

```
cnpg namespace
├── cloudnative-pg controller       (existing)
└── plugin-barman-cloud operator    (new)

each app namespace
├── Cluster CR  ──► spec.plugins → barman-cloud.cloudnative-pg.io
│                               → barmanObjectName: {name}-objectstore
├── ObjectStore CR  ({name}-objectstore)
│   └── spec.configuration.barmanObjectStore  ← moved from Cluster
└── ScheduledBackup CR  (unchanged name/schedule; method: plugin injected by chart)
```

## Component Changes

### 1. `cluster/apps/system/cloudnative-pg/Chart.yaml`

Add `plugin-barman-cloud` as a second Helm dependency from the same chart repository (`https://cloudnative-pg.github.io/charts`). Version to be resolved at implementation time (pin to latest stable).

### 2. `charts/pgsql-cnpg/Chart.yaml`

Bump version `1.2.0 → 1.3.0`.

### 3. `charts/pgsql-cnpg/templates/cnpg.yaml`

Three changes:

**a. Add `ObjectStore` CR** (rendered when `objectStore:` is set in values):

```yaml
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
{{- end }}
```

**b. Replace `backup.barmanObjectStore` with `spec.plugins`** in the `Cluster`:

```yaml
{{- if .Values.objectStore }}
plugins:
  - name: barman-cloud.cloudnative-pg.io
    parameters:
      barmanObjectName: {{ printf "%s-objectstore" .Values.name }}
{{- end }}
```

**c. Inject plugin fields into `ScheduledBackup`** automatically:

```yaml
method: plugin
pluginConfiguration:
  name: barman-cloud.cloudnative-pg.io
```

These fields are chart-injected alongside the existing `$v.spec` block (schedule, `backupOwnerReference`, etc.) — no change required to `scheduledBackups:` values. The template must emit both the injected fields and the user-supplied `spec:` content.

### 4. Per-app `values.yaml` changes

**Image tags:**

| App | Before | After |
|-----|--------|-------|
| honcho | `ghcr.io/cloudnative-pg/postgresql:17.6-system-bookworm` | `ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm` |
| litellm | `ghcr.io/cloudnative-pg/postgresql:17.4` | `ghcr.io/cloudnative-pg/postgresql:17.4-standard-bookworm` |
| gitea | `ghcr.io/cloudnative-pg/postgresql:15.10` | `ghcr.io/cloudnative-pg/postgresql:15.10-standard-bookworm` |
| keycloak | `ghcr.io/cloudnative-pg/postgresql:16.6` | `ghcr.io/cloudnative-pg/postgresql:16.6-standard-bookworm` |
| home-assistant | *(none — operator default)* | `ghcr.io/cloudnative-pg/postgresql:17-standard-bookworm` |

**Values schema** — rename and flatten `backup.barmanObjectStore` → `objectStore`:

```yaml
# Before
pgsql-cnpg:
  backup:
    barmanObjectStore:
      destinationPath: "s3://k8s-at-home-backup/cnpg/honcho"
      endpointURL: <secret:s3_endpoint>
      s3Credentials: ...
      wal:
        compression: gzip

# After
pgsql-cnpg:
  objectStore:
    destinationPath: "s3://k8s-at-home-backup/cnpg/honcho"
    endpointURL: <secret:s3_endpoint>
    s3Credentials: ...
    wal:
      compression: gzip
```

`scheduledBackups:` structure is unchanged; the chart injects `method: plugin` and `pluginConfiguration` automatically.

## Sync Order

`cloudnative-pg` (with `plugin-barman-cloud`) must be healthy before any Cluster is updated, as the plugin webhook must be registered. ArgoCD `syncWave` handles this — `cloudnative-pg` already deploys in an earlier wave.

## Out of Scope

- Clearing old S3 backups — done separately after migration is stable.
- Home-assistant app enablement — image tag is set but `enabled: "false"` is not changed.
- PostgreSQL major version upgrades — each cluster stays on its current major version.
