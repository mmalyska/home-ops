# Nextcloud Family Files + Photos Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the existing Nextcloud the single family app for files and photos: working HEIC and video previews, a fast photo timeline with albums, a self-healing office editor (Euro-Office), and a written onboarding runbook.

**Architecture:** Everything stays chart-based under ArgoCD (`cluster/apps/default/nextcloud/{app,onlyoffice}`). A small custom image adds `ffmpeg` and `exiftool` on top of the official `fpm-alpine` image. Imperative Nextcloud state (app installs, admin settings) is captured in a `docs/` runbook. Each task below is its own branch and PR.

**Tech Stack:** Nextcloud 35.0.2 (chart `nextcloud` 9.4.1), Helm, ArgoCD, GitHub Actions + GHCR, Renovate, CNPG Postgres, Memories 10.x, Euro-Office Document Server 9.3.x.

**Spec:** `.plans/superpowers/specs/2026-10-25-nextcloud-family-media-design.md`

## Global Constraints

- Branch per task, `<type>/<slug>` in a worktree under `.worktrees/` (types `feat/`, `fix/`, `chore/`); never edit the primary checkout; PR to `main`, never push to `main`; push and open a PR right after committing.
- **Merging a PR deploys it** (ArgoCD `selfHeal`). Every merge, `kubectl` mutation (`create job`, `exec` that writes, `apply`) and `occ` write needs explicit user confirmation first. Read-only checks are free.
- Render before committing: `cd cluster/apps/default/nextcloud/app && helm dependency build && helm template nextcloud . -f values.yaml`, then `task lint:all`.
- Never write the private domain literally (use `<secret:private-domain>` tokens); secrets only via `ExternalSecret` or `cluster-secrets`; no Claude attribution in commits or PRs.
- `enabledPreviewProviders` **replaces** upstream defaults: the list must contain all 11 defaults: `PNG, JPEG, GIF, BMP, XBitmap, Krita, WebP, AVIF, MarkDown, TXT, OpenDocument`, plus additions.
- Image is amd64-only; tag equals the base tag (`35.0.2-fpm-alpine`); `LICENSE_CONNECTIONS` in Euro-Office is `99999`; Euro-Office JWT secret must be at least 32 characters.
- Cloudflare tunnel caps a request at 100 s (rely on chunked upload). Avoid new Ceph write load: previews and `appdata_*` live on the QNAP NFS PV, keep any new cache there.
- Open questions Q1 (library size vs ~580 GB free), Q2 (offsite backup for photos), Q3 (number of family members) are unanswered. They do not block Tasks 1 to 6; Task 7 and the mass import in Task 8 need Q1 and Q2 answered first.

## Review Focus

- Enabling `HEIC` by overriding the list and dropping a default (PNG, JPEG, ...) silently kills previews. Test pins all 12 providers (Task 1).
- Chart bump publishes `35.x` before the custom image `35.x-fpm-alpine` exists, causing `ImagePullBackOff`. Pin the tag, publish first (Task 3).
- First bulk phone upload plus pre-generation and indexing together exhaust the 2 Gi limit or CPU (Tasks 5, 8).
- Health-check job overlaps itself or runs while the pod is being replaced (`concurrencyPolicy: Forbid`, tolerate failure) (Task 2).
- Euro-Office migrates the reused DB schema forward, so rollback to ONLYOFFICE 9.0.0 may refuse it: take a CNPG backup first (Task 6).
- Same file name from two phones (Samsung camera names such as `20260927_131824.heic`) overwriting each other: confirm the Android app's per-device subfolder setting (Task 7).

---

### Task 1: HEIC previews through `enabledPreviewProviders`

**Files:**
- Modify: `cluster/apps/default/nextcloud/app/values.yaml` (`nextcloud.nextcloud.configs`, next to `proxy.config.php`)

**Interfaces:**
- Produces: `previews.config.php` key in `nextcloud.nextcloud.configs`; Task 4 appends `OC\Preview\Movie` to the same array.

- [ ] **Step 1: Write the failing render check**

