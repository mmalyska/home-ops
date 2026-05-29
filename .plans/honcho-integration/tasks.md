# Honcho Integration — Tasks

> Self-contained checklist. Executable without reading plan.md.
> REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans.

## Prerequisites (manual, done before starting tasks)

- [ ] **P1**: Create feature branch: `git checkout -b feat/honcho-integration`
- [ ] **P2**: Add new OpenRouter API key to Bitwarden Secrets Manager (separate key for Honcho, distinct from hermes-agent's key) → note the `bwsId`

---

## Phase 1: Honcho Server

### Task 1.1: Chart scaffolding

- [ ] Create `cluster/apps/default/honcho/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: honcho
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] Create `cluster/apps/default/honcho/Chart.yaml`:

```yaml
apiVersion: v2
name: honcho
type: application
version: 1.0.0
dependencies:
  - name: pgsql-cnpg
    version: 1.2.0
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] Run: `helm dependency update cluster/apps/default/honcho/`
- [ ] Verify: `ls cluster/apps/default/honcho/Chart.lock` — file must exist.

---

### Task 1.2: ExternalSecret

- [ ] Create `cluster/apps/default/honcho/templates/externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: honcho-secrets
  namespace: honcho
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: honcho-secrets
    creationPolicy: Owner
  data:
    - secretKey: HONCHO_OPENROUTER_API_KEY
      remoteRef:
        key: {{.Values.openrouterBwsId | quote}}
    - secretKey: S3_ACCESS_KEY_ID
      remoteRef:
        key: "e00e1e38-ae37-479a-8b46-b409016331eb" #gitleaks:allow #S3_ACCESS_KEY
    - secretKey: S3_ACCESS_SECRET_KEY
      remoteRef:
        key: "4d5a418c-82ed-4b8e-bfbf-b40901634ea4" #gitleaks:allow #S3_SECRET_KEY
```

---

### Task 1.3: values.yaml

- [ ] Create `cluster/apps/default/honcho/values.yaml`. Replace `<REPLACE>` with actual OpenRouter Bitwarden ID from prerequisite P2:

```yaml
honcho:
  image:
    repository: ghcr.io/plastic-labs/honcho
    tag: "v3.0.7"
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 512Mi
  deriver:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        memory: 256Mi

openrouterBwsId: "<REPLACE: bwsId of Honcho OpenRouter key in Bitwarden>" #gitleaks:allow

pgsql-cnpg:
  name: honchodb
  imageName: ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm
  instances: 2
  storage:
    size: 5Gi
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
  bootstrap:
    initdb:
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS vector
  monitoring:
    enablePodMonitor: true
  backup:
    retentionPolicy: "10d"
    barmanObjectStore:
      destinationPath: "s3://k8s-at-home-backup/cnpg/honcho"
      endpointURL: <secret:s3_endpoint>
      s3Credentials:
        accessKeyId:
          name: honcho-secrets
          key: S3_ACCESS_KEY_ID
        secretAccessKey:
          name: honcho-secrets
          key: S3_ACCESS_SECRET_KEY
  scheduledBackups:
    - name: honchodb-cnpg-backup
      spec:
        immediate: true
        schedule: "10 0 0 * * *"
        backupOwnerReference: self
```

---

### Task 1.4: Shared env helper (configmap for LLM config)

The deployment templates reference a shared env list. Define it as a Helm helper to avoid duplication between API and Deriver.

- [ ] Create `cluster/apps/default/honcho/templates/_helpers.tpl`:

