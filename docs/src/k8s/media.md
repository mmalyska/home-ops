# Media stack (usenet)

SABnzbd and the \*arr apps run in namespace `media` (ArgoCD category `cluster/apps/media/`, project `media`). Every app
is its own ArgoCD app built on bjw-s `app-template`, with images from `ghcr.io/home-operations/*`. The design is in
`docs/superpowers/specs/2026-10-15-usenet-media-stack-design.md`.

## Apps

| App                            | Role                                 | URL (LAN only)              |
| ------------------------------ | ------------------------------------ | --------------------------- |
| `sabnzbd`                      | usenet downloader                    | `sabnzbd.<private-domain>`  |
| `prowlarr`                     | indexer manager, syncs to the \*arrs | `prowlarr.<private-domain>` |
| `sonarr` / `radarr` / `lidarr` | TV / movies / music                  | `<app>.<private-domain>`    |
| `bazarr`                       | subtitles for Sonarr and Radarr      | `bazarr.<private-domain>`   |
| `recyclarr`                    | daily CronJob, syncs TRaSH profiles  | -                           |
| `media-storage`                | the shared `/media` PV and PVC       | -                           |

All routes are on `envoy-internal` only. The \*arrs run with `AUTH__REQUIRED=Enabled` and no preset method, so the first
visit shows the authentication setup: choose Forms and create the admin user right after the first deploy. SABnzbd has
no such prompt and is open to the LAN until you set a username and password (General, Security), so do that first.

## Storage layout

The QNAP share `/media` is mounted once (PVC `media`) at `/data` in every pod, so downloads and libraries share a
filesystem and imports are hardlinks:

```text
/data
├── usenet/complete/{tv,movies,music}   # SABnzbd categories
├── tv-series                           # Sonarr root folder, Jellyfin library
├── movies                              # Radarr root folder, Jellyfin library
└── music                               # Lidarr root folder, Jellyfin library
```

SABnzbd's incomplete directory is `/incomplete`, a 100Gi ceph-block PVC (`sabnzbd-incomplete`, not backed up). Config
PVCs are ceph-block and backed up by volsync. Container paths are identical in every pod, so no remote path mappings
are needed.

## API keys

`SONARR_API_KEY`, `RADARR_API_KEY`, `LIDARR_API_KEY` and `PROWLARR_API_KEY` live in Bitwarden and reach the pods
through each app's `<app>-secrets` ExternalSecret (`<APP>__AUTH__APIKEY`). Everything else (indexers, news servers,
download clients) is entered in the UIs and stored in the config PVCs.

## First-run setup order

1. SABnzbd: set a username and password (General, Security), add the news servers (primary at priority 0, backup on another backbone at a higher number), create
   categories `tv`, `movies`, `music` pointing at `usenet/complete/<category>`, set the incomplete dir to
   `/incomplete`, and set the free-space pause. Follow the TRaSH SABnzbd guide for the rest.
2. Prowlarr: add the three indexers, then register Sonarr, Radarr and Lidarr as applications with full sync.
3. Sonarr / Radarr / Lidarr: add SABnzbd as a download client (host `sabnzbd`, port 8080; the short service name and the
   `.media.svc.cluster.local` forms are in its host whitelist) with the matching category; root folders
   `/data/tv-series`, `/data/movies`, `/data/music`; Completed Download Handling on; "Use hardlinks instead of copy"
   on; naming per TRaSH.

## Hardlink check

Run once after the share is populated (it needs a writable `/data`):

```sh
kubectl -n media exec deploy/sabnzbd -- sh -c 'echo test > /data/usenet/complete/.hl-src && ln /data/usenet/complete/.hl-src /data/tv-series/.hl-dst && stat -c "%i %h %n" /data/usenet/complete/.hl-src /data/tv-series/.hl-dst; rm -f /data/usenet/complete/.hl-src /data/tv-series/.hl-dst'
```

Both lines must show the same inode and link count 2. Different inodes or `Operation not permitted` mean hardlinks do
not work on this export and imports fall back to copy.

## Notes

- Pods stay `ContainerCreating` until the QNAP export exists and is reachable; there is no alert for that.
- Removing an app needs the manual procedure in the repo memory (`reference_app_removal_procedure`); the appset never
  prunes Applications.
- Not part of this stack yet: metrics and alerts.

## Jellyfin

Jellyfin (namespace `jellyfin`) has its own PV/PVC `jellyfin-media` on the same `/media` export and mounts three
`subPath`s at the same container paths as before: `tv-series` at `/data/tvshows`, `movies` at `/data/movies` and `music`
at `/data/music`. The `subPath` directories must exist and be owned by 1001 before the pod starts, otherwise kubelet
creates them root-owned. The libraries inside Jellyfin did not need to change.

## Recyclarr

A CronJob (`30 4 * * *`) runs `recyclarr sync` against Sonarr and Radarr and keeps the TRaSH quality definitions, the
`WEB-1080p` profile (Sonarr) and the `HD Bluray + WEB` profile (Radarr) with their custom formats in place. Recyclarr
v8 templates are complete configs, so the config in `cluster/apps/media/recyclarr/values.yaml` is a copy of those two
templates (default custom format groups only). To change a profile or enable an optional group, edit that ConfigMap
using the templates in the `recyclarr/config-templates` repository as the reference. Lidarr is not managed.

After the first deploy, run a sync once and read the log:

```sh
kubectl -n media create job --from=cronjob/recyclarr recyclarr-manual
kubectl -n media logs job/recyclarr-manual
kubectl -n media delete job recyclarr-manual
```

Then pick the new profile on the series and movies (the default profile is not changed by Recyclarr).

## Bazarr

Bazarr mounts `/data` and writes subtitles next to the media. In its UI set a login (Settings, General, Security), add
Sonarr (`sonarr`, port 8989) and Radarr (`radarr`, port 7878) with their API keys (Settings, Sonarr / Radarr), and add
subtitle providers and languages.