Run (from `cluster/apps/default/nextcloud/app`): `helm template nextcloud . -f values.yaml | grep -oE "OC.Preview.(PNG|JPEG|GIF|BMP|XBitmap|Krita|WebP|AVIF|MarkDown|TXT|OpenDocument|HEIC)" | sort -u | wc -l`. Expected now: `0`.
- [ ] **Step 2: Add `previews.config.php`** setting `enabledPreviewProviders` to the 11 defaults plus `OC\Preview\HEIC`, and `preview_max_x`/`preview_max_y` = `2048`, `preview_concurrency_new` = `2`, `preview_concurrency_all` = `4`.
- [ ] **Step 3: Re-run the Step 1 command.** Expected: `12`. Run `task lint:all`.
- [ ] **Step 4: Commit, push, open PR** (`feat(nextcloud): enable HEIC previews`).
- [ ] **Step 5 (after user-confirmed merge and sync): live spike.** Open Photos in the browser, then run `kubectl -n nextcloud logs deploy/nextcloud-app -c nextcloud-nginx --since=5m | grep "photos/api/v1/preview/\(29[3-9]\|30[0-3]\)" | awk '{print $9}' | sort | uniq -c`. Pass: no `404` for the 8 HEIC files uploaded on 2026-10-25. Also run (confirmed) `occ config:app:set preview jpeg_quality --value=75`.
- [ ] **Step 6 (only if Step 5 still shows 404s):** enable the chart's `imaginary` block (`nextcloud.imaginary` values and `imaginary.config.php`), render, and repeat Step 5 in a follow-up PR. Record the result in the spec's Findings.

### Task 2: `occ` CronJobs and the connector health check

**Files:**
- Create: `cluster/apps/default/nextcloud/app/templates/occ-cronjobs.yaml` (ServiceAccount, Role with `pods` get/list and `pods/exec` create, RoleBinding, one CronJob per entry)
- Modify: `cluster/apps/default/nextcloud/app/values.yaml` (new top-level `occJobs`)

**Interfaces:**
- Produces: values schema `occJobs: [{name: string, schedule: string, command: [string]}]`; each entry renders CronJob `nextcloud-occ-<name>` running `kubectl -n nextcloud exec deploy/nextcloud-app -c nextcloud -- php occ <command...>`. Tasks 5 and 6 add or edit entries.

- [ ] **Step 1: Write failing render checks.** With `occJobs: []` the template renders nothing; with one entry `{name: connector-check, schedule: "*/15 * * * *", command: ["onlyoffice:documentserver","--check"]}` it renders exactly one CronJob `nextcloud-occ-connector-check`. Command: `helm template nextcloud . -f values.yaml | grep -c "kind: CronJob"` (expected `0` empty, `1` with the entry).
- [ ] **Step 2: Implement the template** with `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 1`, `failedJobsHistoryLimit: 3`, `backoffLimit: 0`, and a kubectl image already used elsewhere in the repo (`grep -rn kubectl cluster/apps --include=values.yaml`; pin by tag).
- [ ] **Step 3: Add the `connector-check` entry** (schedule `*/15 * * * *`) to `values.yaml`. Re-run Step 1 expecting `1`; `task lint:all`.
- [ ] **Step 4: Commit, push, open PR** (`feat(nextcloud): scheduled occ jobs and connector health check`).
- [ ] **Step 5 (after confirmed merge): live test.** With confirmation set a bad flag: `occ config:app:set onlyoffice settings_error --value=test`, wait one schedule, expect `occ config:app:get onlyoffice settings_error` to print nothing. Also check the Role exposes only exec on pods in `nextcloud`.

### Task 3: Custom Nextcloud image (two PRs, in order)

**Files:**
- Create (PR A): `images/nextcloud/Dockerfile`, `.github/workflows/nextcloud-image-publish.yaml`
- Modify (PR B): `cluster/apps/default/nextcloud/app/values.yaml` (`nextcloud.image.registry/repository/tag`), `.github/renovate/customManagers.json5`

**Interfaces:**
- Produces: image `ghcr.io/mmalyska/nextcloud:35.0.2-fpm-alpine` (tag = base tag). Tasks 4 and 5 need `ffmpeg`, `ffprobe`, `exiftool` on `PATH`.