```
{{- define "honcho.llmEnv" -}}
- name: DB_USER
  valueFrom:
    secretKeyRef:
      name: honchodb-cnpg-app
      key: username
- name: DB_PASS
  valueFrom:
    secretKeyRef:
      name: honchodb-cnpg-app
      key: password
- name: DB_CONNECTION_URI
  value: "postgresql+psycopg://$(DB_USER):$(DB_PASS)@honchodb-cnpg-rw.honcho.svc.cluster.local:5432/app"
- name: AUTH_USE_AUTH
  value: "false"
- name: SENTRY_ENABLED
  value: "false"
- name: CACHE_ENABLED
  value: "false"
- name: LLM_OPENAI_API_KEY
  valueFrom:
    secretKeyRef:
      name: honcho-secrets
      key: HONCHO_OPENROUTER_API_KEY
# DERIVER
- name: DERIVER_MODEL_CONFIG__TRANSPORT
  value: openai
- name: DERIVER_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
# SUMMARY
- name: SUMMARY_MODEL_CONFIG__TRANSPORT
  value: openai
- name: SUMMARY_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: SUMMARY_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
# EMBEDDING
- name: EMBEDDING_MODEL_CONFIG__TRANSPORT
  value: openai
- name: EMBEDDING_MODEL_CONFIG__MODEL
  value: openai/text-embedding-3-small
- name: EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
# DIALECTIC levels
- name: DIALECTIC_LEVELS__minimal__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__minimal__MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DIALECTIC_LEVELS__minimal__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__low__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__low__MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DIALECTIC_LEVELS__low__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__medium__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__medium__MODEL_CONFIG__MODEL
  value: google/gemini-2.0-flash
- name: DIALECTIC_LEVELS__medium__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__high__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__high__MODEL_CONFIG__MODEL
  value: anthropic/claude-3-5-haiku
- name: DIALECTIC_LEVELS__high__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DIALECTIC_LEVELS__max__MODEL_CONFIG__TRANSPORT
  value: openai
- name: DIALECTIC_LEVELS__max__MODEL_CONFIG__MODEL
  value: anthropic/claude-3-5-sonnet
- name: DIALECTIC_LEVELS__max__MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
# DREAM
- name: DREAM_DEDUCTION_MODEL_CONFIG__TRANSPORT
  value: openai
- name: DREAM_DEDUCTION_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DREAM_DEDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
- name: DREAM_INDUCTION_MODEL_CONFIG__TRANSPORT
  value: openai
- name: DREAM_INDUCTION_MODEL_CONFIG__MODEL
  value: google/gemini-flash-1.5
- name: DREAM_INDUCTION_MODEL_CONFIG__OVERRIDES__BASE_URL
  value: https://openrouter.ai/api/v1
{{- end -}}
```

---

### Task 1.5: API Deployment

- [ ] Confirm the Honcho health endpoint: `curl -s https://raw.githubusercontent.com/plastic-labs/honcho/main/src/main.py | grep -i health` — expected `/healthcheck`.

- [ ] Create `cluster/apps/default/honcho/templates/deployment-api.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: honcho-api
  namespace: honcho
spec:
  replicas: 1
  selector:
    matchLabels:
      app: honcho-api
  template:
    metadata:
      labels:
        app: honcho-api
    spec:
      containers:
        - name: honcho-api
          image: "{{ .Values.honcho.image.repository }}:{{ .Values.honcho.image.tag }}"
          command: ["sh", "docker/entrypoint.sh"]
          env: {{- include "honcho.llmEnv" . | nindent 12}}
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /healthcheck
              port: 8000
            initialDelaySeconds: 15
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /healthcheck
              port: 8000
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 3
          resources: {{toYaml .Values.honcho.resources | nindent 12}}
```

---

### Task 1.6: Deriver Deployment

- [ ] Create `cluster/apps/default/honcho/templates/deployment-deriver.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: honcho-deriver
  namespace: honcho
spec:
  replicas: 1
  selector:
    matchLabels:
      app: honcho-deriver
  template:
    metadata:
      labels:
        app: honcho-deriver
    spec:
      containers:
        - name: honcho-deriver
          image: "{{ .Values.honcho.image.repository }}:{{ .Values.honcho.image.tag }}"
          command: ["/app/.venv/bin/python", "-m", "src.deriver"]
          env: {{- include "honcho.llmEnv" . | nindent 12}}
          resources: {{toYaml .Values.honcho.deriver.resources | nindent 12}}
```

---

### Task 1.7: Service

