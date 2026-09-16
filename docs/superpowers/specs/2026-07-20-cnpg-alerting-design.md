# CNPG Alerting + Alertmanager Notifications — Design

## Context

Two related backlog items from `.plans/TODO.md` under "Infrastructure — Monitoring & Alerting":

1. **No alert on CNPG `ContinuousArchivingFailing`.** Surfaced 2026-07-20:
   `identity/keycloakdb-cnpg` had continuous archiving failing
   (`barman-cloud-wal-archive: exit status 4`) for ~2 days before its PVC
   actually filled and the cluster crash-looped. Only the generic
   `KubePersistentVolumeFillingUp` alert caught it, and only once disk was
   already critical.
2. **Alertmanager has zero receivers configured.** `KubePersistentVolumeFillingUp`
   fired correctly ~6h before the keycloak outage was noticed, but nobody was
   notified — a QNAP out-of-band alert was the first signal. `botkube` is
   `enabled: "false"` with a half-wired Discord `prometheus` source that was
   never bound to the channel.

These are combined into one design because a CNPG-specific alert is useless
without somewhere for it to go.

**Additional finding during design (2026-07-20):** live Prometheus query
confirmed `bookorbdb-cnpg` has failed every scheduled backup for at least 5
consecutive days (2026-07-16 through today, `rpc error: code = Unknown desc =
exit status 1`), currently undetected. This validates the `CNPGBackupFailing`
alert design below and is tracked as a separate immediate follow-up, not part
of this implementation.

## Goals

- Alert early when a CNPG cluster's WAL archiving stalls, before the PVC
  fills (the keycloak failure mode).
- Alert when a CNPG cluster's most recent backup attempt failed (the
  bookorbdb failure mode).
- Get `critical`/`warning` severity Prometheus alerts routed to a Discord
  channel, with `@here` on critical, so alerts are actually seen.

## Non-goals

- Email/SMTP receiver — no SMTP relay credentials exist in the cluster; explicitly deferred.
- Re-enabling `botkube` as a second notification path — Alertmanager owns delivery directly instead, avoiding a second always-on service and a second routing path to maintain.
- Exposing `Cluster.status.conditions` (e.g. `ContinuousArchiving`) as a metric via kube-state-metrics `customresourcestate` config — not currently configured in this cluster; would be a separate, larger change. The exporter-metric approach below gives an earlier and more precise signal anyway.
- Investigating/fixing `bookorbdb-cnpg`'s live failing backups — tracked separately.

## Design

### 1. CNPG PrometheusRule

New file: `cluster/apps/system/prometheus-stack/templates/prometheusrule-cnpg.yaml`,
following the existing hand-written pattern in `templates/prometheusrule-smart.yaml`
(`monitoring.coreos.com/v1` `PrometheusRule`, labels `app: kube-prometheus-stack`,
`release: prometheus-stack` so the Prometheus Operator's rule selector picks it up —
confirmed via `ruleSelectorNilUsesHelmValues: false` in `values.yaml`).

Metric names below were confirmed live against the cluster's Prometheus
(CNPG's built-in postgres-exporter on port 9187, auto-scraped via per-cluster
`PodMonitor`) — not guessed from CNPG docs.

**`CNPGArchivingStalled`**

```yaml
- alert: CNPGArchivingStalled
  expr: max by (namespace, job) (cnpg_pg_stat_archiver_seconds_since_last_archival) > 3600
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: 'CNPG WAL archiving stalled on {{ $labels.namespace }}'
    description: 'No successful WAL archive in {{ $labels.namespace }} for over 1h — check barman-cloud-wal-archive logs.'
- alert: CNPGArchivingStalled
  expr: max by (namespace, job) (cnpg_pg_stat_archiver_seconds_since_last_archival) > 21600
  for: 10m
  labels:
    severity: critical
  annotations:
    summary: 'CNPG WAL archiving critically stalled on {{ $labels.namespace }}'
    description: 'No successful WAL archive in {{ $labels.namespace }} for over 6h — PVC will eventually fill. Check barman-cloud-wal-archive logs.'
```