- [ ] **Step 1 (PR A): Dockerfile** `FROM docker.io/library/nextcloud:35.0.2-fpm-alpine` then `RUN apk add --no-cache ffmpeg exiftool`. Renovate's built-in Dockerfile manager tracks the `FROM` line.
- [ ] **Step 2: Workflow** modelled on `.github/workflows/devcontainer-publish.yaml` (same pinned actions): trigger on `images/nextcloud/**` (PR build-only, push to main publishes), `linux/amd64` only, derive the tag from the `FROM` line with `sed`, push `ghcr.io/mmalyska/nextcloud:<tag>`.
- [ ] **Step 3: Smoke-test step that fails the build:** run the built image with `sh -c 'ffmpeg -version && ffprobe -version && exiftool -ver && php -m | grep -i imagick'`; the PR build must be green.
- [ ] **Step 4: Commit, push, open PR A** (`feat(images): nextcloud image with ffmpeg and exiftool`). After confirmed merge, confirm the package exists and is public like the other `ghcr.io/mmalyska` images (`gh api /user/packages/container/nextcloud` or an anonymous pull).
- [ ] **Step 5 (PR B): switch values.** Set `nextcloud.image.registry: ghcr.io`, `repository: mmalyska/nextcloud`, `tag: 35.0.2` with a `# renovate: datasource=docker depName=ghcr.io/mmalyska/nextcloud` comment, keeping `flavor: fpm-alpine`. Add a matching regex manager to `.github/renovate/customManagers.json5` for that file. Validate: `npx --yes renovate-config-validator` and `helm template ... | grep "image:.*nextcloud"` shows `ghcr.io/mmalyska/nextcloud:35.0.2-fpm-alpine`.
- [ ] **Step 6: Commit, push, open PR B** (`feat(nextcloud): run the custom image`). After confirmed merge: pod Ready, `kubectl exec ... -c nextcloud -- exiftool -ver` prints a version, `occ status` healthy, 0 restarts.
- [ ] **Step 7 (fallback, only if Memories later fails on musl):** switch the Dockerfile base to the Debian `fpm` flavor in a new PR; plan a deliberate `www-data` uid change (82 to 33) for the NFS data ownership.

### Task 4: Video thumbnails

**Files:**
- Modify: `cluster/apps/default/nextcloud/app/values.yaml` (`previews.config.php` array from Task 1)

**Interfaces:**
- Consumes: Task 1 `previews.config.php`, Task 3 image (`ffmpeg` on `PATH`; `preview_ffmpeg_path` defaults to a `PATH` lookup).

- [ ] **Step 1: Failing check:** `helm template ... | grep -c "OC.Preview.Movie"` expected `0`.
- [ ] **Step 2: Append `OC\Preview\Movie`** to the array; re-run, expect `1`; lint.
- [ ] **Step 3: Commit, push, PR** (`feat(nextcloud): enable video previews`). After confirmed merge, upload one MP4 and one MOV and confirm the preview request returns 200 (same nginx-log method as Task 1). MOV failures are known upstream; record the result in the spec.

### Task 5: Memories, preview pre-generation and resources

**Files:**
- Modify: `cluster/apps/default/nextcloud/app/values.yaml` (resources, `occJobs`), create `docs/src/k8s/nextcloud.md` and its nav entry (find the nav with `grep -rn "nv1-jetson" --include=*.yml --include=*.yaml .github docs mkdocs.yml 2>/dev/null`)

**Interfaces:**
- Consumes: Task 2 `occJobs`, Task 3 image.
- Produces: runbook page `docs/src/k8s/nextcloud.md` ("Admin setup" section), extended by Task 7.

- [ ] **Step 1: Set resources** to request `cpu: 100m`, `memory: 512Mi`, limit `memory: 2Gi` for the `nextcloud` container; add `occJobs` entry `preview-pre-generate` (schedule `*/10 * * * *`, command `["preview:pre-generate"]`). Render and lint.
- [ ] **Step 2: Commit, push, PR** (`feat(nextcloud): more memory and preview pre-generation`); confirmed merge.
- [ ] **Step 3 (confirmed `occ`):** `app:install memories`, `app:install previewgenerator`, `config:system:set memories.vod.cachedir --value=/var/www/html/data/memories-cache`, then `memories:index`. Check that the Memories admin page reports exiftool and ffmpeg found. If exiftool fails on musl, do Task 3 Step 7.
- [ ] **Step 4: Document every command and admin setting** in the "Admin setup" section of `docs/src/k8s/nextcloud.md`; add the nav entry; commit and PR (`docs(nextcloud): admin setup runbook`).
- [ ] **Step 5: Verify** the 11 test files plus one video appear in the Memories timeline with correct dates; Samsung motion photo plays.

### Task 6: Euro-Office instead of ONLYOFFICE

**Files:**
- Modify: `charts/onlyoffice-documentserver/values.yaml`, `charts/onlyoffice-documentserver/templates/deployment.yaml`, `charts/onlyoffice-documentserver/Chart.yaml` (version bump), `cluster/apps/default/nextcloud/onlyoffice/Chart.yaml` (dependency bump), `cluster/apps/default/nextcloud/app/values.yaml` (`connector-check` command)

