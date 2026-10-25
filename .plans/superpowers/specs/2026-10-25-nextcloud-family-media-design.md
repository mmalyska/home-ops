# Nextcloud as the Family's Single Files + Photos App — Design

**Date:** 2026-10-25
**Status:** Approved by the user on 2026-10-25 (open questions 1 to 3 below still unanswered)
**Builds on:** `.archive/.plans/superpowers/specs/2026-07-02-nextcloud-onedrive-replacement-design.md` (the deployment that already exists: Nextcloud + ONLYOFFICE, Keycloak SSO, QNAP NFS data, CNPG Postgres, Dragonfly)

## Intent

The family should be able to leave OneDrive (and cloud photo backup) entirely and use **one app**, Nextcloud, for:

- files: edit documents, spreadsheets, forms, export to PDF, share, sync to macOS and Windows;
- photos and videos: automatic backup from Samsung phones, a browsable timeline, albums, sharing;
- user management: easy to add or remove family members, set quotas, share between them.

The deployment from July already covers files and editing. This design closes the **photos gap** and tidies the **office editor**. It was triggered by a live test on 2026-10-25: eight Samsung HEIC photos uploaded fine but showed no thumbnails, and an xlsx downloaded instead of opening (see "Findings").

## Decisions made with the user

- **One app.** Immich (and any second photo app) was considered and rejected. Everything stays in Nextcloud.
- **Everyone in the family** will back up their phone photos and videos here, not just the owner.
- **Mail, calendar and contacts are out of scope** (Gmail covers them).
- Keep the existing architecture: chart-based deployment under ArgoCD, not Nextcloud All-in-One (AIO needs a Docker host and its own domain/proxy handling and does not fit Talos + GitOps + Keycloak + NFS).
- Work in phases, spike-first where upstream behaviour is unverified.

## Findings (state on 2026-10-25, read-only)

- Nextcloud **35.0.2** (latest stable; 36 is not released, only `master`). Chart `nextcloud` 9.4.1, image `fpm-alpine`. The wrapper `Chart.yaml` `appVersion: "34.0.1"` is stale metadata only.
- Enabled apps: stock `photos` 8.0.0, `onlyoffice` connector 10.2.1, `user_oidc`. No `memories`, no `previewgenerator`, no `recognize`.
- PHP `imagick` supports HEIC, HEIF, AVIF, WebP, DNG. **`ffmpeg`, `ffprobe`, `exiftool` are not in the image.**
- `enabledPreviewProviders` is unset, so upstream defaults apply. Per the Nextcloud docs the default list has 11 providers and contains **neither `HEIC` nor `Movie`**. Observed: of 11 uploaded files, 3 JPG previews returned 200 and 8 HEIC previews returned 404.
- Upstream risk: a forum thread reports Nextcloud 34.0.2 stopped HEIC previews as a workaround for an undisclosed Imagick security issue, with a fix merged for a release planned 13 Aug 2026. It is **not confirmed** that 35.0.2 renders HEIC when the provider is enabled.
- ONLYOFFICE showed "download instead of open" because the connector stored `settings_error` ("Error while downloading the document file to be converted"). Five connector listeners only register the editor when that value is empty, and the connector's own cron check never clears it. It was cleared by running `occ onlyoffice:documentserver --check` (approved, done). The ONLYOFFICE pod had a normal restart (`Completed`, exit 0) about two days earlier, which is the likely trigger (not proven).
- User data and the preview cache (`appdata_*`) live on the QNAP NFS PV, not on Ceph. Ceph holds only the 5 Gi app PVC and the Postgres volumes. The data share reports ~959 GB total, ~379 GB used, ~580 GB free.
- Resources today: Nextcloud container request 256 Mi / limit 1 Gi, PHP `pm.max_children = 20`. Under light upload load it used ~250 Mi and 212m CPU.
- Only one real user exists and ~380 MB of data. Nothing has been migrated, so changes here do not need to preserve a large library.

## Goals

1. Samsung photos (HEIC and JPEG) and videos back up automatically from the Nextcloud Android app and appear with working thumbnails in a fast timeline, with albums and sharing, including Samsung motion photos.
2. Videos get thumbnails and play back in the browser.
3. Browser editing of DOCX/XLSX/PPTX and PDF forms keeps working, and **stays working across restarts** without manual fixes.
4. macOS and Windows desktop sync works for every family member.
5. Adding a family member is a short documented procedure (Keycloak user, Nextcloud group, quota, app setup).
6. Every change is declarative in git (PR per phase), except app installs and admin settings that Nextcloud stores in its own database; those are captured in a runbook in `docs/`.

