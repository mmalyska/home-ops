# TODO

General backlog items not tied to a specific migration plan.

---

## Infrastructure — CNPG

- [ ] **Migrate CNPG clusters from `system` to `standard` + barman-cloud plugin**
  - `system` images are deprecated upstream (cloudnative-pg/postgres-containers)
  - Affected: `honchodb-cnpg` (currently `17.6-system-bookworm` as short-term fix)
  - Long-term path: deploy [plugin-barman-cloud](https://github.com/cloudnative-pg/plugin-barman-cloud) as a system app, then switch all CNPG clusters to `standard-bookworm` images
  - Other clusters (`litellm`, `gitea`, `keycloak`) use the deprecated plain `17.X` rolling tags — should also migrate to `standard` + plugin
  - Ref: https://github.com/cloudnative-pg/plugin-barman-cloud

## Infrastructure — Monitoring & Alerting

- [ ] **Alert on CNPG `ContinuousArchivingFailing`**
  - Surfaced 2026-07-20: `identity/keycloakdb-cnpg` had `ContinuousArchivingFailing` (`barman-cloud-wal-archive: exit status 4`) for ~2 days before its PVC actually filled and the cluster crash-looped
  - Only the generic `KubePersistentVolumeFillingUp` alert caught this, and only once disk was already critical — a last-resort signal, not an early one
  - CNPG pods already expose Prometheus metrics on port 9187 (auto-scraped via per-cluster PodMonitor), but no `PrometheusRule` is built on top of them
  - Add a rule alerting when a `Cluster`'s `ContinuousArchiving` condition is `False` for some sustained window (e.g. 30-60m), and ideally one for failed/incomplete `Backup` CRs too
  - Applies to all CNPG clusters, not just keycloak

- [ ] **Enable Discord + email notifications for Prometheus alerts** — `botkube` is `enabled: "false"` in `cluster/apps/default/botkube/app-config.yaml`, so its half-wired Discord integration (a `prometheus` source plugin exists in `values.yaml` but was never bound to the channel's `sources` list) isn't even running
  - Alertmanager itself has zero receivers configured (`cluster/apps/system/prometheus-stack/values.yaml` only sets `global.resolve_timeout`) — alerts fire and sit with nowhere to go
  - Surfaced 2026-07-20: the `KubePersistentVolumeFillingUp` critical alert fired correctly for `identity/keycloakdb-cnpg` ~6h before the outage was noticed, but nobody was notified — QNAP's own out-of-band alert was the first signal
  - Configure Alertmanager receivers/routes directly: a Discord webhook receiver, plus an email/SMTP receiver, at minimum for `severity: critical`
  - Decide whether to also re-enable botkube (and bind its `prometheus` source) as a second channel, or keep notification ownership solely in Alertmanager to avoid duplicate/half-wired paths

## Infrastructure — CNPG Backup Storage (QNAP S3 bloat)

Surfaced 2026-07-20 investigating a QNAP "storage near empty" alert. Total CNPG backup usage was ~210 GiB against <2 GiB of live data per cluster. Full breakdown/numbers are in conversation history from that date; items below are the unimplemented mitigations.

- [ ] **Fix coder's malformed `ScheduledBackup` cron** — `cluster/apps/ai/coder/values.yaml:78` sets `schedule: "0 2 * * *"` (5-field), while every other CNPG app uses the required 6-field format (`sec min hour day month dow`, e.g. `"5 0 0 * * *"`). The plugin's cron parser misinterprets the missing field and runs backups **every hour** instead of daily — confirmed live (`ScheduledBackup.status.nextScheduleTime` was exactly 1h after `lastScheduleTime`). Over 10 days this produced ~240 base backups instead of 10 and is the single largest contributor to coder's 74.7 GiB S3 footprint (vs. 814 MB live DB). Fix: `"0 0 2 * * *"`.

- [ ] **Raise `archive_timeout` from 5min on low-traffic CNPG clusters** — every `Cluster` forces a full 16 MB WAL segment to S3 every 5 minutes regardless of actual write activity (confirmed live in `nextclouddb-cnpg`'s barman-cloud sidecar logs — `Archived WAL file` firing every ~5min with near-zero app usage). At 288 segments/day × 10-day retention this alone accounts for ~45 GiB of nearly-empty WAL each for `honcho` and `nextcloud` (both <1 GiB live data). Raise to 15-30min for apps without a tight RPO; 2-instance streaming replication already covers primary durability.

- [ ] **Enable compression on all CNPG `ObjectStore`s** — `data.compression` and `wal.compression` are unset on every `ObjectStore` in the cluster (barman-cloud plugin supports gzip/bzip2/snappy). Free additional reduction stacked on top of the two fixes above.

- [ ] **Delete orphaned CNPG backup prefixes on QNAP S3** — `s3://k8s-at-home-backup/cnpg/{daytona,firefly,harbor,home-assistant,litellm}/` (~2.75 GiB total) have no corresponding active `Cluster` resource anywhere in the cluster — leftover from decommissioned/migrated apps. Confirm each app is genuinely gone (not just moved off CNPG) before deleting.

- [ ] **Re-evaluate `retentionPolicy: 10d` per app** — once the above land, decide whether 10 days of daily full backups (barman-cloud plugin has no incremental/differential support today) is still the right default everywhere, or whether lower-value apps can go shorter.

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