**Interfaces:**
- Consumes: Task 2 `connector-check` entry. Produces: connector name `eurooffice` in `occJobs` (verify the fork's check command with `occ list eurooffice`).

- [ ] **Step 1: Read-only discovery.** Pull the pinned image tag (latest `9.3.x` release on `ghcr.io/euro-office/documentserver`) and record its environment variable names for DB and JWT and its data path (docs reference `/var/www/<package>/Data`) by reading the image's entrypoint script. Add `dataMountPath` to values if it differs from `/var/www/onlyoffice/Data`.
- [ ] **Step 2: Failing render check:** `helm template` of the onlyoffice app must render image `ghcr.io/euro-office/documentserver:<pinned tag>` and the discovered env names; today it renders `onlyoffice/documentserver:9.0.0`.
- [ ] **Step 3: Update chart values and `deployment.yaml`**, bump chart and dependency versions, render, lint.
- [ ] **Step 4: Safety.** Check the JWT secret length without printing it: `kubectl -n nextcloud get secret onlyoffice-jwt-secret -o jsonpath='{.data.JWT_SECRET}' | base64 -d | wc -c` must be at least `32`, otherwise update the Bitwarden value first. With confirmation, take an on-demand CNPG backup of `onlyofficedb`.
- [ ] **Step 5: Commit, push, PR** (`feat(onlyoffice): switch document server to Euro-Office`); after confirmed merge, in order (confirmed): `occ app:install eurooffice`, `occ app:disable onlyoffice`, set `DocumentServerUrl`, `DocumentServerInternalUrl`, `StorageUrl`, JWT secret via `occ config:app:set eurooffice ...` (mirroring the values shown by `occ config:list onlyoffice`, secret excluded from logs), then the fork's `--check`.
- [ ] **Step 6: Acceptance tests (all must pass):** `Wydatki.xlsx` opens and saves; a DOCX opens and exports to PDF; a PDF form is created and filled; two users co-edit; after `kubectl rollout restart deploy/onlyoffice` the editor still opens a file with no manual `occ`.
- [ ] **Step 7: Rollback path (only if a test fails):** revert the PR, `occ app:enable onlyoffice`, `occ app:disable eurooffice`, run the ONLYOFFICE check; restore the DB from the Step 4 backup if the old image refuses the schema. Update the spec's Findings with the result either way.
- [ ] **Step 8: Update the `connector-check` command** to the Euro-Office check in the same PR series, and update the "onlyoffice-stuck-document" skill if the new editor changes its diagnosis.

### Task 7: Family onboarding runbook

**Files:**
- Modify: `docs/src/k8s/nextcloud.md` (add "Onboarding a family member")

**Precondition:** Q1 and Q2 answered by the user.

- [ ] **Step 1: Verify (read-only first, then with a test account):** Android and desktop client login against `user_oidc` (browser flow to an app password), and whether Keycloak groups map to Nextcloud groups. Record the real result, not an assumption.
- [ ] **Step 2: Write the procedure:** Keycloak user, first login auto-provisioning, group and quota (`occ user:setting <uid> files quota <size>`), Android app auto-upload (Wi-Fi only, per-device subfolder, "All files access" permission reported by community, unofficial), macOS and Windows desktop clients, sharing a folder or album, Samsung motion photos behaviour.
- [ ] **Step 3: Lint (`task lint:all`), commit, PR** (`docs(nextcloud): family onboarding runbook`).

### Task 8: Load test and close-out

- [ ] **Step 1 (needs Q1, Q2 answered):** with the user, upload at least 300 phone photos and videos at once from one real device. Record: `kubectl -n nextcloud get pod` restarts, `kubectl top pod --containers`, count of 5xx in nginx logs, Memories timeline completeness, and the Ceph write rate over the upload window using the `prometheus-portforward-session` and `prometheus-historical-queries` skills.
- [ ] **Step 2: Pass criteria:** no restart or OOM, no 5xx, no new alert, Ceph write rate within its recent 0.34 to 0.39 MB/s range, all files with thumbnails. Tune `pm.max_children`, memory, and `preview_concurrency_*` in a follow-up PR if not.
- [ ] **Step 3: Close the plan:** move the spec and this plan to `.archive/.plans/superpowers/{specs,plans}/`, update both `list.md` files and every link, and commit (`chore(plans): archive nextcloud-family-media`).
