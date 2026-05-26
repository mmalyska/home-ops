# hermes-agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy hermes-agent (dashboard + gateway) and signal-cli to the home-ops cluster with
local Ollama as the default backend and Signal messenger as the interaction channel.

**Architecture:** Two independent Deployments in namespace `hermes-agent` — one for hermes-agent
(gateway + dashboard containers sharing a PVC) and one for signal-cli (separate PVC). Both live
under `cluster/apps/default/hermes-agent/` as a single local Helm chart with no upstream
dependencies.

**Tech Stack:** Kubernetes, Helm (local chart), ArgoCD ApplicationSet, ExternalSecrets Operator
(Bitwarden), Envoy Gateway HTTPRoute, `nousresearch/hermes-agent:main`, `bbernhard/signal-cli-rest-api:0.99`

**Spec:** `docs/superpowers/specs/2026-05-25-hermes-agent-design.md`

---

## File Map

Files to create (all under `cluster/apps/default/hermes-agent/`):

| File | Purpose |
| ---- | ------- |
| `app-config.yaml` | ArgoCD ApplicationSet entry |
| `Chart.yaml` | Local Helm chart metadata |
| `values.yaml` | Image tags + resource requests |
| `templates/pvc.yaml` | 1 Gi RWO PVC for hermes `/opt/data` |
| `templates/configmap.yaml` | Seeds `config.yaml` on first start |
| `templates/externalsecret.yaml` | API keys + Signal secrets from Bitwarden |
| `templates/deployment.yaml` | hermes-agent pod (gateway + dashboard + init) |
| `templates/service.yaml` | ClusterIP for dashboard port 9119 |
| `templates/httproute.yaml` | Internal ingress → dashboard |
| `templates/signal-pvc.yaml` | 1 Gi RWO PVC for signal-cli account data |
| `templates/signal-deployment.yaml` | signal-cli pod |
| `templates/signal-service.yaml` | ClusterIP for signal-cli port 8080 |

---

## Pre-flight

Before starting, confirm the working branch and that Bitwarden secrets exist.

- [ ] **Confirm you are on branch `chore/hermes-agent`**

```bash
git branch --show-current
# Expected: chore/hermes-agent
```

- [ ] **Create two Bitwarden secrets** (manual step in Bitwarden UI — do this before Task 4):
  - `HERMES_SIGNAL_ACCOUNT` — your Signal phone number in E.164 format (e.g. `+48600123456`)
  - `HERMES_SIGNAL_ALLOWED_USERS` — comma-separated E.164 numbers permitted to message the bot

  Note the UUIDs; you will need them in Task 4.

---

## Task 1: Scaffold chart

**Files:**

- Create: `cluster/apps/default/hermes-agent/app-config.yaml`
- Create: `cluster/apps/default/hermes-agent/Chart.yaml`
- Create: `cluster/apps/default/hermes-agent/values.yaml`

- [ ] **Create `app-config.yaml`**

```yaml
- enabled: "true"
  namespace: hermes-agent
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Create `Chart.yaml`**

```yaml
apiVersion: v2
name: hermes-agent
type: application
version: 1.0.0
```

- [ ] **Create `values.yaml`**

```yaml
hermes:
  image:
    repository: nousresearch/hermes-agent
    tag: "main@sha256:d0ecd9a002707d03ad9ef2869226503318bfe773f08df6c83e6b4b38e37f3175"
  gateway:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 512Mi
  dashboard:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        memory: 512Mi

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
```

- [ ] **Verify chart renders (empty templates dir is fine at this stage)**

```bash
mkdir -p cluster/apps/default/hermes-agent/templates
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: no output (no templates yet) and exit code 0
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/app-config.yaml \
        cluster/apps/default/hermes-agent/Chart.yaml \
        cluster/apps/default/hermes-agent/values.yaml
git commit -m "feat(hermes-agent): scaffold chart"
```

---

## Task 2: hermes-agent PVC

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/pvc.yaml`

- [ ] **Create `templates/pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-agent-data
  namespace: hermes-agent
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: PVC manifest with name hermes-agent-data
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/pvc.yaml
git commit -m "feat(hermes-agent): add hermes data PVC"
```

