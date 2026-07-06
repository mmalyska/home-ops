# RabbitMQ Operator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the RabbitMQ Cluster Operator, build a reusable `rabbitmq-cluster` chart mirroring `charts/pgsql-cnpg/`, and migrate Home Assistant off VerneMQ onto a RabbitMQ instance with the MQTT plugin.

**Architecture:** A Kustomize-based system app installs the official `rabbitmq/cluster-operator` release manifest (CRD + controller, no Bitnami). A new leaf chart `charts/rabbitmq-cluster/` templates a single `RabbitmqCluster` CR (+ optional `ServiceMonitor`) per consuming app, values-driven like `pgsql-cnpg`. A new standalone app `cluster/apps/home-automation/rabbitmq/` depends on that chart with the `rabbitmq_mqtt` plugin enabled and a definitions-import secret providing fixed `admin`/`home_assistant` users (same mechanism VerneMQ's own `templates/external-secret.yaml` already uses). Home Assistant is repointed at it, then VerneMQ is deleted.

**Tech Stack:** Helm, Kustomize, ArgoCD ApplicationSet, RabbitMQ Cluster Operator v2.22.1 (`rabbitmq.com/v1beta1` `RabbitmqCluster` CRD), External Secrets Operator + Bitwarden `ClusterSecretStore`, Prometheus Operator (`ServiceMonitor` CRD).

## Global Constraints

- Never mutate live cluster state (kubectl apply/delete, ArgoCD sync) without explicit user confirmation — this repo's changes land via PR + ArgoCD auto-sync, not manual `kubectl apply`.
- Never push to `main` directly — already on branch `feat/rabbitmq-operator`.
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

- [ ] **Step 1: Create the kustomization pulling the pinned upstream release**

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

- [ ] **Step 2: Create the app-config**

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

- [ ] **Step 3: Render and verify**

Run:
```bash
kubectl kustomize cluster/apps/system/rabbitmq-cluster-operator | grep -c "kind: CustomResourceDefinition"
kubectl kustomize cluster/apps/system/rabbitmq-cluster-operator | grep "name: rabbitmqclusters.rabbitmq.com"
```
Expected: first command prints `1`, second prints a matching line (the CRD's `metadata.name`).

- [ ] **Step 4: Lint**

Run: `task lint:all`
Expected: no errors.

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Create Chart.yaml**

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

- [ ] **Step 2: Create values.yaml**

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

- [ ] **Step 3: Create the template**

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

- [ ] **Step 4: Render and verify**

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

- [ ] **Step 5: Lint**

Run: `task lint:all`
Expected: no errors.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Create Chart.yaml**

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

- [ ] **Step 2: Create app-config.yaml**

Create `cluster/apps/home-automation/rabbitmq/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: ha-rabbitmq
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

- [ ] **Step 3: Create values.yaml**

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

- [ ] **Step 4: Create the definitions-import ExternalSecret**

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

- [ ] **Step 5: Render and verify**

Run:
```bash
cd cluster/apps/home-automation/rabbitmq
helm dependency build
helm template rabbitmq . -f values.yaml
```
Expected: a `RabbitmqCluster` named `home-assistant-mqtt-rmq` with `additionalPlugins: [rabbitmq_mqtt, rabbitmq_prometheus]`, `spec.rabbitmq.additionalConfig` containing `load_definitions = /etc/rabbitmq-definitions/definitions.json`, `spec.override` containing the volume mount and the `mqtt` service port; a `ServiceMonitor`; and an `ExternalSecret` named `rabbitmq-definitions`. No template errors.

- [ ] **Step 6: Lint**

Run: `task lint:all`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add cluster/apps/home-automation/rabbitmq/
git commit -m "feat(home-automation): add rabbitmq app with MQTT plugin for Home Assistant"
```

- [ ] **Step 8: Push and open a PR, then STOP for live verification**

```bash
git push -u origin feat/rabbitmq-operator
gh pr create --title "feat: add RabbitMQ operator + Home Assistant MQTT migration" --body "$(cat <<'EOF'
## Summary
- Deploys the RabbitMQ Cluster Operator (Kustomize, upstream release manifest, no Bitnami)
- Adds reusable `charts/rabbitmq-cluster/` chart mirroring `charts/pgsql-cnpg/`
- Adds `home-assistant/rabbitmq` app with MQTT plugin, ready as a VerneMQ replacement (not yet cut over)

See `docs/superpowers/specs/2026-07-06-rabbitmq-operator-design.md` for full design context.

## Test plan
- [ ] `helm template` / `kubectl kustomize` render clean (done locally, see commits)
- [ ] After merge: confirm operator pod healthy in `rabbitmq-system`
- [ ] After merge: confirm `home-assistant-mqtt-rmq` pod healthy in `ha-rabbitmq`
- [ ] After merge: `kubectl exec` into the pod, `rabbitmqctl list_users` shows `admin` and `home_assistant`
- [ ] After merge: MQTT round-trip test (`mosquitto_pub`/`mosquitto_sub` against the new broker's `1883` port) succeeds
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

- [ ] **Step 1: Confirm the Task 3 gate was actually passed**

Before editing anything, confirm with the user that the PR from Task 3 is merged and all live-verification checkboxes in its test plan are checked. If not, stop and wait.

- [ ] **Step 2: Update the MQTT host**

In `cluster/apps/home-automation/home-assistant/templates/secrets.yaml`, change:

```yaml
        SECRET_MQTT_HOST: "mqtt://vernemq.ha-vernemq.svc.cluster.local"
```

to:

```yaml
        SECRET_MQTT_HOST: "mqtt://home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local"
```

No other lines in this file change — credentials stay the same (`SECRET_MQTT_USERNAME`/`SECRET_MQTT_PASSWORD` already resolve to the same Bitwarden values the new broker's definitions.json was built from).

- [ ] **Step 3: Render and verify**

Run:
```bash
cd cluster/apps/home-automation/home-assistant
helm template home-assistant . -f values.yaml | grep -A2 SECRET_MQTT_HOST
```
Expected: shows the new host value in the rendered `ExternalSecret`'s template block (this is a Go-template string inside the manifest, so the raw literal `{{ .HOME_ASSISTANT_USERNAME }}`-style placeholders are expected to appear unresolved — only `SECRET_MQTT_HOST`'s literal string value is fully rendered by Helm).

- [ ] **Step 4: Lint**

Run: `task lint:all`
Expected: no errors.

- [ ] **Step 5: Commit, push, open PR**

```bash
git add cluster/apps/home-automation/home-assistant/templates/secrets.yaml
git commit -m "feat(home-assistant): cut over MQTT broker from vernemq to rabbitmq"
git push -u origin feat/rabbitmq-operator
gh pr create --title "feat: cut over Home Assistant MQTT to RabbitMQ" --body "$(cat <<'EOF'
## Summary
- Repoints Home Assistant's MQTT connection from VerneMQ to the new RabbitMQ instance

## Test plan
- [ ] After merge: Home Assistant pod restarts cleanly
- [ ] After merge: MQTT integration shows connected in Home Assistant's Settings > Devices & Services
- [ ] After merge: existing MQTT-discovered devices/entities reappear (spot-check a few)
- [ ] VerneMQ left running and untouched — this PR only repoints the client, so rollback is a one-line revert if anything looks wrong
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

- [ ] **Step 1: Confirm the Task 4 gate was actually passed**

Confirm with the user that Home Assistant has been running stably on the new broker and they're ready to delete VerneMQ. If not, stop and wait.

- [ ] **Step 2: Delete the app**

```bash
git rm -r cluster/apps/home-automation/vernemq/
```

- [ ] **Step 3: Lint**

Run: `task lint:all`
Expected: no errors (nothing else references the deleted directory).

- [ ] **Step 4: Commit, push, open PR**

```bash
git commit -m "chore(home-automation): remove vernemq, replaced by rabbitmq"
git push -u origin feat/rabbitmq-operator
gh pr create --title "chore: remove vernemq" --body "$(cat <<'EOF'
## Summary
- Removes VerneMQ now that Home Assistant has been running stably on RabbitMQ

## Test plan
- [ ] After merge: confirm ArgoCD Application for vernemq is deleted (prune) and the `ha-vernemq` namespace's resources are gone
- [ ] Confirm Home Assistant MQTT still connected post-prune
EOF
)"
```

**STOP HERE.** This is the final task — confirm with the user after merge that the ArgoCD prune completed cleanly.
