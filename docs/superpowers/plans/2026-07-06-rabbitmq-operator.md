# RabbitMQ Operator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the RabbitMQ Cluster Operator, build a reusable `rabbitmq-cluster` chart mirroring `charts/pgsql-cnpg/`, and migrate Home Assistant off VerneMQ onto a RabbitMQ instance with the MQTT plugin.

**Architecture:** A Kustomize-based system app installs the official `rabbitmq/cluster-operator` release manifest (CRD + controller, no Bitnami). A new leaf chart `charts/rabbitmq-cluster/` templates a single `RabbitmqCluster` CR (+ optional `ServiceMonitor`) per consuming app, values-driven like `pgsql-cnpg`. A new standalone app `cluster/apps/home-automation/rabbitmq/` depends on that chart with the `rabbitmq_mqtt` plugin enabled and a definitions-import secret providing fixed `admin`/`home_assistant` users (same mechanism VerneMQ's own `templates/external-secret.yaml` already uses). Home Assistant is repointed at it, then VerneMQ is deleted.

**Tech Stack:** Helm, Kustomize, ArgoCD ApplicationSet, RabbitMQ Cluster Operator v2.22.1 (`rabbitmq.com/v1beta1` `RabbitmqCluster` CRD), External Secrets Operator + Bitwarden `ClusterSecretStore`, Prometheus Operator (`ServiceMonitor` CRD).

## Status: Complete

All 5 tasks shipped, merged, and live-verified. VerneMQ and its data are fully gone from the cluster.

**Note on VerneMQ's final removal — this was not auto-pruning, and won't be for future app removals either:** merging PR #4456 (deleting `cluster/apps/home-automation/vernemq/`) did *not* trigger ArgoCD to remove the `vernemq` Application or its resources, even after a day. Root cause: every ApplicationSet in this repo (`appset-system`, `appset-default`, `appset-core`, `appset-ai`, `appset-home-automation`, `appset-games`) is configured with `syncPolicy.applicationsSync: create-update` — deliberately **not** `create-update-delete`. This means deleting an app's directory from git will never auto-delete its ArgoCD `Application` object; the Application is left behind indefinitely reporting `ComparisonError: app path does not exist`. **This is repo-wide, deliberate behavior, not a bug** — removing an app requires an explicit manual step. What that looked like here, with the user's explicit confirmation for each step (this mutates live cluster state, so it always needs sign-off):
1. `kubectl delete application vernemq -n argocd` — the `resources-finalizer.argocd.argoproj.io` finalizer cascade-deleted the StatefulSet, both pods, and both Services.
2. This did **not** touch the two `data-vernemq-{0,1}` PVCs (5Gi each, `ceph-filesystem`) — PVCs created via a StatefulSet's `volumeClaimTemplates` are provisioned by the StatefulSet controller at runtime, not applied directly by ArgoCD from the git manifest, so they're never part of what ArgoCD cascade-deletes.
3. `kubectl delete pvc data-vernemq-0 data-vernemq-1 -n ha-vernemq` — explicit, separate, irreversible step to reclaim the storage, done only after user confirmation.

**Takeaway for future app-removal plans in this repo:** deleting the app directory from git is necessary but not sufficient. The plan must also call for (a) `kubectl delete application <name> -n argocd` after the PR merges, and (b) a separate explicit check/decision on any StatefulSet-managed PVCs left behind, since neither is automatic here.

Summary of what actually happened, since it diverged from a single-branch flow:

| Task | Outcome |
|------|---------|
| 1 | Merged as part of PR [#4452](https://github.com/mmalyska/home-ops/pull/4452) (commit `0673fd81`) |
| 2 | Merged as part of PR [#4452](https://github.com/mmalyska/home-ops/pull/4452) (commit `1eace169`) |
| 3 | Merged as PR [#4452](https://github.com/mmalyska/home-ops/pull/4452) → `b6e44f8b`. Live verification during rollout surfaced 3 issues (see "Deviations" below) fixed with two follow-up commits pushed directly to `main`: `6dfc2f03` (resource requests/limits) and `1c129f35` (missing `vhosts` in definitions import). |
| 4 | PR [#4455](https://github.com/mmalyska/home-ops/pull/4455), merged. Branch `feat/rabbitmq-cutover-home-assistant` off `main` (see below for why). |
| 5 | PR [#4456](https://github.com/mmalyska/home-ops/pull/4456), merged. Branch `feat/remove-vernemq` off `main`. |

**Deviations from this plan, discovered during execution:**

1. **Branching:** the plan assumed all 5 tasks would land on one branch (`feat/rabbitmq-operator`) as one PR. In practice Task 3's PR (#4452) was merged before Tasks 4/5 started (per the plan's own stop-gates, which require live verification between tasks), so `feat/rabbitmq-operator` no longer existed to keep building on. Tasks 4 and 5 each got their own short-lived branch off `main` instead.
2. **Pre-existing, unrelated bug found during Task 3 live verification:** `cluster/apps/home-automation/home-assistant/values.yaml` pinned `argocd.argoproj.io/sync-wave: "-1"` on the CNPG `Cluster` only (not the `ObjectStore`), which — combined with the `barman-cloud` plugin's pre-reconcile hook blocking until its `ObjectStore` exists — created a permanent sync deadlock: ArgoCD wouldn't sync wave `0` (containing the `ObjectStore`) until wave `-1` (the `Cluster`) reported healthy, and the `Cluster` could never report healthy without the `ObjectStore`. This predates the RabbitMQ branch entirely (added 2026-06-02) and is unrelated to it — the user fixed it manually by removing the annotation, plus a second unrelated typo (`home-assistant-secrets` → `home-assistant-secret`) and an incorrect `bootstrap.recovery` block added while debugging (reverted — there was no existing backup to recover from; this is a brand-new Home Assistant instance).
3. **RabbitMQ pod wouldn't schedule:** `charts/rabbitmq-cluster`'s `resources: {}` default let the operator apply its own default (`1 CPU` / `2Gi`), which didn't fit any of the 3 amd64 nodes at the time. Fixed in `cluster/apps/home-automation/rabbitmq/values.yaml` (commit `6dfc2f03`) with an explicit smaller request (`250m`/`512Mi`), sized similarly to VerneMQ's old footprint.
4. **RabbitMQ pod crash-looped on boot:** the Task 3 `definitions.json` (`cluster/apps/home-automation/rabbitmq/templates/external-secret.yaml`) declared `users` and `permissions` for vhost `/` but never declared the vhost itself, so RabbitMQ's definitions-import failed with `Please create virtual host "/" prior to importing definitions`. Fixed (commit `1c129f35`) by adding an explicit `"vhosts": [{"name": "/"}]` block.
5. **Task 4's original test-plan checkboxes didn't apply as written:** live inspection during Task 4 verification found `home-assistant-config`'s PVC and the CNPG recorder database were both freshly created the same day (confirmed by the user: this is a new Home Assistant instance, not data loss). There was no pre-existing `mqtt` integration config entry to "reconnect" — the cutover env var is correct, but the "MQTT integration shows connected" / "entities reappear" checks don't apply until the user configures the MQTT integration against the new broker from scratch.

Live-verified post-fix: RabbitMQ Cluster Operator pod healthy, `home-assistant-mqtt-rmq-server-0` pod `1/1 Running`, `rabbitmqctl list_users` shows `ha` and `mmalyska` (administrator) with full permissions on vhost `/`, node reports fully booted. MQTT pub/sub round-trip was not performed (no MQTT client available in the verification environment) — left to the user if desired.

## Global Constraints

- Never mutate live cluster state (kubectl apply/delete, ArgoCD sync) without explicit user confirmation — this repo's changes land via PR + ArgoCD auto-sync, not manual `kubectl apply`.
- Never push to `main` directly — already on branch `feat/rabbitmq-operator`. **(Deviation: Tasks 4 and 5 used their own branches off `main` instead — see Status above.)**
- Render every manifest/values change before committing: `helm template` for Helm-based apps, `kubectl kustomize` for Kustomize-based apps, then `task lint:all`.
- Never commit secret values — gitleaks pre-commit hook blocks it. Bitwarden `remoteRef.key` UUIDs are not secret values themselves and are tagged `#gitleaks:allow` per existing convention in this repo.
- OnlyOffice is explicitly out of scope (Community Edition structurally cannot use an external broker — see `docs/superpowers/specs/2026-07-06-rabbitmq-operator-design.md`). Do not touch `cluster/apps/default/nextcloud/onlyoffice/`.
- The Messaging Topology Operator is **not** deployed. No `Queue`/`Exchange`/`Binding`/`User`/`Vhost` CRDs anywhere in this plan — per-app user/queue provisioning is definitions-import via `ExternalSecret`, same pattern as VerneMQ today.
- **Deviation from the design doc, discovered during this planning pass:** the design doc said "PodMonitor". The upstream RabbitMQ Cluster Operator's own monitoring guide (for versions >v1.6.0, which v2.22.1 is) recommends a `ServiceMonitor` targeting the Service's `prometheus` port, not a `PodMonitor`. This plan uses `ServiceMonitor` and names the chart field `monitoring.enableServiceMonitor` accordingly.

---

### Task 1: RabbitMQ Cluster Operator system app

**Files:**
- Create: `cluster/apps/system/rabbitmq-cluster-operator/kustomization.yaml`
- Create: `cluster/apps/system/rabbitmq-cluster-operator/app-config.yaml`

**Interfaces:**
- Produces: CRD `rabbitmqclusters.rabbitmq.com` (`apiVersion: rabbitmq.com/v1beta1`, `kind: RabbitmqCluster`) registered cluster-wide, and a running operator Deployment in namespace `rabbitmq-system`. Tasks 2+ depend on this CRD existing before any `RabbitmqCluster` object can reconcile.

- [x] **Step 1: Create the kustomization pulling the pinned upstream release**

```bash
mkdir -p /workspaces/home-ops/cluster/apps/system/rabbitmq-cluster-operator
```

Create `cluster/apps/system/rabbitmq-cluster-operator/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
metadata:
  name: rabbitmq-cluster-operator

resources:
  # renovate-raw: datasource=github-releases depName=rabbitmq/cluster-operator
  - https://github.com/rabbitmq/cluster-operator/releases/download/v2.22.1/cluster-operator.yml
```

**Note:** the release manifest already creates its own `rabbitmq-system` Namespace and sets `metadata.namespace: rabbitmq-system` on every namespaced object, and includes a cert-manager `Issuer`/`Certificate` for its admission webhook — this repo already runs `cert-manager` as a system app, so the webhook's TLS cert will provision correctly once this app syncs.

- [x] **Step 2: Create the app-config**

Create `cluster/apps/system/rabbitmq-cluster-operator/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: rabbitmq-system
  syncWave: "-5"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

`syncWave: "-5"` matches the precedent set by `cluster/apps/system/external-secrets/app-config.yaml` — both are operators whose CRDs other apps instantiate resources against directly, so they need to exist before consumer apps sync.

- [x] **Step 3: Render and verify**

Run:
```bash
kubectl kustomize cluster/apps/system/rabbitmq-cluster-operator | grep -c "kind: CustomResourceDefinition"
kubectl kustomize cluster/apps/system/rabbitmq-cluster-operator | grep "name: rabbitmqclusters.rabbitmq.com"
```
Expected: first command prints `1`, second prints a matching line (the CRD's `metadata.name`).

- [x] **Step 4: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 5: Commit**

```bash
git add cluster/apps/system/rabbitmq-cluster-operator/
git commit -m "feat(rabbitmq): add RabbitMQ Cluster Operator system app"
```

---

### Task 2: Reusable `rabbitmq-cluster` chart

**Files:**
- Create: `charts/rabbitmq-cluster/Chart.yaml`
- Create: `charts/rabbitmq-cluster/values.yaml`
- Create: `charts/rabbitmq-cluster/templates/rabbitmqcluster.yaml`

**Interfaces:**
- Consumes: nothing (leaf chart, depends only on the CRD from Task 1 existing in the cluster at apply time — not at render time, so `helm template` works standalone without Task 1 being deployed).
- Produces (values contract for Task 3 and any future consumer):
  - `name` (string, required) — instance name; CR is named `<name>-rmq`.
  - `replicas` (int, default `1`)
  - `image` (string, default `""` — omitted from the CR when empty, operator default image is used)
  - `storage.size` (string, default `5Gi`) — maps to `spec.persistence.storage`
  - `resources` (map, default `{}`) — passed through verbatim to `spec.resources`
  - `additionalPlugins` (list, default `[]`) — passed through to `spec.rabbitmq.additionalPlugins`, with `rabbitmq_prometheus` auto-appended when monitoring is enabled
  - `additionalConfig` (string, default `""`) — passed through to `spec.rabbitmq.additionalConfig`
  - `override` (map, default `{}`) — passed through verbatim to `spec.override` (used by Task 3 to add the MQTT service port and mount the definitions-import secret)
  - `monitoring.enableServiceMonitor` (bool, default `true`)
  - Renders a `ServiceMonitor` named `<name>-rmq` selecting `app.kubernetes.io/name: <name>-rmq` + `app.kubernetes.io/component: rabbitmq` when monitoring is enabled, scraping the Service's `prometheus` port.

- [x] **Step 1: Create Chart.yaml**

```bash
mkdir -p /workspaces/home-ops/charts/rabbitmq-cluster/templates
```

Create `charts/rabbitmq-cluster/Chart.yaml`:

```yaml
---
apiVersion: v2
name: rabbitmq-cluster
type: application
version: 1.0.0
```

- [x] **Step 2: Create values.yaml**

Create `charts/rabbitmq-cluster/values.yaml`:

```yaml
name: ""
replicas: 1
image: ""
storage:
  size: 5Gi
resources: {}
additionalPlugins: []
additionalConfig: ""
override: {}
monitoring:
  enableServiceMonitor: true
```

- [x] **Step 3: Create the template**

Create `charts/rabbitmq-cluster/templates/rabbitmqcluster.yaml`:

```yaml
{{- $plugins := .Values.additionalPlugins | default list }}
{{- if .Values.monitoring.enableServiceMonitor }}
{{- $plugins = append $plugins "rabbitmq_prometheus" }}
{{- end }}
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: {{ printf "%s-%s" .Values.name "rmq" }}
  {{- with .Values.annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  replicas: {{ .Values.replicas }}
  {{- if .Values.image }}
  image: {{ .Values.image }}
  {{- end }}
  persistence:
    storage: {{ .Values.storage.size }}
  {{- with .Values.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  rabbitmq:
    additionalPlugins:
      {{- toYaml $plugins | nindent 6 }}
    {{- with .Values.additionalConfig }}
    additionalConfig: |
      {{- . | nindent 6 }}
    {{- end }}
  {{- with .Values.override }}
  override:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- if .Values.monitoring.enableServiceMonitor }}
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ printf "%s-%s" .Values.name "rmq" }}
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ printf "%s-%s" .Values.name "rmq" }}
      app.kubernetes.io/component: rabbitmq
  endpoints:
    - port: prometheus
      interval: 15s
{{- end }}
```

- [x] **Step 4: Render and verify**

Run:
```bash
helm template test-instance charts/rabbitmq-cluster --set name=test-instance
```
Expected: two documents — a `RabbitmqCluster` named `test-instance-rmq` with `spec.rabbitmq.additionalPlugins: [rabbitmq_prometheus]`, and a `ServiceMonitor` named `test-instance-rmq` with `matchLabels` `app.kubernetes.io/name: test-instance-rmq` and `app.kubernetes.io/component: rabbitmq`. No Helm template errors.

Then verify the monitoring-disabled path:
```bash
helm template test-instance charts/rabbitmq-cluster --set name=test-instance --set monitoring.enableServiceMonitor=false
```
Expected: only the `RabbitmqCluster` document, `additionalPlugins` is an empty list, no `ServiceMonitor` document.

- [x] **Step 5: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 6: Commit**

```bash
git add charts/rabbitmq-cluster/
git commit -m "feat(charts): add reusable rabbitmq-cluster chart"
```

---

### Task 3: Home Assistant's standalone `rabbitmq` app

**Files:**
- Create: `cluster/apps/home-automation/rabbitmq/Chart.yaml`
- Create: `cluster/apps/home-automation/rabbitmq/app-config.yaml`
- Create: `cluster/apps/home-automation/rabbitmq/values.yaml`
- Create: `cluster/apps/home-automation/rabbitmq/templates/external-secret.yaml`

**Interfaces:**
- Consumes: `rabbitmq-cluster` chart's values contract (Task 2) — `name`, `additionalPlugins`, `additionalConfig`, `override`, `monitoring.enableServiceMonitor`.
- Produces: Service `home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local` exposing AMQP (`5672`), management (`15672`), Prometheus (`15692`), and MQTT (`1883`, added via `override.service`). Secret `rabbitmq-definitions` in namespace `ha-rabbitmq`, mounted into the RabbitMQ pod at `/etc/rabbitmq-definitions/definitions.json` and imported at boot, creating fixed users `admin` and `home_assistant` — same Bitwarden credentials VerneMQ already uses today, so no Bitwarden changes are needed for the swap.

- [x] **Step 1: Create Chart.yaml**

```bash
mkdir -p /workspaces/home-ops/cluster/apps/home-automation/rabbitmq/templates
```

Create `cluster/apps/home-automation/rabbitmq/Chart.yaml`:

```yaml
---
apiVersion: v2
name: rabbitmq
type: application
version: 1.0.0
dependencies:
  - name: rabbitmq-cluster
    version: 1.0.0
    repository: file://../../../../charts/rabbitmq-cluster/
```

- [x] **Step 2: Create app-config.yaml**

Create `cluster/apps/home-automation/rabbitmq/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: ha-rabbitmq
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

- [x] **Step 3: Create values.yaml**

Create `cluster/apps/home-automation/rabbitmq/values.yaml`:

```yaml
rabbitmq-cluster:
  name: home-assistant-mqtt
  additionalPlugins:
    - rabbitmq_mqtt
  additionalConfig: |
    load_definitions = /etc/rabbitmq-definitions/definitions.json
  override:
    statefulSet:
      spec:
        template:
          spec:
            containers:
              - name: rabbitmq
                volumeMounts:
                  - name: definitions
                    mountPath: /etc/rabbitmq-definitions
            volumes:
              - name: definitions
                secret:
                  secretName: rabbitmq-definitions
    service:
      spec:
        ports:
          - name: mqtt
            port: 1883
            targetPort: 1883
            protocol: TCP
  monitoring:
    enableServiceMonitor: true
```

No `image` override — the operator's v2.22.1 default RabbitMQ image is well above the 3.12 floor needed for the modern native MQTT plugin implementation.

- [x] **Step 4: Create the definitions-import ExternalSecret**

Create `cluster/apps/home-automation/rabbitmq/templates/external-secret.yaml`, reusing the exact same Bitwarden entries VerneMQ's own `templates/external-secret.yaml` already pulls from (same admin/home_assistant credentials — no Bitwarden changes needed):

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.devbu.io/external-secrets.io/externalsecret_v1beta1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: rabbitmq-definitions
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: rabbitmq-definitions
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        definitions.json: |
          {
            "users": [
              {"name": "{{ `{{ .admin_username }}` }}", "password": "{{ `{{ .admin_password }}` }}", "tags": ["administrator"]},
              {"name": "{{ `{{ .home_assistant_username }}` }}", "password": "{{ `{{ .home_assistant_password }}` }}", "tags": []}
            ],
            "permissions": [
              {"user": "{{ `{{ .admin_username }}` }}", "vhost": "/", "configure": ".*", "write": ".*", "read": ".*"},
              {"user": "{{ `{{ .home_assistant_username }}` }}", "vhost": "/", "configure": ".*", "write": ".*", "read": ".*"}
            ]
          }
  data:
    - secretKey: admin_username
      remoteRef:
        key: "51a18ec8-bede-48ab-b519-b40a00d706e9" #gitleaks:allow #RABBITMQ_ADMIN_USERNAME (reused from VERNEMQ_ADMIN_USERNAME)
    - secretKey: admin_password
      remoteRef:
        key: "b41c1bad-ee30-4007-99cc-b40a00d72284" #gitleaks:allow #RABBITMQ_ADMIN_PASSWORD (reused from VERNEMQ_ADMIN_PASSWORD)
    - secretKey: home_assistant_username
      remoteRef:
        key: "05543802-765d-45dc-b97a-b40a00d743b1" #gitleaks:allow #RABBITMQ_HOME_ASSISTANT_USERNAME (reused from VERNEMQ_HOME_ASSISTANT_USERNAME)
    - secretKey: home_assistant_password
      remoteRef:
        key: "f872ad0e-cc13-42ec-b3b8-b40a00d76098" #gitleaks:allow #RABBITMQ_HOME_ASSISTANT_PASSWORD (reused from VERNEMQ_HOME_ASSISTANT_PASSWORD)
```

- [x] **Step 5: Render and verify**

Run:
```bash
cd cluster/apps/home-automation/rabbitmq
helm dependency build
helm template rabbitmq . -f values.yaml
```
Expected: a `RabbitmqCluster` named `home-assistant-mqtt-rmq` with `additionalPlugins: [rabbitmq_mqtt, rabbitmq_prometheus]`, `spec.rabbitmq.additionalConfig` containing `load_definitions = /etc/rabbitmq-definitions/definitions.json`, `spec.override` containing the volume mount and the `mqtt` service port; a `ServiceMonitor`; and an `ExternalSecret` named `rabbitmq-definitions`. No template errors.

- [x] **Step 6: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 7: Commit**

```bash
git add cluster/apps/home-automation/rabbitmq/
git commit -m "feat(home-automation): add rabbitmq app with MQTT plugin for Home Assistant"
```

- [x] **Step 8: Push and open a PR, then STOP for live verification**

```bash
git push -u origin feat/rabbitmq-operator
gh pr create --title "feat: add RabbitMQ operator + Home Assistant MQTT migration" --body "$(cat <<'EOF'
## Summary
- Deploys the RabbitMQ Cluster Operator (Kustomize, upstream release manifest, no Bitnami)
- Adds reusable `charts/rabbitmq-cluster/` chart mirroring `charts/pgsql-cnpg/`
- Adds `home-assistant/rabbitmq` app with MQTT plugin, ready as a VerneMQ replacement (not yet cut over)

See `docs/superpowers/specs/2026-07-06-rabbitmq-operator-design.md` for full design context.

## Test plan
- [x] `helm template` / `kubectl kustomize` render clean (done locally, see commits)
- [x] After merge: confirm operator pod healthy in `rabbitmq-system`
- [x] After merge: confirm `home-assistant-mqtt-rmq` pod healthy in `ha-rabbitmq` (required two follow-up fixes, see Status/Deviations above)
- [x] After merge: `kubectl exec` into the pod, `rabbitmqctl list_users` shows `admin` and `home_assistant` (actual usernames are `mmalyska`/`ha` per the Bitwarden values behind those placeholder names — both present with correct tags/permissions)
- [ ] After merge: MQTT round-trip test (`mosquitto_pub`/`mosquitto_sub` against the new broker's `1883` port) succeeds — not performed, no MQTT client available during verification; left to the user
EOF
)"
```

**STOP HERE.** Do not proceed to Task 4 until the user has merged this PR and confirmed the live-cluster checks in the PR's test plan pass. This is a live-cluster verification gate, not something to assume.

---

### Task 4: Cutover Home Assistant to the new broker

**Files:**
- Modify: `cluster/apps/home-automation/home-assistant/templates/secrets.yaml`

**Interfaces:**
- Consumes: the live, verified `home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local` Service from Task 3.

- [x] **Step 1: Confirm the Task 3 gate was actually passed**

Before editing anything, confirm with the user that the PR from Task 3 is merged and all live-verification checkboxes in its test plan are checked. If not, stop and wait.

- [x] **Step 2: Update the MQTT host**

In `cluster/apps/home-automation/home-assistant/templates/secrets.yaml`, change:

```yaml
        SECRET_MQTT_HOST: "mqtt://vernemq.ha-vernemq.svc.cluster.local"
```

to:

```yaml
        SECRET_MQTT_HOST: "mqtt://home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local"
```

No other lines in this file change — credentials stay the same (`SECRET_MQTT_USERNAME`/`SECRET_MQTT_PASSWORD` already resolve to the same Bitwarden values the new broker's definitions.json was built from).

- [x] **Step 3: Render and verify**

Run:
```bash
cd cluster/apps/home-automation/home-assistant
helm template home-assistant . -f values.yaml | grep -A2 SECRET_MQTT_HOST
```
Expected: shows the new host value in the rendered `ExternalSecret`'s template block (this is a Go-template string inside the manifest, so the raw literal `{{ .HOME_ASSISTANT_USERNAME }}`-style placeholders are expected to appear unresolved — only `SECRET_MQTT_HOST`'s literal string value is fully rendered by Helm).

- [x] **Step 4: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 5: Commit, push, open PR**

```bash
git add cluster/apps/home-automation/home-assistant/templates/secrets.yaml
git commit -m "feat(home-assistant): cut over MQTT broker from vernemq to rabbitmq"
git push -u origin feat/rabbitmq-operator
gh pr create --title "feat: cut over Home Assistant MQTT to RabbitMQ" --body "$(cat <<'EOF'
## Summary
- Repoints Home Assistant's MQTT connection from VerneMQ to the new RabbitMQ instance

## Test plan
- [x] After merge: Home Assistant pod restarts cleanly
- [ ] After merge: MQTT integration shows connected in Home Assistant's Settings > Devices & Services — N/A, this turned out to be a brand-new HA instance with no MQTT integration configured yet (see Status/Deviations above)
- [ ] After merge: existing MQTT-discovered devices/entities reappear (spot-check a few) — N/A, same reason
- [x] VerneMQ left running and untouched — this PR only repoints the client, so rollback is a one-line revert if anything looks wrong
EOF
)"
```

**STOP HERE.** Do not proceed to Task 5 until the user confirms this PR is merged and Home Assistant is stable on the new broker.

---

### Task 5: Remove VerneMQ

**Files:**
- Delete: `cluster/apps/home-automation/vernemq/` (entire directory)

**Interfaces:**
- Consumes: user confirmation that Task 4's cutover has been stable in production for a period the user is comfortable with (their call — this plan doesn't prescribe a wait time).

- [x] **Step 1: Confirm the Task 4 gate was actually passed**

Confirm with the user that Home Assistant has been running stably on the new broker and they're ready to delete VerneMQ. If not, stop and wait.

- [x] **Step 2: Delete the app**

```bash
git rm -r cluster/apps/home-automation/vernemq/
```

- [x] **Step 3: Lint**

Run: `task lint:all`
Expected: no errors (nothing else references the deleted directory).

- [x] **Step 4: Commit, push, open PR**

```bash
git commit -m "chore(home-automation): remove vernemq, replaced by rabbitmq"
git push -u origin feat/rabbitmq-operator
gh pr create --title "chore: remove vernemq" --body "$(cat <<'EOF'
## Summary
- Removes VerneMQ now that Home Assistant has been running stably on RabbitMQ

## Test plan
- [x] After merge: confirm ArgoCD Application for vernemq is deleted (prune) and the `ha-vernemq` namespace's resources are gone — **did not happen automatically.** This repo's ApplicationSets all use `applicationsSync: create-update` (never delete), so the `Application` sat indefinitely with `ComparisonError: app path does not exist`. Required a manual `kubectl delete application vernemq -n argocd` (confirmed with the user first) — the `resources-finalizer.argocd.argoproj.io` finalizer then cascade-deleted the StatefulSet/pods/Services. See the plan's Status section for the full writeup and the takeaway for future app-removal plans.
- [x] Confirm Home Assistant MQTT still connected post-prune — N/A for this instance (fresh HA install, no MQTT integration configured yet); RabbitMQ pod itself unaffected by the vernemq deletion.
- [x] **Added, not in the original test plan:** the two `data-vernemq-{0,1}` PVCs (StatefulSet `volumeClaimTemplates`-managed, so not cascade-deleted by ArgoCD) were left bound after the Application delete. Deleted separately via `kubectl delete pvc data-vernemq-0 data-vernemq-1 -n ha-vernemq`, with explicit user confirmation since this is irreversible data loss. `ha-vernemq` namespace is now fully empty.
EOF
)"
```

**STOP HERE.** This is the final task — confirm with the user after merge that the ArgoCD prune completed cleanly.

**Actual outcome:** confirmed complete. See the Status section at the top of this plan for the full manual-deletion writeup — merging the PR alone was not sufficient in this repo.