---

## Task 3: ConfigMap — seed config.yaml

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/configmap.yaml`

The init container copies this file to `/opt/data/config.yaml` only if the file does not already
exist, so user changes made via the dashboard survive pod restarts.

- [ ] **Create `templates/configmap.yaml`**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-config
  namespace: hermes-agent
data:
  config.yaml: |
    model:
      provider: "ollama"
      default: "qwen3.5:9b"
      base_url: "http://ollama.ha-ollama.svc.cluster.local:11434/v1"
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: ConfigMap manifest with config.yaml key
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/configmap.yaml
git commit -m "feat(hermes-agent): add config seed ConfigMap"
```

---

## Task 4: ExternalSecret

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/externalsecret.yaml`

Replace `SIGNAL_ACCOUNT_UUID` and `SIGNAL_ALLOWED_USERS_UUID` with the Bitwarden UUIDs you noted
in the pre-flight step.

- [ ] **Create `templates/externalsecret.yaml`**

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
    - secretKey: ANTHROPIC_API_KEY
      remoteRef:
        key: "b4f5ae0d-6b2e-44bc-85ee-b409016935b1" #gitleaks:allow #LITELLM_ANTHROPIC_API_KEY
    # Uncomment and add your Bitwarden UUID to enable OpenRouter:
    # - secretKey: OPENROUTER_API_KEY
    #   remoteRef:
    #     key: "YOUR_BITWARDEN_UUID_HERE" #gitleaks:allow #HERMES_OPENROUTER_API_KEY
    - secretKey: SIGNAL_ACCOUNT
      remoteRef:
        key: "SIGNAL_ACCOUNT_UUID" #gitleaks:allow #HERMES_SIGNAL_ACCOUNT
    - secretKey: SIGNAL_ALLOWED_USERS
      remoteRef:
        key: "SIGNAL_ALLOWED_USERS_UUID" #gitleaks:allow #HERMES_SIGNAL_ALLOWED_USERS
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: ExternalSecret manifest with four data entries (ANTHROPIC_API_KEY, two Signal entries;
# OPENROUTER commented out)
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/externalsecret.yaml
git commit -m "feat(hermes-agent): add ExternalSecret for API keys and Signal secrets"
```

---

