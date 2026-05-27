# hermes-agent Chart Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the hermes-agent Helm chart so external secrets, hermes config, and PVC backup definitions are all driven from `values.yaml` rather than hardcoded in templates.

**Architecture:** Move the `externalSecrets` list into values and loop over it in both `externalsecret.yaml` and `deployment.yaml`; move the hermes config YAML into `values.yaml` under `hermes.config` and render it from `configmap.yaml`; add a new `volsync.yaml` template with two ExternalSecret + ReplicationSource pairs (one per PVC) using the shared cluster restic credentials.

**Tech Stack:** Helm 3, Kubernetes, external-secrets.io/v1 ExternalSecret, volsync.backube/v1alpha1 ReplicationSource, Bitwarden Secrets Manager via ClusterSecretStore

---

## File Map

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `values.yaml` | Add `externalSecrets` list, `hermes.config` block, `backup` block |
| Modify | `templates/externalsecret.yaml` | Loop over `.Values.externalSecrets` to emit data entries |
| Modify | `templates/deployment.yaml` | Loop over `.Values.externalSecrets` for `secretKeyRef` env vars |
| Modify | `templates/configmap.yaml` | Render `hermes.config` from values via `toYaml` |
| Create | `templates/volsync.yaml` | Two ExternalSecret + ReplicationSource pairs for PVC backups |

---

### Task 1: Update values.yaml

**Files:**
- Modify: `cluster/apps/default/hermes-agent/values.yaml`

- [ ] **Step 1: Replace the full contents of `values.yaml`**

```yaml
hermes:
  image:
    repository: nousresearch/hermes-agent
    tag: "main@sha256:3555b9eb722bca03b81815a1b309602a345604e5cfcf2c5f42e2b496fd115722"
  resources:
    requests:
      cpu: 200m
      memory: 512Mi
    limits:
      memory: 1Gi
  config:
    model:
      provider: "anthropic"
      default: "claude-sonnet-4-6"
    display:
      show_cost: true

signalCli:
  image:
    repository: bbernhard/signal-cli-rest-api
    tag: "0.99@sha256:96578363477d97cb1d8da303791b2ad686b374a255fce4d78c7c6f00ef56cba8"
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      memory: 1Gi

externalSecrets:
  - secretName: ANTHROPIC_TOKEN
    bwsId: "2c6efb7e-d4e6-4dc5-ada9-b45600b5ce8e" #gitleaks:allow #ANTHROPIC_TOKEN
  - secretName: OPENROUTER_API_KEY
    bwsId: "790817a9-4048-4bcb-b23a-b4560090065b" #gitleaks:allow #HERMES_OPENROUTER_API_KEY
  - secretName: SIGNAL_ACCOUNT
    bwsId: "158c3d58-550d-4d5b-abff-b456008e27e2" #gitleaks:allow #HERMES_SIGNAL_ACCOUNT
  - secretName: SIGNAL_ALLOWED_USERS
    bwsId: "719fd085-f387-4332-a675-b456008e757a" #gitleaks:allow #HERMES_SIGNAL_ALLOWED_USERS
  - secretName: SIGNAL_HOME_CHANNEL
    bwsId: "398a8c7d-403f-4f06-b441-b45600aa8c7f" #gitleaks:allow #HERMES_SIGNAL_HOME_CHANNEL
  - secretName: DISCORD_BOT_TOKEN
    bwsId: "be7ed9dc-3301-4c8b-adcd-b45600ea8816" #gitleaks:allow #HERMES_DISCORD_BOT_TOKEN
  - secretName: DISCORD_ALLOWED_USERS
    bwsId: "17384da9-0339-44a9-b322-b45600eaaf2b" #gitleaks:allow #HERMES_DISCORD_ALLOWED_USERS

backup:
  schedule: "0 */6 * * *"
  retention:
    daily: 6
    weekly: 4
    monthly: 2
```

- [ ] **Step 2: Verify file saved correctly**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml 2>&1 | head -5
```

Expected: Helm parses without error (output will show rendered YAML).

---

### Task 2: Update externalsecret.yaml to loop over values

**Files:**
- Modify: `cluster/apps/default/hermes-agent/templates/externalsecret.yaml`

- [ ] **Step 1: Replace the full contents of `externalsecret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hermes-agent-secrets
  namespace: hermes-agent
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: hermes-agent-secrets
    creationPolicy: Owner
  data:
    {{- range .Values.externalSecrets }}
    - secretKey: {{ .secretName }}
      remoteRef:
        key: {{ .bwsId | quote }}
    {{- end }}
