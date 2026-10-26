# Nextcloud (family files and photos)

Nextcloud in namespace `nextcloud` (ArgoCD apps `nextcloud-app` and `nextcloud-onlyoffice`, category `cluster/apps/default/nextcloud/`).
It replaces OneDrive for the family: files, document editing (ONLYOFFICE), sharing, and phone photo/video upload with the
Memories timeline. Sign-in is Keycloak (`user_oidc`). The design is in
`.plans/superpowers/specs/2026-10-25-nextcloud-family-media-design.md`.

## How it is put together

| Part             | What                                                                                                                    |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Image            | `ghcr.io/mmalyska/nextcloud`, built in [mmalyska/containers](https://github.com/mmalyska/containers) (`apps/nextcloud`) |
| Chart            | upstream `nextcloud` chart, `fpm-alpine` plus an nginx sidecar                                                          |
| Database / cache | CNPG Postgres (`nextclouddb-cnpg`) and a Dragonfly instance                                                             |
| Data             | user files and `appdata_*` (previews) on the QNAP NFS PV; the app code and config on a 5 Gi Ceph PVC                    |
| Routes           | `envoy-external` (internet, Cloudflare tunnel) **and** `envoy-internal` (LAN), see "LAN access"                         |
| Editor           | ONLYOFFICE document server, own app, own CNPG database                                                                  |

The custom image is the official `nextcloud:<version>-fpm-alpine` plus `ffmpeg`, `exiftool`, the ImageMagick HEIC coder
(`imagemagick-heic`), the Intel VAAPI driver (`intel-media-driver`, `vainfo`) and `/usr/local/bin/memories-ffmpeg`.
Tags are `<version>` (no flavor suffix); `values.yaml` pins `tag: <version>@sha256:...`, and a containers rebuild under the
same tag shows up as a digest change that has to be bumped in `values.yaml`.

## Sizing assumptions

- Library: about 400 GB for the family, on a share with about 580 GB free. Previews add roughly 10-20 % (the
  `preview_max_x/y` cap is 2048 px), plus versions and trash. Watch the free space on the NFS volume.
- **The QNAP holds the only copy.** Phones keep originals until the user frees space, so tell the family not to use
  "free up space" until there is an offsite copy. Recommended: QNAP snapshots on the share, and Hybrid Backup Sync to an
  encrypted cloud bucket. These are QNAP-side settings and are not in the cluster repo.

## Resources and why

The `nextcloud` container has request `cpu: 100m`, `memory: 512Mi` and limits `cpu: 4`, `memory: 4Gi`, plus one
`gpu.intel.com/i915`.

- **Memory.** At 1 Gi the pod was OOM-killed in a loop as soon as HEIC and video previews worked: php-fpm workers decode
  full-size photos and ffmpeg runs in the same cgroup. One HDR video transcode peaks at about 2.3 GiB (measured), so the
  limit is 4 Gi for two at once. The `MAGICK_MEMORY_LIMIT`, `MAGICK_MAP_LIMIT` and `MAGICK_THREAD_LIMIT` env vars make
  ImageMagick spill to disk instead of RAM.
- **GPU.** The nodes have an Intel iGPU (Talos udev rule `50-udev-render-device.yaml`, Intel device plugin, 4 shares per
  node), the same as Jellyfin. The runtime owns the render node by the container's uid:gid, so the container sets
  `runAsGroup: 82` (www-data) to get read/write on `/dev/dri/renderD128`.
- **php-fpm** has `pm.max_children = 20`; the default of 5 starved the liveness probe under normal browsing.

## LAN access

The AdGuard external-dns only publishes records for routes attached to `envoy-internal`. A route on `envoy-external` alone
makes LAN clients resolve the hostname to Cloudflare, so every upload leaves through the internet uplink and returns
through the tunnel (measured: 114-274 KB/s). Nextcloud and ONLYOFFICE therefore each have a second route
(`httproute-internal.yaml`) on `envoy-internal`. After a change, client devices may need a DNS flush or reconnect.

## Admin setup (imperative state)

Everything below lives in the database or the data volume, not in git, so it is repeated here. Run `occ` as `www-data`
(the exec shell is root, and root-owned files break php-fpm):

```sh
occ() { kubectl -n nextcloud exec deploy/nextcloud-app -c nextcloud -- su -s /bin/sh www-data -c "cd /var/www/html && php occ $*"; }
```

Apps (installed 2026-10-25):

```sh
occ app:install memories           # 10.2.0
occ app:install previewgenerator   # 5.15.0
occ memories:index                 # first run; later uploads are indexed by hooks
```

Memories video transcoding (system config; the defaults are `disable: true` and empty paths):

```sh
occ config:system:set memories.vod.disable --type=boolean --value=false
occ config:system:set memories.vod.ffprobe --value=/usr/bin/ffprobe
occ config:system:set memories.vod.ffmpeg  --value=/usr/local/bin/memories-ffmpeg   # the wrapper, not /usr/bin/ffmpeg
occ config:system:set memories.vod.cachedir --value=/var/www/html/data/memories-cache   # on NFS, owned by www-data
occ config:system:set memories.vod.vaapi --type=boolean --value=true
occ config:system:set memories.vod.vaapi.device --value=/dev/dri/renderD128
occ config:system:set memories.vod.use_transpose --type=boolean --value=true         # portrait phone videos
```

`use_transpose` is what makes portrait videos (stored 4K landscape with a rotation flag) play upright in Memories.
`mkdir /var/www/html/data/memories-cache` must be done as `www-data` (or `chown`ed afterwards).

Declarative parts: `previews.config.php` in `values.yaml` (see below), and the CronJobs in `occJobs`.

## Previews

`enabledPreviewProviders` **replaces** the upstream default list, so the 11 defaults stay in it and `HEIC` and `Movie` are
added. HEIC needs the ImageMagick HEIC coder in the image (`Imagick::queryFormats('HEIC')` must not be empty), otherwise
every HEIC thumbnail returns 404 and the web viewer offers a download. The CronJob `nextcloud-occ-preview-pre-generate`
runs `occ preview:pre-generate` every 10 minutes (as `www-data`) so a new upload has thumbnails before anyone opens it.

## Video playback

- **Use Memories to watch videos.** The Files viewer plays the original file. Samsung phones record 4K60 HEVC at about
  51 Mbit/s, often in HLG HDR: browsers stutter on that and show washed-out, over-bright colours. Memories transcodes to
  a smaller SDR HLS stream and tone-maps correctly.
- **How the transcode runs.** go-vod uses the GPU to decode and encode (VAAPI). HLG has no HDR10 metadata, so GPU tone
  mapping (`tonemap_vaapi`) is impossible, and go-vod's OpenCL path is not available (Alpine's ffmpeg has no OpenCL).
  The tone mapping therefore runs in software on the CPU after scaling down.
