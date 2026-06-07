# BookOrbit Deployment Design

**Date:** 2026-06-03
**Status:** Approved

## Goal

Deploy [BookOrbit](https://github.com/bookorbit/bookorbit) (v1.8.0) as a self-hosted ebook/audiobook reader on the home-ops Kubernetes cluster, replacing the archived Calibre-Web deployment.

## Context

- BookOrbit is a TypeScript/NestJS/Vue single-container app (port 3000)
- Requires PostgreSQL with the `pgvector` extension
- Ebook library lives on QNAP NFS at `/ebooks` (already mounted as `nfs-ebooks-pvc` in `nfs-mounts` namespace)
- Cluster uses Keycloak as OIDC provider
- Cluster pattern for web apps with Postgres: `app-template` + `pgsql-cnpg` + `volsync` (matches n8n, litellm, honcho)

## Approach

**Option A selected:** `app-template` + `pgsql-cnpg` + `volsync` chart dependencies — the most idiomatic pattern in this cluster for a single-container web app with a Postgres backend.

## Repository Layout

```
cluster/apps/default/bookorbit/
├── app-config.yaml          # ArgoCD ApplicationSet entry
├── Chart.yaml               # app-template + pgsql-cnpg + volsync deps
├── Chart.lock
├── charts/                  # vendored chart deps
├── values.yaml              # all configuration
└── templates/
    ├── externalsecret.yaml  # JWT_SECRET, SETUP_BOOTSTRAP_TOKEN, OIDC, S3 creds
    └── nfs-ebooks.yaml      # PV + PVC for /books → QNAP /ebooks
```

- **Namespace:** `bookorbit`
- **Category:** `default` (alongside n8n, grocy, jellyfin)
- **ArgoCD:** `syncPolicy.selfHeal: true`, `prune: false`
- **Secrets plugin:** `SECRET_PROVIDER: cluster-secrets` for `<secret:*>` token substitution

## Database (CNPG)

- **Cluster name:** `bookorbdb`
- **Image:** `ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm`
- **Instances:** 2 (HA)
- **Storage:** 10Gi per instance, `ceph-block`
- **pgvector:** enabled via `postInitApplicationSQL: CREATE EXTENSION IF NOT EXISTS vector`
- **Monitoring:** `enablePodMonitor: true`
- **Service endpoint:** `bookorbdb-cnpg-rw:5432`
- **App secret:** CNPG auto-generates `bookorbdb-cnpg-app` with `username`/`password` keys — referenced via `envFrom`, no ExternalSecret needed for DB credentials

### CNPG S3 Backup

```yaml
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
externalClusters:
  - name: bookorbdb-cnpg-backup
    plugin:
      name: barman-cloud.cloudnative-pg.io
      parameters:
        barmanObjectName: bookorbdb-objectstore
```

Recovery from backup is available by uncommenting `bootstrap.recovery` in `values.yaml`.

## Secrets

`templates/externalsecret.yaml` pulls from Bitwarden (`ClusterSecretStore: bitwarden`) and produces `bookorbit-secrets`:

| Key | Source | Notes |
|-----|---------|-------|
| `JWT_SECRET` | Bitwarden item | `openssl rand -hex 32` — create before first deploy |
| `SETUP_BOOTSTRAP_TOKEN` | Bitwarden item | `openssl rand -hex 16` — one-time setup wizard token |
| `OIDC_CLIENT_ID` | Bitwarden item | Keycloak client ID for BookOrbit |
| `OIDC_CLIENT_SECRET` | Bitwarden item | Keycloak client secret |
| `OIDC_ISSUER_URL` | Bitwarden item | e.g. `https://keycloak.<domain>/realms/main` |
| `S3_ACCESS_KEY_ID` | Bitwarden item (shared) | Same item as honcho |
| `S3_ACCESS_SECRET_KEY` | Bitwarden item (shared) | Same item as honcho |

## Storage

| Mount | PVC | Backend | Size | Access |
|-------|-----|---------|------|--------|
| `/data` | `bookorbit` (volsync-managed) | `ceph-block` RWO | 5Gi | app config, covers, state |
| `/books` | `bookorbit-ebooks-pvc` | NFS `qnap.*/ebooks` RWX | 50Gi | read-only ebook library |

**NFS PV/PVC** (`templates/nfs-ebooks.yaml`): created in the `bookorbit` namespace pointing at `qnap.<secret:private-domain>:/ebooks` — same approach as the archived Calibre-Web, separate from `nfs-mounts/nfs-ebooks-pvc`.

**Volsync backup** for `/data` PVC: schedule `0 */6 * * *`, S3 destination `s3://k8s-at-home-backup/volsync/bookorbit`.

## App Deployment

```yaml
image: ghcr.io/bookorbit/bookorbit:v1.8.0   # pinned; Renovate will update
port: 3000
securityContext:
  runAsUser: 1001
  runAsGroup: 1001
  fsGroup: 1001
```

**Static env vars:**

| Var | Value |
|-----|-------|
| `NODE_ENV` | `production` |
| `PORT` | `3000` |
| `TZ` | `CET` |
| `PUID` / `PGID` | `1001` |
| `APP_URL` | `https://bookorbit.<secret:private-domain>` |
| `POSTGRES_HOST` | `bookorbdb-cnpg-rw` |
| `POSTGRES_PORT` | `5432` |
| `POSTGRES_DB` | `app` |
| `NODE_MAX_OLD_SPACE_SIZE` | `2048` |
| `OIDC_ALLOW_LOCAL_ISSUERS` | `true` (Keycloak is internal) |

**Secret env vars:**
- `envFrom: bookorbit-secrets` → `JWT_SECRET`, `SETUP_BOOTSTRAP_TOKEN`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER_URL`
- `POSTGRES_USER` and `POSTGRES_PASSWORD` mapped individually via `valueFrom.secretKeyRef` from `bookorbdb-cnpg-app` (keys: `username`, `password`) — CNPG does not generate `POSTGRES_*`-named keys, so `envFrom` cannot be used here

**Resources:**
```yaml
requests: { cpu: 100m, memory: 512Mi }
limits:   { memory: 2Gi }
```

## Routing

```yaml
HTTPRoute:
  gateway: envoy-internal (namespace: envoy-gateway, section: https)
  hostname: bookorbit.<secret:private-domain>
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
```

Internal-only access via private domain. No external Cloudflare tunnel.

## Pre-Deploy Checklist

Before enabling the app in ArgoCD, these Bitwarden secrets must exist:

- [ ] `JWT_SECRET` (random hex 32)
- [ ] `SETUP_BOOTSTRAP_TOKEN` (random hex 16)
- [ ] `OIDC_CLIENT_ID` + `OIDC_CLIENT_SECRET` + `OIDC_ISSUER_URL` (Keycloak client created)
- [ ] S3 credential items (confirm same Bitwarden IDs as honcho)

After first deploy, complete the setup wizard at `https://bookorbit.<domain>/auth/setup` using the bootstrap token.