```

- [ ] **Step 2: Render and verify ExternalSecret output**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent | grep -A 40 "kind: ExternalSecret" | head -50
```

Expected output should show all 7 secret entries rendered from the loop, e.g.:
```yaml
  data:
    - secretKey: ANTHROPIC_TOKEN
      remoteRef:
        key: "2c6efb7e-d4e6-4dc5-ada9-b45600b5ce8e" #gitleaks:allow
    - secretKey: OPENROUTER_API_KEY
    ...
```

---

### Task 3: Update deployment.yaml to loop over externalSecrets for env vars

**Files:**
- Modify: `cluster/apps/default/hermes-agent/templates/deployment.yaml`

- [ ] **Step 1: Replace the hardcoded `secretKeyRef` env var block in `deployment.yaml`**

Replace the section from line 73 (`- name: ANTHROPIC_TOKEN`) through line 108 (`key: DISCORD_ALLOWED_USERS`) with a loop. The full `env:` block in the hermes-agent container should become:

```yaml
          env:
            - name: HOME
              value: /opt/data
            - name: HERMES_DASHBOARD
              value: "true"
            - name: OLLAMA_BASE_URL
              value: "http://ollama.ha-ollama.svc.cluster.local:11434/v1"
            - name: SIGNAL_HTTP_URL
              value: "http://signal-cli:8080"
            {{- range .Values.externalSecrets }}
            - name: {{ if .envName }}{{ .envName }}{{ else }}{{ .secretName }}{{ end }}
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: {{ .secretName }}
            {{- end }}
```

- [ ] **Step 2: Render and verify deployment env vars**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent | grep -A 80 "name: hermes-agent$" | grep -A 5 "secretKeyRef" | head -60
```

Expected: 7 env var entries with `secretKeyRef`, each referencing `hermes-agent-secrets`.

---

### Task 4: Update configmap.yaml to render config from values

**Files:**
- Modify: `cluster/apps/default/hermes-agent/templates/configmap.yaml`

- [ ] **Step 1: Replace the full contents of `configmap.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-config
  namespace: hermes-agent
data:
  config.yaml: |
{{ .Values.hermes.config | toYaml | indent 4 }}
```

- [ ] **Step 2: Render and verify ConfigMap output**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent | grep -A 20 "kind: ConfigMap"
```

Expected:
```yaml
data:
  config.yaml: |
    display:
      show_cost: true
    model:
      default: claude-sonnet-4-6
      provider: anthropic
```

