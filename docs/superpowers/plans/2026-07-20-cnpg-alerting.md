# CNPG Alerting + Alertmanager Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two CNPG Prometheus alerts (stalled WAL archiving, failing backups) and wire Alertmanager to actually deliver `critical`/`warning` alerts to Discord, so failures like the keycloak PVC-fill incident and the bookorbdb backup-failure streak get noticed within the hour instead of days later.

**Architecture:** A new hand-written `PrometheusRule` in `cluster/apps/system/prometheus-stack/templates/` (same pattern as the existing `prometheusrule-smart.yaml`) adds the two CNPG alerts. `alertmanager.config` in the same app's `values.yaml` gains a `discord` receiver and a route matching `severity=~"critical|warning"`. The webhook URL is kept out of `values.yaml` entirely — it's delivered via a new `ExternalSecret` → `Secret` → `alertmanagerSpec.secrets` mount → `webhook_url_file`, avoiding a confirmed-broken alternative (a `<secret:...>` token would get trapped inside a base64-encoded Secret field that the `argocd-secret-replacer` plugin's literal-text substitution can never reach).

**Tech Stack:** Helm (kube-prometheus-stack 87.5.1 / Alertmanager v0.33.1), Prometheus Operator `PrometheusRule` CRD, External Secrets Operator (`ClusterSecretStore bitwarden`), Bitwarden Secrets Manager (`bws` CLI), ArgoCD GitOps sync.

## Global Constraints

- Design source of truth: `docs/superpowers/specs/2026-07-20-cnpg-alerting-design.md` — read it if anything here is ambiguous.
- Metric names (`cnpg_pg_stat_archiver_seconds_since_last_archival`, `cnpg_collector_last_failed_backup_timestamp`, `cnpg_collector_last_available_backup_timestamp`) were confirmed live against the cluster's Prometheus — do not substitute different metric names without re-verifying against `curl http://localhost:9090/api/v1/label/__name__/values` (see `prometheus-portforward-session` skill for the port-forward lifecycle across Bash calls).
- `PrometheusRule` files in this repo use Helm raw-string escaping for Go template syntax, e.g. `{{`{{ $labels.namespace }}`}}` — because they live under `templates/` and are themselves passed through Helm rendering. Copy this pattern exactly; unescaped `{{ }}` will break the Helm render.
- `alertmanager.config.receivers[].discord_configs[].webhook_url` must **never** be set directly with a `<secret:...>` token — use `webhook_url_file` + `alertmanagerSpec.secrets` as designed. See design doc section 2 for why.
- Never commit the real Discord webhook URL to git.
- Branch: `feat/cnpg-alerting-notifications` (already created, design doc already committed on it — do not create a new branch).
- Kubeconfig for any live cluster checks: `talosctl --talosconfig=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig kubeconfig --nodes 192.168.48.2 --force $KUBECONFIG`.

---

## Task 1: CNPG PrometheusRule

**Files:**
- Create: `cluster/apps/system/prometheus-stack/templates/prometheusrule-cnpg.yaml`

**Interfaces:**
- Produces: two Prometheus alert names, `CNPGArchivingStalled` (fires at `severity: warning` and separately at `severity: critical`) and `CNPGBackupFailing` (`severity: warning`). Task 3's Alertmanager route matches on `severity=~"critical|warning"`, so both alert names route to Discord automatically — no additional wiring needed between this task and Task 3.

- [ ] **Step 1: Write the PrometheusRule file**

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cnpg-alerts
  namespace: monitoring
  labels:
    app: kube-prometheus-stack
    release: prometheus-stack
spec:
  groups:
    - name: cnpg.archiving
      interval: 5m
      rules:
        - alert: CNPGArchivingStalled
          expr: max by (namespace, job) (cnpg_pg_stat_archiver_seconds_since_last_archival) > 3600
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: 'CNPG WAL archiving stalled on {{`{{ $labels.namespace }}`}}'
            description: 'No successful WAL archive in {{`{{ $labels.namespace }}`}} for over 1h ({{`{{ $value }}`}}s) — check barman-cloud-wal-archive logs.'
        - alert: CNPGArchivingStalled
          expr: max by (namespace, job) (cnpg_pg_stat_archiver_seconds_since_last_archival) > 21600
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: 'CNPG WAL archiving critically stalled on {{`{{ $labels.namespace }}`}}'
            description: 'No successful WAL archive in {{`{{ $labels.namespace }}`}} for over 6h ({{`{{ $value }}`}}s) — PVC will eventually fill. Check barman-cloud-wal-archive logs.'
    - name: cnpg.backups
      interval: 5m
      rules:
        - alert: CNPGBackupFailing
          expr: max by (namespace, job) (cnpg_collector_last_failed_backup_timestamp) > max by (namespace, job) (cnpg_collector_last_available_backup_timestamp)
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: 'CNPG backups failing on {{`{{ $labels.namespace }}`}}'
            description: 'The most recent backup attempt in {{`{{ $labels.namespace }}`}} failed and is more recent than the last successful backup.'
```

- [ ] **Step 2: Render and verify the rule appears correctly**

```sh
cd cluster/apps/system/prometheus-stack
helm template prometheus-stack . -f values.yaml | grep -A3 "name: cnpg-alerts"
```

Expected: a `PrometheusRule` block with `metadata.name: cnpg-alerts`, `namespace: monitoring`, and the `release: prometheus-stack` label. If nothing prints, the file wasn't picked up by Helm — check it's directly under `templates/` (not a subdirectory) and has valid YAML (`---` document start, correct indentation).

- [ ] **Step 3: Validate the two PromQL expressions against live Prometheus**

```sh
export KUBECONFIG=/tmp/claude-1000/-workspaces-home-ops/84d4501d-bf31-4bdf-a18f-169a226d4976/scratchpad/kubeconfig
nohup kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 > /tmp/claude-1000/-workspaces-home-ops/84d4501d-bf31-4bdf-a18f-169a226d4976/scratchpad/pf.log 2>&1 &
disown
sleep 3
curl -s "http://localhost:9090/api/v1/query" --data-urlencode "query=max by (namespace, job) (cnpg_pg_stat_archiver_seconds_since_last_archival) > 3600"
curl -s "http://localhost:9090/api/v1/query" --data-urlencode "query=max by (namespace, job) (cnpg_collector_last_failed_backup_timestamp) > max by (namespace, job) (cnpg_collector_last_available_backup_timestamp)"
pkill -f "port-forward.*prometheus"; true
```

Expected: both return `"status": "success"` (HTTP 200, no PromQL parse error). At time of design, the first query matched `gitea` and `bookorbit` (long-stalled archiving — real, pre-existing conditions, not a bug in the rule) and the second matched `bookorbit` (confirmed failing backup streak). If the scratchpad path above no longer exists (new session), substitute any writable path and regenerate the kubeconfig first via the Global Constraints command.

- [ ] **Step 4: Commit**

```sh
git add cluster/apps/system/prometheus-stack/templates/prometheusrule-cnpg.yaml
git commit -m "feat(prometheus-stack): add CNPG archiving/backup PrometheusRule"
```

---

## Task 2: Discord webhook secret

**Files:**
- Create: `cluster/apps/system/prometheus-stack/templates/alertmanager-discord-webhook-externalsecret.yaml`

**Interfaces:**
- Consumes: a Discord webhook URL (obtained from the user in Step 1 of this task — cannot be generated programmatically, requires Discord channel UI access).
- Produces: a K8s `Secret` named `alertmanager-discord-webhook` in the `monitoring` namespace with key `url`, which Task 3's `alertmanagerSpec.secrets: [alertmanager-discord-webhook]` mounts at `/etc/alertmanager/secrets/alertmanager-discord-webhook/url`.

- [ ] **Step 1: Get the Discord webhook URL from the user**

This cannot be automated — stop and ask the user to create a webhook in their target Discord channel (Discord: Channel Settings → Integrations → Webhooks → New Webhook → Copy Webhook URL) and paste the URL. Do not proceed until you have it. Do not echo the full URL back in any commit message, PR description, or log that gets persisted to a shared/visible location.

- [ ] **Step 2: Store it in Bitwarden Secrets Manager**

```sh
bws secret create ALERTMANAGER_DISCORD_WEBHOOK '<the webhook URL from Step 1>' 422f340a-6eb8-4a4f-90d1-b3fe00d00d76 -o json
```

Expected: JSON output including an `"id"` field (a UUID) — this is the new secret's ID, needed in Step 3. `422f340a-6eb8-4a4f-90d1-b3fe00d00d76` is the `cluster` Bitwarden project (confirmed via `bws project list` — same project that holds `discord_botid`/`discord_token`/etc.). Do not print or log the webhook URL itself again after this step; only the returned `id` is needed going forward.

- [ ] **Step 3: Write the ExternalSecret**

Replace `<SECRET_ID_FROM_STEP_2>` with the real UUID from Step 2's output:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: alertmanager-discord-webhook
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: alertmanager-discord-webhook
    creationPolicy: Owner
  data:
    - secretKey: url
      remoteRef:
        key: "<SECRET_ID_FROM_STEP_2>" #gitleaks:allow #ALERTMANAGER_DISCORD_WEBHOOK
```

No `metadata.namespace` field — matches the existing `harbor-oidc-secret`/`headlamp-oidc` `ExternalSecret`s in this repo, which rely on the ArgoCD Application's destination namespace (`monitoring` here, set in `app-config.yaml`).

- [ ] **Step 4: Render and verify**

```sh
cd cluster/apps/system/prometheus-stack
helm template prometheus-stack . -f values.yaml | grep -A12 "name: alertmanager-discord-webhook"
```

Expected: an `ExternalSecret` block with `secretStoreRef.name: bitwarden`, `target.name: alertmanager-discord-webhook`, and a `data[0].remoteRef.key` containing the real UUID (not the placeholder text) — confirming the substitution in Step 3 was actually made.

- [ ] **Step 5: Commit**

```sh
git add cluster/apps/system/prometheus-stack/templates/alertmanager-discord-webhook-externalsecret.yaml
git commit -m "feat(prometheus-stack): add ExternalSecret for Alertmanager Discord webhook"
```

The secret UUID in this commit is a Bitwarden item reference, not the credential itself — safe to commit (matches every other `remoteRef.key` in the repo). Gitleaks will still scan it; the `#gitleaks:allow` comment suppresses any false-positive UUID-looks-like-a-secret flag, matching existing entries.

---

## Task 3: Alertmanager receiver + route

**Files:**
- Modify: `cluster/apps/system/prometheus-stack/values.yaml` (the `alertmanager:` block, currently only `config.global.resolve_timeout` and `alertmanagerSpec.storage`)

**Interfaces:**
- Consumes: `alertmanager-discord-webhook` Secret from Task 2 (must exist for `alertmanagerSpec.secrets` to mount successfully at deploy time — safe to write this task's YAML before Task 2's PR merges, since both land in the same PR).
- Consumes: alert names `CNPGArchivingStalled`, `CNPGBackupFailing` from Task 1 only implicitly (via the `severity` label they set, not by name — this task's route has no CNPG-specific logic, it's generic severity-based routing that also covers the existing `smart-disk-health` alerts).

- [ ] **Step 1: Edit `values.yaml`**

Find the existing `alertmanager:` block:

```yaml
  alertmanager:
    config:
      global:
        resolve_timeout: 5m
    alertmanagerSpec:
      storage:
        volumeClaimTemplate:
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 25Gi
```

Replace it with:

```yaml
  alertmanager:
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
    alertmanagerSpec:
      secrets:
        - alertmanager-discord-webhook
      storage:
        volumeClaimTemplate:
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 25Gi
```

Note: the `discord_configs` template fields (`title`, `message`) use unescaped `{{ }}` deliberately — this block lives inside a YAML **string value** passed through to Alertmanager's own Go templating at alert-render time, not through Helm's templating (Helm only templates `.yaml`/`.tpl` files under `templates/`, and `values.yaml` is not one — its contents are passed through as literal data). Do not add the triple-backtick raw-string escaping used in `prometheusrule-cnpg.yaml`; that pattern is specific to files under `templates/`.

- [ ] **Step 2: Render and verify the discord receiver + secrets mount**

```sh
cd cluster/apps/system/prometheus-stack
helm template prometheus-stack . -f values.yaml > /tmp/claude-1000/-workspaces-home-ops/84d4501d-bf31-4bdf-a18f-169a226d4976/scratchpad/rendered.yaml
grep -A3 "secrets:" /tmp/claude-1000/-workspaces-home-ops/84d4501d-bf31-4bdf-a18f-169a226d4976/scratchpad/rendered.yaml | grep -A2 "alertmanager-discord-webhook"
python3 -c "
import re, base64
t = open('/tmp/claude-1000/-workspaces-home-ops/84d4501d-bf31-4bdf-a18f-169a226d4976/scratchpad/rendered.yaml').read()
m = re.search(r'alertmanager\.yaml: \"([^\"]+)\"', t)
print(base64.b64decode(m.group(1)).decode())
"
```

Expected: the first command shows `alertmanager-discord-webhook` under the Alertmanager CR's `spec.secrets`. The decoded config (second command) shows a `discord_configs` receiver with `webhook_url_file: /etc/alertmanager/secrets/alertmanager-discord-webhook/url` (not a literal webhook URL, not a `<secret:...>` token) and a `route.routes` entry matching `severity=~"critical|warning"` → `receiver: discord`.

- [ ] **Step 3: `task lint:all`**

```sh
task lint:all
```

Expected: passes (yamllint, helmlint, prettier). Fix any reported formatting issues (typically indentation or trailing whitespace) before continuing.

- [ ] **Step 4: Commit**

```sh
git add cluster/apps/system/prometheus-stack/values.yaml
git commit -m "feat(prometheus-stack): route critical/warning alerts to Discord"
```

---

## Task 4: TODO.md update and PR

**Files:**
- Modify: `.plans/TODO.md`

**Interfaces:** none (documentation-only task).

- [ ] **Step 1: Check off both completed items and add the deferred-investigation note**

In `.plans/TODO.md` under `## Infrastructure — Monitoring & Alerting`, change both `- [ ]` items to `- [x]` and append a short note to each about what was actually implemented (mirroring the style already used for the completed CNPG/backup-storage items above them). Also add a new item noting the two live findings surfaced during this work, for separate follow-up:

```markdown
- [ ] **Investigate CNPG archiving/backup anomalies found while building the new alerts (2026-07-20)** — `bookorbdb-cnpg` (bookorbit) has failed every scheduled backup for 5+ consecutive days (`rpc error: code = Unknown desc = exit status 1`); `giteadb-cnpg` (gitea) has gone ~21 days without a successful WAL archive despite `archive_timeout: 30min` being live, while CNPG's own `ContinuousArchiving` condition still reports `True` — could be a genuinely idle database (low `archived_count` supports this) or a real stall the condition isn't catching. The new `CNPGArchivingStalled`/`CNPGBackupFailing` alerts (this PR) will fire on both immediately on merge — expected, not a bug.
```

- [ ] **Step 2: Push and open the PR**

```sh
git push -u origin feat/cnpg-alerting-notifications
gh pr create --title "feat(prometheus-stack): CNPG archiving/backup alerts + Discord notifications" --body "$(cat <<'EOF'
## Summary
- Add `CNPGArchivingStalled` and `CNPGBackupFailing` PrometheusRule alerts, based on metric names confirmed live against the cluster (not guessed from docs)
- Configure Alertmanager to route `critical`/`warning` alerts to a Discord webhook, with `@here` on critical
- Webhook URL delivered via ExternalSecret + `webhook_url_file`, not a `<secret:...>` token (confirmed the token-substitution path is broken for this specific chart's Secret shape — see design doc)

Design: `docs/superpowers/specs/2026-07-20-cnpg-alerting-design.md`
Plan: `docs/superpowers/plans/2026-07-20-cnpg-alerting.md`

## Test plan
- [x] `helm template` verified for all three new/changed files
- [x] Both new PromQL expressions validated against live Prometheus (see Task 1 Step 3)
- [x] `task lint:all` passes
- [ ] Post-merge: fire a synthetic test alert via `amtool` and confirm it lands in Discord (see plan's Post-Merge Verification section — requires user go-ahead, not done as part of this PR)

## Note
Merging this will immediately fire `critical` Discord alerts for `bookorbit` and `gitea` — both are real, pre-existing conditions (see TODO.md follow-up item added in this PR), not false positives from the new rule.
EOF
)"
```

---

## Post-Merge Verification (manual — do not run without explicit user go-ahead)

This step sends a real message to the configured Discord channel and depends on ArgoCD having already synced the merged PR (automatic — `prometheus-stack`'s `app-config.yaml` has `syncPolicy.selfHeal: true`). Do not run it as part of the PR; run it afterward, and only after confirming with the user, since it both touches the live cluster and posts a visible Discord message.

- [ ] **Confirm the Secret synced and Alertmanager picked it up**

```sh
export KUBECONFIG=/tmp/claude-1000/-workspaces-home-ops/84d4501d-bf31-4bdf-a18f-169a226d4976/scratchpad/kubeconfig
kubectl get secret -n monitoring alertmanager-discord-webhook
kubectl get pods -n monitoring -l app.kubernetes.io/name=alertmanager
```

Expected: the Secret exists, and the Alertmanager pod (`alertmanager-prometheus-stack-kube-prom-alertmanager-0`) is `2/2 Running` with no recent restarts (a bad config causes a crash loop on the `alertmanager` container specifically).

- [ ] **Fire a synthetic test alert**

```sh
kubectl exec -n monitoring alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager -- \
  amtool alert add alertname="TestAlert" severity="warning" --annotation=summary="Test alert from CNPG alerting rollout" --alertmanager.url=http://localhost:9093
```

Expected: within ~30s (the configured `group_wait`), a message reading "Test alert from CNPG alerting rollout" appears in the target Discord channel. If nothing arrives, check `kubectl logs -n monitoring alertmanager-prometheus-stack-kube-prom-alertmanager-0 -c alertmanager` for delivery errors (most likely cause: webhook URL was mistyped in Task 2 Step 1, or the Discord webhook was deleted/regenerated since).

- [ ] **Confirm the CNPG alerts are actually active**

```sh
curl -s "http://localhost:9090/api/v1/query" --data-urlencode 'query=ALERTS{alertname=~"CNPGArchivingStalled|CNPGBackupFailing"}' | python3 -m json.tool
```

(Requires the Prometheus port-forward from Task 1 Step 3 — restart it if closed.) Expected: entries for `bookorbit` and `gitea` per the known pre-existing conditions (see Task 4's TODO.md note) — confirms the rule is loaded and evaluating, not just rendered.
