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
