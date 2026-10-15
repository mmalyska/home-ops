# Usenet media stack (*arr + SABnzbd) design

Date: 2026-10-15
Status: draft, awaiting review

## Goal

Acquire TV, movies and music from usenet into the existing QNAP-backed
Jellyfin libraries, using the *arr stack and SABnzbd, configured to TRaSH
Guides defaults. Layout and app patterns are borrowed from
onedr0p/home-ops (`kubernetes/apps/default`), adapted to this repo's
ArgoCD ApplicationSet + `app-template` conventions.

## Decisions (agreed in brainstorming)

| Area | Decision |
|---|---|
| Storage | One QNAP share `/media`, mounted once as `/data` in every media pod, so downloads and libraries share a filesystem (hardlinks, atomic moves) |
| Existing media | `/tv-series`, `/movies`, `/music` are separate QNAP shares today; contents move into `/media/{tv-series,movies,music}` (user performs the QNAP move) |
| Downloader | SABnzbd. Incomplete/unpack on a ceph-block PVC, completed downloads on the NFS share |
| Apps | Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, SABnzbd. No Seerr |
| Repo layout | New ArgoCD category `media` (`cluster/apps/media/`), one ArgoCD app per component, all in namespace `media` |
| Config/state | SQLite on ceph-block per app, backed up with the local `volsync` chart (Jellyfin pattern) |
| App settings | Configured once in each UI. Recyclarr keeps TRaSH profiles/custom formats for Sonarr and Radarr in git |
| Access | Internal only: HTTPRoute on `envoy-internal`, app forms login required, nothing on Cloudflare |
| Identity | Run as 1001:1001, same as Jellyfin |
| Images | `ghcr.io/home-operations/*`, pinned `tag@digest`, Renovate-managed |
| Secrets | Indexer and news-provider credentials entered in the UIs (stored in app config on the volsync-backed PVC). *arr API keys pre-seeded from Bitwarden via ExternalSecrets. Nothing secret in git |
| News providers | Primary plus backup/block account(s), ordered by server priority in SABnzbd |

## Non-goals