## Non-goals

- Mail, calendar, contacts, Talk, whiteboard.
- Face/object recognition (`recognize`): CPU-heavy, deferred.
- Any second photo application.
- Migrating existing OneDrive data (covered by the July spec's per-user `rclone` procedure; unchanged).
- Offsite backup (declined in July; see Open questions).

## Anti-goals (a failure even if it technically works)

- Phone backup that is slow to browse, or that exhausts RAM and crashes the pod during the first big upload.
- Losing or altering original photos or videos (no server-side conversion of originals).
- Increasing Ceph write load meaningfully (the Ceph SATA disks are already wear-constrained, see `.plans/TODO.md`).
- Swapping the office editor without a tested way back.

## Constraints

- Repo rules in `CLAUDE.md`: secrets only via ExternalSecret or `cluster-secrets` tokens, never write the private domain literally (use `<secret:private-domain>`), render manifests before committing, no cluster mutation without confirmation, changes by PR from a `feat/` or `fix/` branch, update docs in the same change.
- Cloudflare tunnel caps a single request at 100 s; large uploads rely on Nextcloud's chunked upload (the Android and desktop clients use it).
- Nodes are amd64 (Lenovo M720q). The arm64 GPU node is not used by Nextcloud.
- The ONLYOFFICE deployment is a local chart, `charts/onlyoffice-documentserver` (image repository and tag are values), with a CNPG database `onlyofficedb`.

## Design

### Phase 1 — Previews and editor reliability (small PRs, no new image)

- Set `enabledPreviewProviders` in the `nextcloud.configs` block. **It replaces the defaults**, so the list must contain the full default 11 plus `OC\Preview\HEIC` and (once ffmpeg exists) `OC\Preview\Movie`. Also consider `OC\Preview\TIFF`, `OC\Preview\AVIFImagick`.
- Tune previews (my call, to be validated): cap `preview_max_x`/`preview_max_y` around 2048, `jpeg_quality` 70 to 80, set `preview_concurrency_new` to 2 and `preview_concurrency_all` to 4 to protect the pod.
- **Spike first:** after enabling `HEIC`, check that a real uploaded Samsung `.heic` renders on 35.0.2. The eight files from 2026-10-25 are the test set. If it does not render, fall back to the Imaginary preview service (a small Deployment, `preview_imaginary_url`), which is also useful for video-free speed.
- Add a scheduled **connector health check**: a CronJob (my call: every 15 minutes) that runs `occ <connector>:documentserver --check` in the Nextcloud pod context (or a sidecar-based equivalent), so a transient failure self-clears. Must work for whichever connector (ONLYOFFICE or Euro-Office) is active after Phase 4.

### Phase 2 — Custom Nextcloud image (ffmpeg, exiftool)

- New `images/nextcloud/Dockerfile`: `FROM docker.io/library/nextcloud:<ver>-fpm-alpine`, `apk add --no-cache ffmpeg exiftool` (plus `perl` if exiftool needs it). This is the route upstream documents ("build your own image on top of it").
- New GitHub Actions workflow modelled on `.github/workflows/devcontainer-publish.yaml`, publishing `ghcr.io/mmalyska/nextcloud` (amd64 only, my call).
- Renovate: track the base tag in the Dockerfile; the live image tag in `values.yaml` follows the published image. **Ordering matters:** a base bump must build and publish before the deploy value moves.
- Set `preview_ffmpeg_path`/`preview_ffprobe_path` if needed; enable `OC\Preview\Movie`.
- **Unverified upstream:** whether Memories' exiftool works on Alpine/musl. The spike decides it. Fallback: switch the image base to the Debian `fpm` flavor (changes the `www-data` uid from 82 to 33, which affects data-volume ownership and needs a deliberate migration).

### Phase 3 — Memories + preview pre-generation

- Install the Memories app (v10.2.0 supports Nextcloud 34 to 35). Configure through its admin panel (upstream recommends the UI for file types); record settings in the runbook.
- Run the initial `occ memories:index`; later uploads index via hooks.
- Install `previewgenerator` and run `preview:pre-generate` from the existing cron sidecar on a schedule (my call: every 10 minutes) so first scroll is not slow.
- Keep the stock Photos app for albums and sharing; Memories uses its albums.
- Raise resources (my call, to validate with the first bulk upload): Nextcloud memory limit 1 Gi to 2 Gi, a modest CPU request, and review `pm.max_children`. The Memories index lives in Postgres: watch Ceph write rate after the first indexing run.
- Memories needs a persistent transcode cache directory if on-the-fly video transcoding is used (`memories.vod.cachedir`); place it on the NFS PV, not Ceph.

### Phase 4 — Euro-Office instead of ONLYOFFICE (spike-first, reversible)

Why: Euro-Office (Nextcloud + IONOS backed fork) has no 20-connection cap in source (`LICENSE_CONNECTIONS = 99999`), lists PDF form creation/editing, has an official Nextcloud connector (`eurooffice` 11.0.6, Nextcloud 33 to 36), and removes dependence on a vendor that ended its Nextcloud partnership. Risks: young project, the container is a "community build"; Nextcloud's signed distribution has no container image yet; version churn.

- Change the local chart values to `ghcr.io/euro-office/documentserver` pinned to a specific tag (not `latest`); the JWT secret must be at least 32 characters (check the existing ExternalSecret).
- Install the Euro-Office connector app and disable (not delete) the ONLYOFFICE connector so rollback is re-enabling it.
- Reuse `onlyofficedb` first; document-server state is transient. If the fork refuses the existing schema, create a fresh CNPG cluster (keep the same chart).
- **Acceptance test before merging:** the existing `Wydatki.xlsx` opens and saves, a DOCX opens and exports to PDF, a PDF form can be created and filled, two users co-edit, and the editor survives a Document Server pod restart.
- **Rollback:** revert the PR, re-enable the ONLYOFFICE connector, `occ <connector>:documentserver --check`. No documents move, so rollback is safe.
- Keep the namespace, app names and chart names unchanged for now (my call); rename later in its own PR.

### Phase 5 — Family onboarding runbook (docs)

A page under `docs/` covering, per family member: create the Keycloak user, first login auto-provisions the Nextcloud account, add to groups, set quota, install the Android app and enable auto-upload (Wi-Fi only, charging optional, "All files access" permission per community reports, unofficial), install macOS and Windows desktop clients, share the Photos folder or albums. Include the decision on Samsung motion photos (Memories handles them; the stock Photos app does not).

Two things the builder must verify, not assume: (1) whether the Android and desktop clients can log in against the `user_oidc` setup (the usual route is the browser login flow producing an app password); if not, the runbook must say how family members get app passwords; (2) whether Keycloak groups map to Nextcloud groups (needed for quotas and shared folders) or groups are managed in Nextcloud by hand.

### Phase 6 — Optional later

Imaginary (if not needed in Phase 1), `notify_push` for instant sync, `recognize` for faces (CPU cost, probably after hardware changes).

## Verification (what "done" means)

- The 11 files uploaded on 2026-10-25 all have thumbnails, including the 8 HEIC.
- A new Samsung photo and video auto-uploaded from a phone appear in the Memories timeline with thumbnails and play back.
- A bulk upload of several hundred files completes without a pod restart, OOM, 5xx, or alert, and the Ceph write rate stays within its recent range.
- xlsx/docx/pdf open in the browser after a Document Server restart without any manual `occ` step.
- `helm template`/`kubectl kustomize` render clean, `task lint:all` passes, docs updated.

## Open questions for the user

1. **Total expected size** of the family library (OneDrive ~600 GB per the July plan, plus all phone photos and videos): the NAS share shows ~580 GB free. Is that enough, and is there a plan to grow it?
2. **Offsite backup**: it was declined in July for OneDrive-style files. The data now includes irreplaceable family photos with only QNAP snapshots protecting them. Does the earlier decision still stand?
3. **Number of family members and phones** (drives quotas, concurrency, and the first-upload load test).

## Left to the builder

Exact PHP and Memories settings values, resource numbers (after measuring), whether the health check is a CronJob or a sidecar, image tag scheme, Imaginary vs native HEIC, and the order of Phases 2 and 3 if the spike shows exiftool works without the custom image.