- `cnpg_pg_stat_archiver_seconds_since_last_archival` is only meaningfully
  reported by the primary instance (standbys report `0`/stale); `max by
  (namespace, job)` collapses to one series per cluster (`job` label is
  `<namespace>/<cluster>-cnpg`, shared across both instances' pods).
- Chart-wide `postgresql.parameters.archive_timeout` is `30min`
  (`charts/pgsql-cnpg/values.yaml`), so this metric cycles up to ~1800s under
  normal idle operation. Thresholds are set well above that (1h warning, 6h
  critical) specifically to avoid flapping on that idle cycle.
- The keycloak incident ran ~2 days before the PVC actually filled, so even
  the 6h critical threshold is an early, high-confidence signal with no
  observed false-positive risk against current live data (all six clusters
  queried sit well under 1h as of this writing, except keycloak itself which
  is now `-1`/reset after the recent fix).

**`CNPGBackupFailing`**

```yaml
- alert: CNPGBackupFailing
  expr: max by (namespace, job) (cnpg_collector_last_failed_backup_timestamp) > max by (namespace, job) (cnpg_collector_last_available_backup_timestamp)
  for: 30m
  labels:
    severity: warning
  annotations:
    summary: 'CNPG backups failing on {{ $labels.namespace }}'
    description: 'The most recent backup attempt in {{ $labels.namespace }} failed and is more recent than the last successful backup.'
```

- Fires when the most recent backup *attempt* is a failure newer than the
  last success, and stays firing until a success occurs — correct semantics
  for "backups are currently in a failing streak," not just "a failure
  happened once."
- Confirmed against live data: `bookorbdb-cnpg` currently satisfies this
  expression (5 consecutive daily `failed` backups, `last_available_backup_timestamp
  = 0`, i.e. no success ever recorded).
- `for: 30m` avoids alerting on a single transient failure that's
  immediately retried; once true, the condition persists until the next
  scheduled backup succeeds (typically ~24h), so this isn't a
  window that risks missing the signal.

### 2. Alertmanager Discord receiver + route

**Correction made during implementation planning (2026-07-20):** the
original draft of this section used a `<secret:discord_alertmanager_webhook>`
token directly in `alertmanager.config.receivers[].discord_configs[].webhook_url`,
following the `cluster-secrets` pattern botkube uses. This was tested against
a real render and found broken: unlike botkube's chart (which puts secrets in
a plain `stringData` block), kube-prometheus-stack's `alertmanager.config`
gets marshalled into **base64-encoded** `data.alertmanager.yaml` inside a
chart-managed Secret. The `argocd-secret-replacer` CMP plugin does literal
text substitution on the rendered manifest stream (confirmed via
`docs/superpowers/plans/2026-07-08-dragonfly-operator.md`'s prior encounter
with the same plugin missing a `urlquery`-mangled token) — a token trapped
inside base64 can never match. The corrected design below avoids the problem
entirely by keeping the webhook URL out of `alertmanager.config` altogether.

Added to `alertmanager.config` in `cluster/apps/system/prometheus-stack/values.yaml`
(currently only sets `global.resolve_timeout`):

```yaml
alertmanager:
  alertmanagerSpec:
    secrets:
      - alertmanager-discord-webhook
  config:
    global:
      resolve_timeout: 5m
    route:
      routes:
        - matchers: ['severity=~"critical|warning"']
          receiver: discord
    receivers:
      - name: discord
        discord_configs:
          - webhook_url_file: /etc/alertmanager/secrets/alertmanager-discord-webhook/url
            title: '{{ .CommonAnnotations.summary }}'
            message: |
              {{ if eq .CommonLabels.severity "critical" }}@here {{ end }}{{ .CommonAnnotations.description }}
```

- `critical` and `warning` both route to Discord (per decision below);
  `@here` mention is added only for `critical` via the message template
  conditional — no extra secret/role-ID plumbing needed.
- New Discord **channel webhook** (Discord's native webhook mechanism,
  distinct from botkube's bot-token/bot-ID integration — a new webhook must
  be created in the target Discord channel's settings).
- The webhook URL itself never enters `values.yaml` or any `<secret:...>`
  token. Instead: a new `ExternalSecret` (`cluster/apps/system/prometheus-stack/templates/alertmanager-discord-webhook-externalsecret.yaml`)
  pulls a new Bitwarden Secrets Manager item into a plain K8s `Secret` named
  `alertmanager-discord-webhook` with key `url` — the standard per-app
  `ExternalSecret` + `ClusterSecretStore bitwarden` mechanism, matching
  `harbor-oidc-secret`/`headlamp-oidc` precedent, and the mechanism CLAUDE.md
  already prescribes for tokens that land in `Secret data/stringData`.
  `alertmanagerSpec.secrets: [alertmanager-discord-webhook]` (Prometheus
  Operator field, mounts arbitrary named Secrets into the Alertmanager pod at
  `/etc/alertmanager/secrets/<name>/`) makes that Secret's `url` key
  available to Alertmanager as a file, which `webhook_url_file` reads.
- `cluster/apps/system/prometheus-stack/app-config.yaml` already has
  `SECRET_PROVIDER: cluster-secrets` set — no longer strictly required for
  this feature since no `<secret:...>` token is used here, but left as-is
  since other values in the file may still depend on it.

### 3. Verification plan

- `helm template prometheus-stack . -f values.yaml` before committing, to
  confirm the rendered `PrometheusRule` and the Alertmanager config Secret
  both render as expected (no broken Go templating in the Discord message).
- After deploy, fire a synthetic test alert via `amtool alert add` (through
  `kubectl exec` into the alertmanager pod, or via a port-forward) to confirm
  the Discord message actually arrives — not just that the YAML is valid.
- Spot-check the two new `PrometheusRule` alerts against current live metric
  values (already done during design — see confirmed values above) to make
  sure they don't fire immediately on merge for any existing healthy
  cluster.

## Open follow-ups (not in this implementation)

- Investigate `bookorbdb-cnpg`'s live failing backup streak (separate task).
- Email/SMTP receiver, if Discord proves insufficient.
- Re-enable botkube as a second channel, if ever desired.
- Expose CRD `status.conditions` via kube-state-metrics `customresourcestate`,
  if a condition-based (rather than metric-based) alert is ever needed for
  other CRDs too.