- Seerr/request UI, external (internet) access, SSO in front of the apps.
- Postgres/CNPG for the *arrs, declarative indexer/download-client wiring.
- VPN: usenet over SSL does not need it.
- Metrics/alerts (exportarr, Prometheus rules): follow-up.
- Backing up the media itself (QNAP's concern, unchanged).

## Repository changes

### New ArgoCD category `media`

| File | Change |
|---|---|
| `cluster/appsets/appset-media.yaml` | Copy of `appset-games.yaml` with path `cluster/apps/media/*/app-config.yaml`, project `media`, name `appset-media` |
| `cluster/projects/media.yaml` | Copy of `projects/games.yaml`, name `media`, description "Media acquisition project" |
| `CLAUDE.md` | Add `media` to the category list |
| `docs/` | New page documenting layout, share structure, and operational notes (below) |

`applicationsSync: create-update` stays as in every other appset, so
removing an app later needs the manual procedure in
`reference_app_removal_procedure`.

### Apps under `cluster/apps/media/`

| App dir | Contents |
|---|---|
| `media-storage` | The shared `/media` PV + PVC (`media`) in namespace `media`. Only manifests, no workload |
| `sabnzbd` | app-template, config PVC (volsync), `incomplete` ceph PVC (not backed up), HTTPRoute |
| `prowlarr` | app-template, config PVC (volsync), HTTPRoute |
| `sonarr` | as above, mounts `media` PVC at `/data` |
| `radarr` | as above |
| `lidarr` | as above |
| `bazarr` | as above, `/data` writable (writes subtitles next to media) |
| `recyclarr` | CronJob + ConfigMap (`recyclarr.yml`), API keys from ExternalSecret |

Each app dir follows the repo pattern: `app-config.yaml` (namespace
`media`, `SECRET_PROVIDER: cluster-secrets` because hostnames use
`<secret:private-domain>`), `Chart.yaml` (app-template 5.3.0 and the local
`volsync` chart as in `bookorbit`/`jellyfin`), `values.yaml`, `templates/`.

Sync ordering is **not** relied on: the generated Applications are
independent, so pods stay `Pending`/`ContainerCreating` until the PV/PVC from
`media-storage` exists and the QNAP export is reachable, then recover on
their own.

### Storage

QNAP share `/media` (NFS export, nfsvers 4.1, same mount options as the
existing PVs: `tcp, intr, hard, noatime, nodiratime`):

```text
/media
├── usenet/complete/{tv,movies,music}   # SABnzbd categories
├── tv-series                           # Sonarr root folder, Jellyfin library
├── movies                              # Radarr root folder, Jellyfin library
└── music                               # Lidarr root folder, Jellyfin library
```

Every pod mounts the same PVC at `/data`, so container paths are identical
across SABnzbd and the *arrs (no remote path mappings):
`/data/usenet/complete/tv`, `/data/tv-series`, and so on. SABnzbd's
incomplete directory is `/incomplete`, a separate ceph-block PVC.

PV/PVC: `ReadWriteMany`, `persistentVolumeReclaimPolicy: Retain`,
`storageClassName: nfs-qnap` as the existing Jellyfin and bookorbit
volumes. A PV binds exactly one namespace, so Jellyfin (namespace
`jellyfin`) gets its own PV/PVC pointing at the same export.

### Jellyfin cutover

Jellyfin currently has three NFS PVs mounted at `/data/tvshows`,
`/data/movies`, `/data/music`. NFS PV `spec.nfs` is immutable, so they are
replaced, not edited.

- New PV/PVC `jellyfin-media` -> `/media`, mounted three times with `subPath`
  `tv-series`, `movies`, `music` at the **same container paths as today**.
  Jellyfin's database references those paths, so there is no library
  re-pointing, no rescan-from-scratch, and watch history is kept. Jellyfin
  never sees `/media/usenet`.
- Mount mode stays whatever it is today (read-write); not changed here.
- Old PVs/PVCs (`jellyfin-tv-shows`, `-movies`, `-music`) are deleted
  manually afterwards (`prune: false`).

### Per-app configuration

Common to the *arrs (Sonarr, Radarr, Lidarr, Prowlarr) and Bazarr:

- app-template controller, `pod.securityContext` 1001/1001,
  `fsGroupChangePolicy: OnRootMismatch`, `TZ: CET`.
- Config PVC `ceph-block` (Sonarr/Radarr/Lidarr 5Gi, Prowlarr/Bazarr/SABnzbd
  2Gi), backed up by the volsync chart using the Jellyfin values pattern.
- Auth via environment: forms login, authentication required (not
  `DisabledForLocalAddresses`). Username/password are set on first visit;
  until then the UI is open on the internal network only.
- API key pre-seeded from an ExternalSecret so Recyclarr, Prowlarr and Bazarr
  have stable keys. Pods that consume it carry the Reloader annotation.
- Service ClusterIP, no LoadBalancer IP assigned.
- HTTPRoute `<app>.<secret:private-domain>` on `envoy-internal`,
  `external-dns.alpha.kubernetes.io/controller: dns-controller`.
- Deployment strategy `Recreate` (RWO config PVC).
- Memory limit set, no CPU limit (matches repo convention). Initial values:
  *arrs 1Gi, SABnzbd 2Gi, Recyclarr 256Mi; revisit from observed usage.
- No node selector; the nv1 GPU node is tainted and these apps have no
  toleration, so they land on the M720q nodes.

Per app:

- **SABnzbd**: categories `tv`, `movies`, `music` mapping to
  `usenet/complete/<category>`. News servers entered in the UI, primary at
  priority 0, backup(s) on a different backbone at higher numbers.
  `host_whitelist` must contain the route hostname. Free-space pause set
  below the QNAP free-space floor. Remaining options follow the TRaSH
  SABnzbd guide.
- **Prowlarr**: three indexers added once; Sonarr/Radarr/Lidarr registered as
  applications with full sync. SABnzbd is a download client of each *arr, not
  of Prowlarr.
- **Sonarr/Radarr**: root folders `/data/tv-series`, `/data/movies`; SABnzbd
  download client with category `tv`/`movies`; Completed Download Handling on;
  "Use hardlinks instead of copy" on; naming and media-management per TRaSH.
  Quality profiles and custom formats come from Recyclarr.
- **Lidarr**: root folder `/data/music`; SABnzbd category `music`. Recyclarr
  does not support Lidarr, so profiles are set manually per TRaSH. Existing
  music library is imported without renaming or retagging until reviewed.
- **Bazarr**: connects to Sonarr/Radarr by service DNS and API key; subtitle
  provider accounts entered in the UI.
- **Recyclarr**: daily CronJob. `recyclarr.yml` in git references TRaSH
  templates for Sonarr and Radarr and reads instance URLs/API keys with
  `!env_var` from the ExternalSecret. Failure does not affect running apps.

## Rollout order

1. **QNAP (user):** create share `/media` on the same volume as the existing
   shares, NFS export allowed for the node IPs (192.168.48.2-5), files owned
   by 1001:1001, create the `usenet/complete/*` folders. Do not enable
   Windows ACLs on the share.
2. **PR A:** `media` category, `media-storage`, SABnzbd, Prowlarr, Sonarr,
   Radarr, Lidarr. Deploys against an empty `/media`; Jellyfin untouched.
3. **Hardlink test (read-only checks, then a scratch file):** from a media pod
   `ln` a test file between `/data/usenet/complete` and `/data/tv-series` and
   compare inodes. This gates everything after it.
4. Configure the apps in the UIs (providers, indexers, download clients).
5. **PR B:** Bazarr and Recyclarr.
6. **Jellyfin cutover (maintenance window):** pause Jellyfin through git
   (selfHeal reverts a plain scale-down), move content from the old shares
   into `/media/{tv-series,movies,music}`, merge **PR C** swapping the PVs
   and subPath mounts, resume, verify libraries and watch history, then
   delete the old PVs/PVCs and finally the old shares/exports.

Cluster mutations (pausing Jellyfin, deleting PVs, any sync) need explicit
user confirmation at the time, per the repo's hard rules.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Hardlinks do not work over this NFS/QNAP combination | Step 3 test before any content moves; fallback is copy+delete with the downloader and libraries unchanged |
| QNAP shares have ACLs that reject chmod/chown from *arrs | Step 1 forbids ACLs on the new share; *arr "Set permissions" left off |
| Cross-share move on QNAP copies instead of renaming | User verifies on the QNAP; migration time and temporary free space are the cost, not a design change |
| 2-bay NAS fills during usenet bursts | SABnzbd free-space pause; incomplete dir kept on ceph |
| ceph-block capacity for `incomplete` | Size chosen after checking free space (default proposal 100Gi) |
| Unauthenticated first-run window on new apps | Internal-only routes; credentials set immediately after first deploy |
| Jellyfin PV swap breaks library paths | Same container paths via `subPath`; no path change in Jellyfin |

## Verification

- `helm template` each app, `task lint:all` (yamllint, helmlint, prettier),
  gitleaks pre-commit.
- Post-deploy: pods Ready, HTTPRoutes resolve on the LAN, SABnzbd test
  download of a small NZB lands in `usenet/complete/tv`, Sonarr imports it as
  a hardlink (same inode), Jellyfin sees it.

## Documentation and memory

- New docs page for the media stack (share layout, app roles, URLs, runbook
  for hardlink test and Jellyfin cutover).
- `CLAUDE.md` category list updated.
- Add a memory note for the QNAP `/media` layout and the single-mount
  hardlink constraint once the cutover is done.

## Open items for review

1. Env-var names for API key, auth and SABnzbd host whitelist are
   unverified against the `ghcr.io/home-operations/*` images; confirm when
   writing the values.
2. `incomplete` PVC size and per-app config sizes are proposals.
3. Memory limits are starting points.
4. Whether Jellyfin should keep read-write access to the libraries.
5. When to delete the old shares after the cutover.