(Note: `toYaml` sorts keys alphabetically — this is fine, the config loader doesn't care about key order.)

---

### Task 5: Add volsync.yaml for PVC backups

**Files:**
- Create: `cluster/apps/default/hermes-agent/templates/volsync.yaml`

The shared restic credential Bitwarden UUIDs (same as used by gitea):
- `REPOSITORY_TEMPLATE`: `39b92426-09c4-4a74-8285-b40a00d62b4d`
- `RESTIC_PASSWORD`: `07d70a7a-a6d9-4b0b-af1f-b40a00d649a9`
- `AWS_ACCESS_KEY_ID`: `adb66319-d083-4379-afd5-b40a00d66963`
- `AWS_SECRET_ACCESS_KEY`: `70ebd8f2-8270-46d8-8953-b40a00d6854f`

- [ ] **Step 1: Create `templates/volsync.yaml`**

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hermes-restic
  namespace: hermes-agent
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  target:
    name: hermes-restic-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        RESTIC_REPOSITORY: '{{`{{ .REPOSITORY_TEMPLATE }}`}}/hermes'
        RESTIC_PASSWORD: '{{`{{ .RESTIC_PASSWORD }}`}}'
        AWS_ACCESS_KEY_ID: '{{`{{ .AWS_ACCESS_KEY_ID }}`}}'
        AWS_SECRET_ACCESS_KEY: '{{`{{ .AWS_SECRET_ACCESS_KEY }}`}}'
  data:
    - secretKey: REPOSITORY_TEMPLATE
      remoteRef:
        key: "39b92426-09c4-4a74-8285-b40a00d62b4d" #gitleaks:allow #VOLSYNC_RESTIC_REPOSITORY_TEMPLATE
    - secretKey: RESTIC_PASSWORD
      remoteRef:
        key: "07d70a7a-a6d9-4b0b-af1f-b40a00d649a9" #gitleaks:allow #VOLSYNC_RESTIC_PASSWORD
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: "adb66319-d083-4379-afd5-b40a00d66963" #gitleaks:allow #VOLSYNC_RESTIC_AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: "70ebd8f2-8270-46d8-8953-b40a00d6854f" #gitleaks:allow #VOLSYNC_RESTIC_AWS_SECRET_ACCESS_KEY
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: hermes
  namespace: hermes-agent
spec:
  sourcePVC: hermes-agent-data
  trigger:
    schedule: {{ .Values.backup.schedule | quote }}
  restic:
    copyMethod: Snapshot
    pruneIntervalDays: 14
    repository: hermes-restic-secret
    retain:
      daily: {{ .Values.backup.retention.daily }}
      weekly: {{ .Values.backup.retention.weekly }}
      monthly: {{ .Values.backup.retention.monthly }}
    moverSecurityContext:
      runAsUser: 0
      runAsGroup: 0
      fsGroup: 0
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hermes-signal-restic
  namespace: hermes-agent
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  target:
    name: hermes-signal-restic-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        RESTIC_REPOSITORY: '{{`{{ .REPOSITORY_TEMPLATE }}`}}/hermes-signal'
        RESTIC_PASSWORD: '{{`{{ .RESTIC_PASSWORD }}`}}'
        AWS_ACCESS_KEY_ID: '{{`{{ .AWS_ACCESS_KEY_ID }}`}}'
        AWS_SECRET_ACCESS_KEY: '{{`{{ .AWS_SECRET_ACCESS_KEY }}`}}'
  data:
    - secretKey: REPOSITORY_TEMPLATE
      remoteRef:
        key: "39b92426-09c4-4a74-8285-b40a00d62b4d" #gitleaks:allow #VOLSYNC_RESTIC_REPOSITORY_TEMPLATE
    - secretKey: RESTIC_PASSWORD
      remoteRef:
        key: "07d70a7a-a6d9-4b0b-af1f-b40a00d649a9" #gitleaks:allow #VOLSYNC_RESTIC_PASSWORD
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: "adb66319-d083-4379-afd5-b40a00d66963" #gitleaks:allow #VOLSYNC_RESTIC_AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: "70ebd8f2-8270-46d8-8953-b40a00d6854f" #gitleaks:allow #VOLSYNC_RESTIC_AWS_SECRET_ACCESS_KEY
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: hermes-signal
  namespace: hermes-agent
spec:
  sourcePVC: hermes-signal-data
  trigger:
    schedule: {{ .Values.backup.schedule | quote }}
  restic:
    copyMethod: Snapshot
    pruneIntervalDays: 14
    repository: hermes-signal-restic-secret
    retain:
      daily: {{ .Values.backup.retention.daily }}
      weekly: {{ .Values.backup.retention.weekly }}
      monthly: {{ .Values.backup.retention.monthly }}
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
```

Note: `hermes-agent-data` uses `runAsUser: 0` because the hermes container runs as root. `hermes-signal-data` uses `1000` to match the signal-cli deployment `securityContext`.

- [ ] **Step 2: Render and verify volsync output**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent | grep -A 20 "kind: ReplicationSource"
```

Expected: Two `ReplicationSource` blocks — `hermes` pointing to `hermes-agent-data` and `hermes-signal` pointing to `hermes-signal-data`, each with the schedule from values.

---

### Task 6: Full render and lint

**Files:** (no changes)

- [ ] **Step 1: Full helm template render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent
```

Expected: Clean output with no errors. Should include: 1 ExternalSecret (hermes-agent-secrets), 2 volsync ExternalSecrets (hermes-restic, hermes-signal-restic), 2 ReplicationSources, 1 ConfigMap, 2 Deployments, 2 PVCs, 2 Services, 1 HTTPRoute.

- [ ] **Step 2: Run linter**

```bash
cd /workspaces/home-ops && task lint:all
```

Expected: All checks pass (yamllint, helm lint, prettier).

- [ ] **Step 3: Commit**

```bash
git add cluster/apps/default/hermes-agent/
git commit -m "feat(hermes-agent): drive secrets, config, and PVC backups from values"
```
