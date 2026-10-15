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
| `media-storage`                | the shared `/media` PV and PVC       | -                           |

All routes are on `envoy-internal` only. Each app has forms login with authentication required; the first visit asks
for an admin user, so create it right after the first deploy.

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

1. SABnzbd: add the news servers (primary at priority 0, backup on another backbone at a higher number), create
   categories `tv`, `movies`, `music` pointing at `usenet/complete/<category>`, set the incomplete dir to
   `/incomplete`, and set the free-space pause. Follow the TRaSH SABnzbd guide for the rest.
2. Prowlarr: add the three indexers, then register Sonarr, Radarr and Lidarr as applications with full sync.
3. Sonarr / Radarr / Lidarr: add SABnzbd as a download client with the matching category; root folders
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
- Not part of this stack yet: Bazarr, Recyclarr, metrics and alerts, and moving Jellyfin onto `/media`.
