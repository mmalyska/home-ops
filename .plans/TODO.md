# TODO

General backlog items not tied to a specific migration plan.

---

## Infrastructure — CNPG

- [x] **Migrate CNPG clusters from `system` to `standard` + barman-cloud plugin** — done via `ac76d0ea` (#4041, "migrate all clusters to standard-bookworm + plugin-barman-cloud"). Verified 2026-07-20: `plugin-barman-cloud` pod running in `cnpg` ns (deployed via `cluster/apps/system/cloudnative-pg`), and every CNPG cluster live in-cluster (`bookorbdb`, `coderdb`, `giteadb`, `honchodb`, `keycloakdb`, `nextclouddb`, `onlyofficedb`) reports a `standard-bookworm` image. `charts/pgsql-cnpg` wires `objectStore` to the plugin natively. The note above about `honchodb-cnpg` still being on `system-bookworm` was stale — it's `17.6-standard-bookworm` in both git and live.
  - Ref: https://github.com/cloudnative-pg/plugin-barman-cloud

## Infrastructure — Monitoring & Alerting

- [x] **Alert on CNPG `ContinuousArchivingFailing`** — added `CNPGArchivingStalled` and `CNPGBackupFailing` to a new `PrometheusRule`, based on metric names confirmed live against the cluster (not guessed from docs). Applies to all CNPG clusters via the existing per-cluster PodMonitor labels, not just keycloak. Done via `fbe72147` on branch `feat/cnpg-alerting-notifications`.
  - Surfaced 2026-07-20: `identity/keycloakdb-cnpg` had `ContinuousArchivingFailing` (`barman-cloud-wal-archive: exit status 4`) for ~2 days before its PVC actually filled and the cluster crash-looped
  - Only the generic `KubePersistentVolumeFillingUp` alert caught this, and only once disk was already critical — a last-resort signal, not an early one
  - CNPG pods already expose Prometheus metrics on port 9187 (auto-scraped via per-cluster PodMonitor), but no `PrometheusRule` is built on top of them
  - Add a rule alerting when a `Cluster`'s `ContinuousArchiving` condition is `False` for some sustained window (e.g. 30-60m), and ideally one for failed/incomplete `Backup` CRs too
  - Applies to all CNPG clusters, not just keycloak

- [x] **Enable Discord + email notifications for Prometheus alerts** — configured Alertmanager with a Discord webhook receiver/route for `critical`/`warning` alerts (`@here` on critical), webhook URL delivered via a dedicated `ExternalSecret` + `webhook_url_file` rather than a `<secret:...>` token (the token-substitution path is broken for this chart's Secret shape — see design doc). Email/SMTP receiver and botkube re-enablement deferred, not part of this pass. Done via `84994974` + `c850c1f5` on branch `feat/cnpg-alerting-notifications`.
  - Alertmanager itself has zero receivers configured (`cluster/apps/system/prometheus-stack/values.yaml` only sets `global.resolve_timeout`) — alerts fire and sit with nowhere to go
  - Surfaced 2026-07-20: the `KubePersistentVolumeFillingUp` critical alert fired correctly for `identity/keycloakdb-cnpg` ~6h before the outage was noticed, but nobody was notified — QNAP's own out-of-band alert was the first signal
  - Configure Alertmanager receivers/routes directly: a Discord webhook receiver, plus an email/SMTP receiver, at minimum for `severity: critical`
  - Decide whether to also re-enable botkube (and bind its `prometheus` source) as a second channel, or keep notification ownership solely in Alertmanager to avoid duplicate/half-wired paths

- [ ] **Investigate CNPG archiving/backup anomalies found while building the new alerts (2026-07-20)** — `bookorbdb-cnpg` (bookorbit) has failed every scheduled backup for 5+ consecutive days (`rpc error: code = Unknown desc = exit status 1`); `giteadb-cnpg` (gitea) has gone ~21 days without a successful WAL archive despite `archive_timeout: 30min` being live, while CNPG's own `ContinuousArchiving` condition still reports `True` — could be a genuinely idle database (low `archived_count` supports this) or a real stall the condition isn't catching. The new `CNPGArchivingStalled`/`CNPGBackupFailing` alerts (this PR) will fire on both immediately on merge — expected, not a bug.
  - Still open as of 2026-07-20 evening: `bookorbit` remains the one real ongoing failure (last success 07-14, still failing today with the same `InsufficientStorageSpace` error that PR #4622 fixed for its siblings) — needs its own investigation into why it alone hasn't recovered.

- [x] **Fix `CNPGBackupFailing` false positives from stale metric** — the rule's `cnpg_collector_last_available_backup_timestamp` never updates once a `Cluster` is on the barman-cloud plugin backup method (upstream bug: [plugin-barman-cloud#380](https://github.com/cloudnative-pg/plugin-barman-cloud/issues/380)), so the alert stayed firing forever after the first plugin backup failure even when later backups succeeded. Switched to `barman_cloud_cloudnative_pg_io_last_{available,failed}_backup_timestamp` in `cluster/apps/system/prometheus-stack/templates/prometheusrule-cnpg.yaml`. Confirmed this was producing false positives for `honcho`, `identity`, `coder`, and `nextcloud` — all had genuinely healthy backups under the correct metric despite Discord alerts firing on all four. Done via `7364d70a`, pushed directly to `main` (2026-07-20).

## Infrastructure — CNPG Backup Storage (QNAP S3 bloat)

Surfaced 2026-07-20 investigating a QNAP "storage near empty" alert. Total CNPG backup usage was ~210 GiB against <2 GiB of live data per cluster. Full breakdown/numbers are in conversation history from that date; items below are the unimplemented mitigations.

- [x] **Fix coder's malformed `ScheduledBackup` cron** — was a 5-field cron (`"0 2 * * *"`) misparsed as hourly instead of daily. Fixed to `"0 0 2 * * *"` on branch `fix/cnpg-backup-storage-bloat`.

- [x] **Raise `archive_timeout` from 5min on low-traffic CNPG clusters** — set to `30min` as a chart-level default in `charts/pgsql-cnpg/values.yaml` (`postgresql.parameters.archive_timeout`), applied uniformly to all CNPG clusters rather than per-app, on branch `fix/cnpg-backup-storage-bloat`.

- [x] **Enable compression on all CNPG `ObjectStore`s** — `data.compression`/`wal.compression: gzip` added as a chart-level default (merged into each app's `objectStore:` block via `mergeOverwrite` in `charts/pgsql-cnpg/templates/cnpg.yaml`, app-specific values still win if ever overridden), on branch `fix/cnpg-backup-storage-bloat`. Same branch also centralized the repeated `instanceSidecarConfiguration` (AWS checksum env vars) into the chart as a default, removing it from all 10 per-app `values.yaml` files — this was the exact class of repetition bug that caused coder's cron/config to drift in the first place.

- [ ] **Re-evaluate `retentionPolicy: 10d` per app** — deferred until the effect of the above fixes on actual S3 usage is visible (barman-cloud plugin has no incremental/differential backup support today, so this is a straight days-retained tradeoff).

Dropped: deleting orphaned CNPG backup prefixes on QNAP S3 (`daytona`, `firefly`, `harbor`, `home-assistant`, `litellm`) — decided against; those apps may be re-enabled and restored from those backups someday.

## Infrastructure — Logging

- [ ] **No centralized log aggregation exists** — `monitoring` namespace is metrics-only (kube-prometheus-stack + smartctl-exporter), no Loki/Promtail/Fluent Bit/Vector anywhere in the cluster
  - Surfaced while disabling rook-ceph's `logCollector` (PR #4468) to reclaim ~1.3 cores/1.3Gi of idle reservation — without it, Ceph component logs are `kubectl logs`-only (ephemeral, lost on restart/rotation)
  - Accepted as a tradeoff for now; revisit if Ceph log history is ever needed for debugging a real incident
  - If pursued, a lightweight option (e.g. Grafana Loki + Promtail/Alloy) would also benefit every other app in the cluster, not just rook-ceph

## Apps — Chart Upgrades

- [ ] **Jellyfin** — migrate from local custom chart to official `jellyfin/jellyfin` Helm chart
  - Upstream chart: https://github.com/jellyfin/jellyfin-helm/tree/master/charts/jellyfin
  - Current: `cluster/apps/default/jellyfin/` is a hand-rolled chart with no external dep
  - Check if official chart supports Gateway API `route:` natively (would let us drop `templates/httproute.yaml` too)
  - Review if PVC/storage config, LoadBalancer service (`192.168.48.22`), and resource requests map cleanly to new chart values
  - Do after Traefik → Envoy migration Phase 1 is stable