- **The wrapper.** go-vod builds `-vf hwdownload,format=p010le,scale=...` which copies every 4K 10-bit frame to the CPU
  and only then scales: 0.4x real time on a 4K60 clip, so each chunk takes longer to make than to play. The wrapper
  `memories-ffmpeg` rewrites that one graph so the GPU scales first and caps the output at 30 fps (2.6x real time). All
  other ffmpeg calls pass through unchanged. If a Memories update changes the graph, the rewrite stops matching and the
  stutter returns; the Goss test in the containers repo covers the current form.
- **Limits.** 1080p HDR is too slow on this iGPU (0.45x real time even with the GPU scale first), so HDR clips are
  practical at 480p and 720p. The player's quality menu still offers 1080p and picking it will stutter. SDR videos use
  the GPU-only path and are fast. On the phones, turning off HDR video recording avoids the whole problem.
- **Measured** (one HDR stream, 4K60 HLG source): up to about 2.8 CPU cores, 2.3 GiB peak, no throttling.

## Troubleshooting

| Symptom                                        | Cause and fix                                                                                                                                        |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| xlsx downloads instead of opening              | Euro-Office connector `settings_error` set; the `connector-check` CronJob clears it every 15 minutes, or run `occ eurooffice:documentserver --check` |
| HEIC has no thumbnail                          | the image lacks `imagemagick-heic`, or `HEIC` is missing from `enabledPreviewProviders`                                                              |
| pod `OOMKilled`, 502 on the probes             | memory limit too low for previews or transcodes, see "Resources and why"                                                                             |
| uploads at 100-300 KB/s on the LAN             | client resolves to Cloudflare; check `nslookup` returns `192.168.48.21`, flush DNS                                                                   |
| video plays rotated in Memories                | `memories.vod.use_transpose` is false                                                                                                                |
| video stutters, new chunk every ~5 s           | the ffmpeg wrapper is not set as `memories.vod.ffmpeg`, or the 1080p variant of an HDR clip was chosen                                               |
| `vainfo` or ffmpeg cannot open the render node | the container lost `runAsGroup: 82` or the `gpu.intel.com/i915` request                                                                              |

Check the GPU from the pod: `su -s /bin/sh www-data -c "vainfo --display drm --device /dev/dri/renderD128"`.
Do not run heavy ffmpeg tests in the live pod: a 1080p tone-mapping test next to a playing stream OOM-killed the container.

## Not done yet

Family onboarding (Keycloak user, groups, quota, Android auto-upload settings, macOS/Windows sync clients) and the
Euro-Office replacement of ONLYOFFICE are tracked in the plan `2026-10-25-nextcloud-family-media`.