- [ ] Create `cluster/apps/default/honcho/templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: honcho
  namespace: honcho
spec:
  type: ClusterIP
  selector:
    app: honcho-api
  ports:
    - name: http
      port: 8000
      targetPort: 8000
      protocol: TCP
```

---

### Task 1.8: Render and lint

- [ ] Run: `helm template honcho cluster/apps/default/honcho/ -f cluster/apps/default/honcho/values.yaml`
  - Expected output: CNPG Cluster (with `vector` postInitApplicationSQL), ScheduledBackup, ExternalSecret `honcho-secrets`, Deployments `honcho-api` and `honcho-deriver`, Service `honcho`.
  - Verify `DB_CONNECTION_URI` env var renders with `postgresql+psycopg://` prefix.
  - Verify all `DIALECTIC_LEVELS__*` env vars appear in both Deployments.

- [ ] Run: `task lint:all` — no errors.

- [ ] Commit: `git add cluster/apps/default/honcho/ && git commit -m "feat(honcho): add self-hosted Honcho server with CNPG/pgvector and OpenRouter"`

---

## Phase 2: Hermes-agent wiring

### Task 2.1: Memory provider in hermes config

- [ ] In `cluster/apps/default/hermes-agent/values.yaml`, add `memory.provider: honcho` under the existing `hermes.config:` block:

```yaml
hermes:
  config:
    # ...existing fields unchanged...
    memory:
      provider: honcho
```

(The config-seeder deep-merges this into `/opt/data/config.yaml` on every pod start.)

---

### Task 2.2: honcho.json ConfigMap

- [ ] Create `cluster/apps/default/hermes-agent/templates/honcho-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-honcho
  namespace: hermes-agent
data:
  honcho.json: |
    {
      "baseUrl": "http://honcho.honcho.svc.cluster.local:8000",
      "observationMode": "directional",
      "recallMode": "hybrid",
      "sessionStrategy": "per-session",
      "contextCadence": 1,
      "dialecticCadence": 2,
      "dialecticDepth": 1,
      "hosts": {
        "hermes": {
          "enabled": true,
          "aiPeer": "hermes",
          "peerName": "mmalyska",
          "workspace": "hermes"
        },
        "hermes.orchestrator": {
          "enabled": true,
          "aiPeer": "orchestrator",
          "peerName": "mmalyska",
          "workspace": "hermes"
        },
        "hermes.devops": {
          "enabled": true,
          "aiPeer": "devops",
          "peerName": "mmalyska",
          "workspace": "hermes"
        },
        "hermes.researcher": {
          "enabled": true,
          "aiPeer": "researcher",
          "peerName": "mmalyska",
          "workspace": "hermes"
        },
        "hermes.dotnet-dev": {
          "enabled": true,
          "aiPeer": "dotnet-dev",
          "peerName": "mmalyska",
          "workspace": "hermes"
        },
        "hermes.node-dev": {
          "enabled": true,
          "aiPeer": "node-dev",
          "peerName": "mmalyska",
          "workspace": "hermes"
        },
        "hermes.mobile-dev": {
          "enabled": true,
          "aiPeer": "mobile-dev",
          "peerName": "mmalyska",
          "workspace": "hermes"
        }
      }
    }
```

---

### Task 2.3: honcho-seeder init-container

- [ ] In `cluster/apps/default/hermes-agent/templates/deployment.yaml`, add the `honcho-seeder` init-container **after** the existing `config-seeder`:

```yaml
- name: honcho-seeder
  image: "{{ .Values.hermes.image.repository }}:{{ .Values.hermes.image.tag }}"
  command:
    - python3
    - -c
    - |
      import json, os

      template_path = '/honcho-config/honcho.json'
      target_path = '/opt/data/.hermes/honcho.json'

      with open(template_path) as f:
          overrides = json.load(f)

      os.makedirs(os.path.dirname(target_path), exist_ok=True)

      if os.path.exists(target_path):
          with open(target_path) as f:
              config = json.load(f) or {}

          def deep_merge(base, src):
              for k, v in src.items():
                  if isinstance(v, dict) and isinstance(base.get(k), dict):
                      deep_merge(base[k], v)
                  else:
                      base[k] = v

          deep_merge(config, overrides)
      else:
          config = overrides

      with open(target_path, 'w') as f:
          json.dump(config, f, indent=2)

  volumeMounts:
    - name: data
      mountPath: /opt/data
    - name: honcho-config
      mountPath: /honcho-config
```