## Task 5: hermes-agent Deployment

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/deployment.yaml`

The pod has:

- **init container** `config-seeder`: copies ConfigMap-mounted `config.yaml` to the PVC if absent
- **gateway** container: runs `gateway run` via args (ENTRYPOINT `/init` is preserved)
- **dashboard** container: runs `dashboard --host 0.0.0.0 --no-open`

Both main containers share the `hermes-agent-data` PVC and inject secrets from `hermes-agent-secrets`.

- [ ] **Create `templates/deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hermes-agent
  template:
    metadata:
      labels:
        app: hermes-agent
      annotations:
        checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
    spec:
      initContainers:
        - name: config-seeder
          image: "{{ .Values.hermes.image.repository }}:{{ .Values.hermes.image.tag }}"
          command:
            - sh
            - -c
            - "[ -f /opt/data/config.yaml ] || cp /config-template/config.yaml /opt/data/config.yaml"
          volumeMounts:
            - name: data
              mountPath: /opt/data
            - name: config-template
              mountPath: /config-template
      containers:
        - name: gateway
          image: "{{ .Values.hermes.image.repository }}:{{ .Values.hermes.image.tag }}"
          args:
            - gateway
            - run
          env:
            - name: OLLAMA_BASE_URL
              value: "http://ollama.ha-ollama.svc.cluster.local:11434/v1"
            - name: SIGNAL_HTTP_URL
              value: "http://signal-cli:8080"
            - name: ANTHROPIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: ANTHROPIC_API_KEY
            - name: SIGNAL_ACCOUNT
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: SIGNAL_ACCOUNT
            - name: SIGNAL_ALLOWED_USERS
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: SIGNAL_ALLOWED_USERS
          resources: {{ toYaml .Values.hermes.gateway.resources | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /opt/data
        - name: dashboard
          image: "{{ .Values.hermes.image.repository }}:{{ .Values.hermes.image.tag }}"
          args:
            - dashboard
            - --host
            - "0.0.0.0"
            - --no-open
          ports:
            - name: http
              containerPort: 9119
              protocol: TCP
          env:
            - name: OLLAMA_BASE_URL
              value: "http://ollama.ha-ollama.svc.cluster.local:11434/v1"
            - name: SIGNAL_HTTP_URL
              value: "http://signal-cli:8080"
            - name: ANTHROPIC_API_KEY
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: ANTHROPIC_API_KEY
            - name: SIGNAL_ACCOUNT
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: SIGNAL_ACCOUNT
            - name: SIGNAL_ALLOWED_USERS
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: SIGNAL_ALLOWED_USERS
          resources: {{ toYaml .Values.hermes.dashboard.resources | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /opt/data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: hermes-agent-data
        - name: config-template
          configMap:
            name: hermes-agent-config
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: Deployment with 1 initContainer (config-seeder) and 2 containers (gateway, dashboard)
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/deployment.yaml
git commit -m "feat(hermes-agent): add hermes-agent Deployment"
```

---

## Task 6: hermes-agent Service

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/service.yaml`

- [ ] **Create `templates/service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: hermes-agent
  namespace: hermes-agent
spec:
  type: ClusterIP
  selector:
    app: hermes-agent
  ports:
    - name: http
      port: 9119
      targetPort: 9119
      protocol: TCP
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: Service manifest with port 9119
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/service.yaml
git commit -m "feat(hermes-agent): add dashboard Service"
```

---

## Task 7: HTTPRoute

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/httproute.yaml`

The `<secret:private-domain>` token is resolved by the `argocd-secret-replacer` CMP plugin
(enabled via `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`).

- [ ] **Create `templates/httproute.yaml`**

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hermes-agent
  namespace: hermes-agent
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - hermes.<secret:private-domain>
  rules:
    - backendRefs:
        - name: hermes-agent
          port: 9119
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: HTTPRoute manifest with hostname hermes.<secret:private-domain>
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/httproute.yaml
git commit -m "feat(hermes-agent): add internal HTTPRoute"
```

---

## Task 8: signal-cli PVC

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/signal-pvc.yaml`

- [ ] **Create `templates/signal-pvc.yaml`**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hermes-signal-data
  namespace: hermes-agent
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: two PVCs — hermes-agent-data and hermes-signal-data
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/signal-pvc.yaml
git commit -m "feat(hermes-agent): add signal-cli data PVC"
```

---

## Task 9: signal-cli Deployment

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/signal-deployment.yaml`

The container mounts its data at `/home/.local/share/signal-cli`. `MODE=json-rpc` enables
signal-cli's native JSON-RPC/SSE HTTP daemon on port 8080.

- [ ] **Create `templates/signal-deployment.yaml`**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: signal-cli
  namespace: hermes-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: signal-cli
  template:
    metadata:
      labels:
        app: signal-cli
    spec:
      containers:
        - name: signal-cli
          image: "{{ .Values.signalCli.image.repository }}:{{ .Values.signalCli.image.tag }}"
          env:
            - name: MODE
              value: json-rpc
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          resources: {{ toYaml .Values.signalCli.resources | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /home/.local/share/signal-cli
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: hermes-signal-data
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: second Deployment named signal-cli with MODE=json-rpc env var
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/signal-deployment.yaml
git commit -m "feat(hermes-agent): add signal-cli Deployment"
```

---

## Task 10: signal-cli Service

**Files:**

- Create: `cluster/apps/default/hermes-agent/templates/signal-service.yaml`

- [ ] **Create `templates/signal-service.yaml`**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: signal-cli
  namespace: hermes-agent
spec:
  type: ClusterIP
  selector:
    app: signal-cli
  ports:
    - name: http
      port: 8080
      targetPort: 8080
      protocol: TCP
```

- [ ] **Verify render**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent -f cluster/apps/default/hermes-agent/values.yaml
# Expected: two Services — hermes-agent:9119 and signal-cli:8080
```

- [ ] **Commit**

```bash
git add cluster/apps/default/hermes-agent/templates/signal-service.yaml
git commit -m "feat(hermes-agent): add signal-cli Service"
```

---

## Task 11: Full render and lint verification

Run the full render pipeline and lint before opening the PR.

- [ ] **Full helm template render — capture output**

```bash
helm template hermes-agent cluster/apps/default/hermes-agent \
  -f cluster/apps/default/hermes-agent/values.yaml > /tmp/hermes-render.yaml
echo "Exit: $?"
# Expected: exit 0
```

- [ ] **Count expected resource kinds**

```bash
grep "^kind:" /tmp/hermes-render.yaml | sort | uniq -c
# Expected output (order may vary):
#   2 Deployment          (hermes-agent, signal-cli)
#   1 ConfigMap           (hermes-agent-config)
#   1 ExternalSecret      (hermes-agent-secrets)
#   1 HTTPRoute           (hermes-agent)
#   2 PersistentVolumeClaim (hermes-agent-data, hermes-signal-data)
#   2 Service             (hermes-agent, signal-cli)
```

- [ ] **Run YAML lint**

```bash
task lint:yaml
# Expected: no errors
```

- [ ] **Run markdown lint (catches any doc changes)**

```bash
task lint:markdown
# Expected: no errors
```

- [ ] **Commit lint fixes if any**

```bash
git add -p
git commit -m "chore(hermes-agent): fix lint issues"
# Skip if no changes
```

---

## Task 12: Signal account linking (one-time, post-deploy)

After ArgoCD syncs and the signal-cli pod is running, link the Signal account. This step requires
the Bitwarden secret for `SIGNAL_ACCOUNT` to already be set.

- [ ] **Wait for signal-cli pod to be Running**

```bash
kubectl get pods -n hermes-agent -w
# Wait until signal-cli-<hash> shows Running
```

- [ ] **Generate the linking URI**

```bash
kubectl exec -n hermes-agent deploy/signal-cli -c signal-cli -- \
  signal-cli link -n "HermesAgent"
# Prints a QR code or tsdevice:/ URI.
# On your phone: Signal → Settings → Linked Devices → Link New Device → scan QR.
```

- [ ] **Verify the account is linked**

```bash
kubectl exec -n hermes-agent deploy/signal-cli -c signal-cli -- \
  signal-cli --account +YOUR_SIGNAL_NUMBER listAccounts
# Expected: your phone number listed as a linked account
```

- [ ] **Send a test message to the bot from your phone**

  Send a DM via Signal from a number in `SIGNAL_ALLOWED_USERS`. Check gateway logs:

```bash
kubectl logs -n hermes-agent deploy/hermes-agent -c gateway --tail=50
# Expected: log entries showing an incoming Signal message and agent response
```

---

## Task 13: Open PR

- [ ] **Push branch**

```bash
git push -u origin chore/hermes-agent
```

- [ ] **Open PR**

```bash
gh pr create \
  --title "feat: deploy hermes-agent with Signal messenger integration" \
  --body "$(cat <<'EOF'
## Summary

- Adds hermes-agent (gateway + dashboard) to cluster/apps/default
- Adds signal-cli as a separate Deployment in the same namespace
- Default LLM backend: local Ollama qwen3.5:9b
- Anthropic API key wired up (same Bitwarden entry as litellm)
- Signal messenger integration via bbernhard/signal-cli-rest-api

## Post-merge steps

1. ArgoCD syncs the app (namespace auto-created)
2. Add Bitwarden UUIDs for SIGNAL_ACCOUNT and SIGNAL_ALLOWED_USERS to externalsecret.yaml
3. Run the signal-cli account linking procedure (Task 12 in the plan)

## Test plan

- [ ] helm template renders 9 resources without errors
- [ ] ArgoCD application shows Synced/Healthy
- [ ] Dashboard accessible at hermes.<private-domain>
- [ ] Signal DM from allowed number reaches gateway (check logs)
EOF
)"
```
