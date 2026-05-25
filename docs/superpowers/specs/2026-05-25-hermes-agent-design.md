# hermes-agent Deployment Design

**Date:** 2026-05-25  
**Status:** Approved

## Goal

Deploy [hermes-agent](https://github.com/NousResearch/hermes-agent) to the home-ops cluster with three configured
backends (local Ollama as default, Anthropic and OpenRouter as optional), dashboard accessible on the internal
ingress only.

---

## Architecture

### Application category & location

`cluster/apps/default/hermes-agent/` — same category as `open-webui`, `litellm`, `n8n`.

### Deployment model

Single Deployment in namespace `hermes-agent` with **two containers + one init container**, sharing a single RWO PVC.

```text
Pod
├── initContainer: config-seeder
│     Seeds /opt/data/config.yaml from ConfigMap if the file does not already exist.
│     Allows user to override config via the dashboard without it being reset on restart.
├── container: gateway
│     image: nousresearch/hermes-agent
│     command: ["gateway", "run"]
│     mount: /opt/data → PVC
└── container: dashboard
      image: nousresearch/hermes-agent
      command: ["dashboard", "--host", "0.0.0.0", "--no-open"]
      port: 9119
      mount: /opt/data → PVC
```

Key change from docker-compose: dashboard uses `--host 0.0.0.0` (not `127.0.0.1`) so the K8s Service can reach it.

---

## File Layout

```text
cluster/apps/default/hermes-agent/
├── app-config.yaml           # ArgoCD ApplicationSet entry
├── Chart.yaml                # Local chart, no upstream dependency
├── values.yaml               # Image tag, resources, hostname token
└── templates/
    ├── deployment.yaml       # Two-container pod + init container
    ├── service.yaml          # ClusterIP, port 9119
    ├── pvc.yaml              # 1Gi RWO for /opt/data
    ├── configmap.yaml        # Seed config.yaml
    ├── externalsecret.yaml   # ANTHROPIC_API_KEY (+ optional OPENROUTER_API_KEY)
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

| Variable            | Source                        | Notes                           |
| ------------------- | ----------------------------- | ------------------------------- |
| `ANTHROPIC_API_KEY` | ExternalSecret                | Same Bitwarden UUID as litellm  |
| `OPENROUTER_API_KEY`| ExternalSecret (commented out)| Add Bitwarden UUID to enable    |
| `OLLAMA_BASE_URL`   | Plain env var                 | In-cluster Ollama endpoint      |

---

## Secrets

**ExternalSecret** `hermes-agent-secrets` using `ClusterSecretStore: bitwarden`:

- `ANTHROPIC_API_KEY` → Bitwarden UUID `b4f5ae0d-6b2e-44bc-85ee-b409016935b1` (same as litellm)
- `OPENROUTER_API_KEY` → **commented out**; add your Bitwarden UUID and uncomment to enable

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

- **PVC**: `hermes-agent-data`, `1Gi`, `ReadWriteOnce`
- Mounted at `/opt/data` in gateway, dashboard, and init containers
- Stores: conversation history, agent profiles, `config.yaml` (user-editable), tool state

---

## ArgoCD

- `app-config.yaml` fields: `enabled: "true"`, `namespace: hermes-agent`, `syncPolicy.selfHeal: true`, `syncPolicy.prune: false`
- `plugin.env.SECRET_PROVIDER: cluster-secrets` for hostname token substitution
- No `syncWave` override needed (default wave)

---

## Open Items

- User must create a Bitwarden secret for `OPENROUTER_API_KEY` and add its UUID to `externalsecret.yaml` to enable OpenRouter.
- Image: `nousresearch/hermes-agent` only publishes to Docker Hub (no GHCR mirror). The image uses a
  rolling `main` tag (no semver releases). Pin with a digest in `values.yaml`:

  ```yaml
  tag: "main@sha256:d0ecd9a002707d03ad9ef2869226503318bfe773f08df6c83e6b4b38e37f3175"
  ```

  Renovate's `helm-values` manager (matches `cluster/**/*.yaml`) tracks the digest and will open a
  PR when `main` moves to a new commit.
