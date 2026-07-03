# Nextcloud + OnlyOffice — OneDrive Replacement Design

**Date:** 2026-07-02
**Status:** Approved

## Goal

Self-host family file sync/management (Nextcloud) and document editing (OnlyOffice) to replace OneDrive, moving ~600GB of family data out of US-hosted cloud storage as a privacy measure.

## Context & Decisions

- **Reference:** [bjw-s-labs/home-ops nextcloud helmrelease](https://github.com/bjw-s-labs/home-ops/blob/main/kubernetes/apps/selfhosted/nextcloud/app/helmrelease.yaml) — chart choice, `fpm-alpine` flavor, declarative `config.php` snippets, and `hostUsers: false` postRenderer patch are reused. MariaDB is **not** reused (see Database below).
- **Storage capacity constraint:** Ceph pools have ~350GB max-avail at 3x replication (277GB already used) — cannot hold 600GB+ of family data. QNAP TS-251D NAS has 1TB+ free and already serves this role for other bulk data (`movies`/`tv-series`/`ebooks` NFS PVs).
- **Auth:** Keycloak SSO via Nextcloud's `user_oidc` app (same pattern as Harbor's native OIDC — no oauth2-proxy in front). Local `admin` account kept as break-glass fallback only.
- **Remote access:** Required — family needs mobile sync + browser access away from home. Exposed via `envoy-external` + Cloudflare tunnel, same as Harbor/Jellyfin/Gitea.
- **Offsite backup:** Explicitly declined by user — local redundancy only. QNAP snapshots are already enabled on the NAS (pre-existing, not part of this build).
- **OnlyOffice edition:** Community Server (free). 20 concurrent open-document cap is a non-issue at family scale; no HA needed.
- **Migration:** Per-user, staged (not one bulk cutover) — each family member migrated and verified independently, on their own schedule.

## Architecture

```
cluster/apps/default/nextcloud/          (appSubfolder: app, onlyoffice)
│
├── app/                                 # Nextcloud
│   ├── Postgres (pgsql-cnpg chart)      — matches gitea/bookorbit/anytype/grocy convention
│   ├── Redis (bundled chart subchart)   — per-app, file locking + sessions + cache
│   ├── PVC: ceph-block                  — /var/www/html (app/config state, small)
│   ├── PVC: NFS (QNAP)                  — nextcloud.datadir → /var/www/data (user files, 600GB+)
│   ├── user_oidc app                    — Keycloak SSO
│   ├── ONLYOFFICE connector app         — talks to onlyoffice/ over ClusterIP
│   └── HTTPRoute (envoy-external)       — WebDAV/CalDAV/CardDAV ride same route
│
└── onlyoffice/                          # OnlyOffice Document Server (Community)
    ├── PVC: ceph-block                  — fonts/cache/JWT doc cache (small)
    ├── JWT_ENABLED=true                 — shared secret via ExternalSecret
    └── ClusterIP only                   — not internet-facing; Nextcloud proxies editing sessions
```

**Storage split rationale:** App/config state is small and latency-sensitive → Ceph (replicated, snapshot-friendly). User data is large and growing → NFS on QNAP, decoupling family data growth from cluster Ceph capacity entirely.

## Database & Caching

- **Postgres**: via local `pgsql-cnpg` chart — avoids introducing MariaDB as a second SQL engine in the cluster.
- **Redis**: bundled per-app subchart (as in `anytype`) — not shared `dragonfly`; no other app in the cluster centralizes on it.

## Auth (Keycloak SSO)

