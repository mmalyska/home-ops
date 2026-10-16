---
name: QNAP /media share layout (usenet stack)
description: One QNAP share /media mounted as /data by every media pod; hardlinks need the single mount; folder ownership 1001; old shares retired
metadata:
  type: reference
---

The usenet stack (namespace `media`, see docs/src/k8s/media.md) uses one QNAP NFS share `/media` (export 192.168.48.0/22, sys, no-squash, ACLs off), mounted once per pod as `/data`:

- `usenet/complete/{tv,movies,music}` (SABnzbd categories), `tv-series`, `movies`, `music` (library roots, all owned 1001:1001, mode 775).
- Jellyfin mounts it through its own PV/PVC `jellyfin-media` with subPaths at `/data/tvshows`, `/data/movies`, `/data/music`; Music Assistant mounts `subPath: music` read-only at `/media/music`.

**Why:** hardlink imports and atomic moves only work inside one filesystem and one mount. A second mount of the same export still works for read access, but downloads and libraries must stay on the same mount inside the pods that import (SABnzbd, Sonarr, Radarr, Lidarr).

**How to apply:**
- New media consumers mount `/media` with a `subPath`; never re-split into separate shares.
- subPath directories must pre-exist owned by 1001, or kubelet creates them root-owned.
- QNAP File Station cannot write to `/media` as an ordinary user (owner is uid 1001). Move or copy data with a throwaway root pod that mounts the shares, then chown 1001:1001. Do not use busybox `cp -n` on a directory that already exists, it silently copies nothing.
- The old shares `/tv-series`, `/movies`, `/music` have been unused by the cluster since 2026-10-16; earliest deletion 2026-10-30.
- Jellyfin does not see NFS changes made by other clients (no inotify): add the Jellyfin Connect entry in Sonarr/Radarr or run a library scan.