- [ ] In the same file, under `volumes:`, add:

```yaml
- name: honcho-config
  configMap:
    name: hermes-agent-honcho
```

---

### Task 2.4: Render and lint

- [ ] Run: `helm template hermes-agent cluster/apps/default/hermes-agent/ -f cluster/apps/default/hermes-agent/values.yaml`
  - Verify `honcho-seeder` init-container appears in Pod spec after `config-seeder`.
  - Verify `honcho-config` volume and mount appear.
  - Verify `memory.provider: honcho` appears in the rendered `hermes-agent-config` ConfigMap.

- [ ] Run: `task lint:all` — no errors.

- [ ] Commit: `git add cluster/apps/default/hermes-agent/ && git commit -m "feat(hermes-agent): wire Honcho as memory provider with deep-merge seeder"`

---

## Phase 3: Open PR

- [ ] Push branch: `git push -u origin feat/honcho-integration`
- [ ] Open PR with description covering: what's changed, ArgoCD sync order (Honcho first, then hermes-agent restart), rollback steps.

---

## Phase 4: Post-deploy validation

After ArgoCD syncs (Honcho app first; hermes-agent restarts after):

### Honcho healthy

- [ ] `kubectl -n honcho get pods` — all pods Running: `honcho-api-*`, `honcho-deriver-*`, `honchodb-cnpg-1`, `honchodb-cnpg-2`.
- [ ] API responds: `kubectl -n honcho exec deploy/honcho-api -- curl -s http://localhost:8000/healthcheck` — HTTP 200.

### pgvector active

- [ ] `kubectl -n honcho exec honchodb-cnpg-1 -- psql -U app app -c "SELECT extname FROM pg_extension WHERE extname='vector';"` — returns `vector`.

### honcho.json placed correctly

- [ ] `kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- cat /opt/data/.hermes/honcho.json` — file present, `baseUrl` shows `http://honcho.honcho.svc.cluster.local:8000`, 7 host blocks visible.

### Hermes sees the provider

- [ ] In Discord/Signal, send `hermes honcho status` — expected: connected, shows baseUrl and host list.

### Memory roundtrip

- [ ] Start a conversation with the `default` profile (via Discord or Signal). Share a specific preference, e.g. "I always prefer dark mode in UIs."
- [ ] Start a new session (new conversation). Ask Hermes: "What do you know about my UI preferences?" — Honcho should surface the stored fact via dialectic or context injection.

### Profile isolation check

- [ ] Start a conversation with a worker profile (e.g., `devops`). Ask it to recall the UI preference. The `devops` aiPeer has its own memory but shares the user peer (`mmalyska`) — it should see the stored user fact if sharing is configured, or return empty if isolated.

### Rollback procedure

- **Disable memory provider only**: Remove `memory.provider: honcho` from `hermes-agent/values.yaml` → ArgoCD sync → hermes-agent restarts without memory. Honcho server untouched (no data loss).
- **Disable Honcho entirely**: Set `enabled: "false"` in `cluster/apps/default/honcho/app-config.yaml` → ArgoCD sync removes Honcho app. CNPG PVC survives for later restore.
- **Full rollback**: Revert both commits on the branch and close the PR.

---

## Phase 5: Follow-up (after stable)

- [ ] Pin Honcho image to SHA digest for Renovate tracking.
- [ ] Evaluate cost: check OpenRouter billing for `honcho` key after 1 week.
- [ ] Consider `dialecticDepth: 2` if memory quality seems shallow.
- [ ] Consider enabling Redis if Honcho query latency is noticeable (>200ms).
- [ ] Add volsync backup for Honcho namespace if the CNPG PVC isn't covered.