- Register a confidential OIDC client in Keycloak for Nextcloud.
- Client secret delivered via `ExternalSecret` (Bitwarden) → K8s `Secret` → referenced by `user_oidc` app config (same `ExternalSecret`-for-`Secret`-fields rule as Harbor's `harbor-oidc-secret`).
- Family members auto-provision on first OIDC login. Local `admin` disabled from normal login flow.

## Networking & Exposure

- `envoy-external` Gateway + Cloudflare tunnel, HTTPRoute with HSTS `ResponseHeaderModifier` (per bjw-s reference).
- `config.php` must set `trusted_proxies` / `overwriteprotocol` for correct HTTPS/client-IP detection through Envoy + cloudflared — otherwise redirect loops / broken CSRF checks.
- WebDAV/CalDAV/CardDAV (`/remote.php/dav/...`, `/.well-known/carddav`, `/.well-known/caldav`) ride the same HTTPRoute — no extra routing.
- Cloudflare-side rate limiting on `/login` and `/index.php/login/v2` recommended (Terraform), on top of Nextcloud's built-in brute-force throttler, since this is now internet-facing family data.
- OnlyOffice Document Server: ClusterIP only, no HTTPRoute — reached internally by the Nextcloud connector app.

## OnlyOffice Integration

- Official `onlyoffice/documentserver` image, Community edition.
- Nextcloud's official "ONLYOFFICE" connector app configured to point at `onlyoffice.nextcloud.svc.cluster.local`.
- `JWT_ENABLED=true` on Document Server; shared JWT secret via `ExternalSecret`, injected into both Document Server env and the connector app's stored config.
- Known limit: 20 concurrent open-document editing sessions (Community edition cap) — acceptable at family scale.

## Backup

| Component | Mechanism |
|---|---|
| Postgres | CNPG scheduled `barman-cloud` backups to QNAP S3 (QuObjects), with existing `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` sidecar workaround |
| App/config PVC (Ceph) | Volsync, same pattern as gitea/grocy/anytype |
| User data (NFS datadir) | QNAP-native snapshots (already enabled on the NAS — pre-existing, out of cluster scope) |

No offsite backup — explicitly declined; local/NAS redundancy only.

## Migration from OneDrive (per-user, staged)

For each family member, in sequence (starting with the account owner as the test case):

1. Provision their Nextcloud account (first Keycloak SSO login auto-provisions it, or pre-create locally if the folder needs to exist first).
2. `rclone sync onedrive-<user>:/ /mnt/nextcloud-data/<user>/files/` — run from a workstation with direct NFS access to that user's QNAP share path. One user's OneDrive at a time, not a single 600GB bulk pass, and not routed through Nextcloud's web upload/WebDAV.
3. `occ files:scan --path="/<user>/files"` — scoped to that user, not `--all`.
4. Verify: log in as that user, confirm folder structure, spot-check files (especially long paths / special characters, which OneDrive tolerates but can trip up `occ scan`).
5. Move to the next family member.

Bad migration for one user doesn't block or risk the others' data; each user can be migrated on their own schedule (e.g. kids' accounts after adults).

## Repository Structure

```
charts/nextcloud/ (if a local wrapper chart is needed) or direct OCIRepository chartRef
  — TBD at implementation-plan time based on whether upstream chart values suffice

cluster/apps/default/nextcloud/
  app-config.yaml                # appSubfolder: [app, onlyoffice]
  app/
    Chart.yaml
    values.yaml
    templates/
      externalsecret-oidc.yaml
      externalsecret-onlyoffice-jwt.yaml
      httproute.yaml (if not native chart support)
  onlyoffice/
    Chart.yaml
    values.yaml
    templates/
      externalsecret-jwt.yaml

cluster/apps/default/nfs-mounts/resources/
  nfs-nextcloud-data.yaml         # new static PV/PVC, QNAP-backed, per bjw-s/repo NFS pattern
```

## Open Questions (for implementation-plan phase)

- Exact QNAP share path/name for the new `nextcloud-data` NFS export (needs to be created on the NAS first).
- Whether the official Nextcloud Helm chart's default single-PVC assumption needs a postRenderer patch to split `html` vs `datadir` onto two separate PVCs, or whether `nextcloud.datadir` + `persistence.existingClaim` already supports this cleanly.
- Keycloak realm/client naming convention to match existing Harbor/other OIDC clients.
- Per-user OneDrive `rclone` remote credentials — how many distinct OneDrive accounts (personal vs family plan / shared drive) need separate `rclone` remotes configured.
