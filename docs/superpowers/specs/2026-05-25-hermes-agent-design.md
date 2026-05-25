# hermes-agent Deployment Design

**Date:** 2026-05-25  
**Status:** Approved

## Goal

Deploy [hermes-agent](https://github.com/NousResearch/hermes-agent) to the home-ops cluster with three configured
backends (local Ollama as default, Anthropic and OpenRouter as optional), dashboard accessible on the internal
ingress only, and Signal messenger as a chat interaction channel.

---

## Architecture

### Application category & location

`cluster/apps/default/hermes-agent/` — same category as `open-webui`, `litellm`, `n8n`.

### Deployment model

Single Deployment in namespace `hermes-agent` with **three containers + one init container**, sharing RWO PVCs.

```text
Pod
├── initContainer: config-seeder
│     Seeds /opt/data/config.yaml from ConfigMap if the file does not already exist.
│     Allows user to override config via the dashboard without it being reset on restart.
├── container: gateway
│     image: nousresearch/hermes-agent
│     command: ["gateway", "run"]
│     mount: /opt/data → hermes-data PVC
├── container: dashboard
│     image: nousresearch/hermes-agent
│     command: ["dashboard", "--host", "0.0.0.0", "--no-open"]
│     port: 9119
│     mount: /opt/data → hermes-data PVC
└── container: signal-cli
      image: bbernhard/signal-cli-rest-api:0.99
      env: MODE=json-rpc
      port: 8080 (localhost only — no K8s Service)
      mount: /home/.local/share/signal-cli → signal-data PVC
```

Key changes from docker-compose:

- Dashboard uses `--host 0.0.0.0` (not `127.0.0.1`) so the K8s Service can reach it.
- `signal-cli` runs as a sidecar in `MODE=json-rpc`, which exposes signal-cli's native
  JSON-RPC/SSE HTTP daemon on port 8080 — exactly the interface hermes-agent's Signal adapter
  expects. Gateway reaches it via `http://localhost:8080`.

---

## File Layout

```text
cluster/apps/default/hermes-agent/
├── app-config.yaml           # ArgoCD ApplicationSet entry
├── Chart.yaml                # Local chart, no upstream dependency
├── values.yaml               # Image tags, resources, hostname token
└── templates/
    ├── deployment.yaml       # Three-container pod + init container
    ├── service.yaml          # ClusterIP, port 9119
    ├── pvc.yaml              # 1Gi RWO for /opt/data (hermes)
    ├── signal-pvc.yaml       # 1Gi RWO for signal-cli account data
    ├── configmap.yaml        # Seed config.yaml
    ├── externalsecret.yaml   # API keys + Signal secrets
    └── httproute.yaml        # envoy-internal → service:9119
```

---

## Configuration

### Provider & default model

`config.yaml` is seeded by the init container from the ConfigMap:

```yaml
model:
  provider: "ollama"        # maps to "custom" — local in-cluster Ollama
  default: "qwen3.5:9b"    # model already pulled in ha-ollama namespace
  base_url: "http://ollama.ha-ollama.svc.cluster.local:11434/v1"
```

The user can switch providers (to Anthropic or OpenRouter) via the dashboard. Switching persists in the PVC and survives restarts (the init container only seeds if the file is absent).

### Environment variables (all containers)

**hermes-agent containers (gateway + dashboard):**

| Variable              | Source                         | Notes                           |
| --------------------- | ------------------------------ | ------------------------------- |
| `ANTHROPIC_API_KEY`   | ExternalSecret                 | Same Bitwarden UUID as litellm  |
| `OPENROUTER_API_KEY`  | ExternalSecret (commented out) | Add Bitwarden UUID to enable    |
| `OLLAMA_BASE_URL`     | Plain env var                  | In-cluster Ollama endpoint      |
| `SIGNAL_HTTP_URL`     | Plain env var                  | `http://localhost:8080`         |
| `SIGNAL_ACCOUNT`      | ExternalSecret                 | Phone number in E.164 format    |
| `SIGNAL_ALLOWED_USERS`| ExternalSecret                 | Comma-separated E.164 numbers   |

**signal-cli container:**

| Variable | Source        | Notes                                      |
| -------- | ------------- | ------------------------------------------ |
| `MODE`   | Plain env var | `json-rpc` — enables native JSON-RPC daemon|

---

## Secrets

**ExternalSecret** `hermes-agent-secrets` using `ClusterSecretStore: bitwarden`:

- `ANTHROPIC_API_KEY` → Bitwarden UUID `b4f5ae0d-6b2e-44bc-85ee-b409016935b1` (same as litellm)
- `OPENROUTER_API_KEY` → **commented out**; add your Bitwarden UUID and uncomment to enable
- `SIGNAL_ACCOUNT` → new Bitwarden entry (UUID TBD); phone number in E.164 format, e.g. `+48...`
- `SIGNAL_ALLOWED_USERS` → new Bitwarden entry (UUID TBD); comma-separated E.164 numbers allowed
  to message the bot

Secret mechanism choice: ExternalSecret (not `cluster-secrets` plugin) because these values land in K8s `Secret data` fields and are injected as pod env vars.

---

## Networking

- **Service**: `ClusterIP`, name `hermes-agent`, port `9119 → 9119`, namespace `hermes-agent`
- **HTTPRoute**: hostname `hermes.<secret:private-domain>` → `envoy-internal` gateway (sectionName: `https`)
  - Annotation: `external-dns.alpha.kubernetes.io/controller: dns-controller`
  - Backend: `hermes-agent:9119`
- **`app-config.yaml`**: `SECRET_PROVIDER: cluster-secrets` to resolve `<secret:private-domain>` token in the HTTPRoute

Dashboard is internal-only (no `envoy-external` parent ref).

---

## Storage

- **PVC `hermes-agent-data`**: `1Gi`, `ReadWriteOnce`, mounted at `/opt/data` in gateway, dashboard,
  and init containers. Stores: conversation history, agent profiles, `config.yaml`, tool state.
- **PVC `hermes-signal-data`**: `1Gi`, `ReadWriteOnce`, mounted at `/home/.local/share/signal-cli`
  in the signal-cli container. Stores: Signal account credentials and session keys.
  Must be populated via the one-time linking procedure before the gateway can receive messages.

---

## ArgoCD

- `app-config.yaml` fields: `enabled: "true"`, `namespace: hermes-agent`, `syncPolicy.selfHeal: true`, `syncPolicy.prune: false`
- `plugin.env.SECRET_PROVIDER: cluster-secrets` for hostname token substitution
- No `syncWave` override needed (default wave)

---

## Signal Integration

### How it works

hermes-agent's Signal adapter connects to `signal-cli` running in HTTP daemon mode. It streams
incoming messages via SSE and sends responses via JSON-RPC. The sidecar makes signal-cli available
at `http://localhost:8080` — no K8s Service or NetworkPolicy needed.

### One-time account linking (manual, run once before first deploy)

Signal-cli must be linked as a secondary device on a phone number before the pod can receive
messages. This is done **outside the cluster** by exec-ing into the signal-cli container after its
first start:

```bash
# 1. After first deploy, exec into the signal-cli sidecar
kubectl exec -n hermes-agent deploy/hermes-agent -c signal-cli -- \
  signal-cli link -n "HermesAgent"

# 2. This prints a QR code / linking URI.
#    On your phone: Signal → Settings → Linked Devices → Link New Device → scan QR.

# 3. Verify the link
kubectl exec -n hermes-agent deploy/hermes-agent -c signal-cli -- \
  signal-cli --account +YOUR_NUMBER listAccounts
```

Once linked, the account credentials are persisted in `hermes-signal-data` PVC and survive pod
restarts. Re-linking is only needed if the PVC is deleted or the phone number changes.

### signal-cli image

`bbernhard/signal-cli-rest-api:0.99` with `MODE=json-rpc` runs signal-cli's native JSON-RPC/SSE
HTTP daemon on port 8080. This is the interface hermes-agent's Signal adapter uses directly.

Pin with manifest digest in `values.yaml`:

```yaml
tag: "0.99@sha256:96578363477d97cb1d8da303791b2ad686b374a255fce4d78c7c6f00ef56cba8"
```

Renovate's `helm-values` manager will track digest updates for this tag.

### Access control

Set `SIGNAL_ALLOWED_USERS` to a comma-separated list of E.164 phone numbers that are permitted to
message the bot. Without it, hermes denies all incoming DMs (safe default). Group messages are
disabled unless `SIGNAL_GROUP_ALLOWED_USERS` is also configured (not included in initial deploy).

---

- User must create a Bitwarden secret for `OPENROUTER_API_KEY` and add its UUID to `externalsecret.yaml` to enable OpenRouter.
- User must create Bitwarden secrets for `SIGNAL_ACCOUNT` (phone number) and `SIGNAL_ALLOWED_USERS`
  and add their UUIDs to `externalsecret.yaml` before deploying.
- After first deploy, run the one-time account linking procedure (see Signal Integration section).
- Image: `nousresearch/hermes-agent` only publishes to Docker Hub (no GHCR mirror). The image uses a
  rolling `main` tag (no semver releases). Pin with a digest in `values.yaml`:

  ```yaml
  tag: "main@sha256:d0ecd9a002707d03ad9ef2869226503318bfe773f08df6c83e6b4b38e37f3175"
  ```

  Renovate's `helm-values` manager (matches `cluster/**/*.yaml`) tracks the digest and will open a
  PR when `main` moves to a new commit.
