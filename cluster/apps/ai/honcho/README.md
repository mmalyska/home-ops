# Honcho — Self-Hosted Memory Server

[Honcho](https://github.com/plastic-labs/honcho) v3 deployed as a self-hosted memory server in the `honcho` namespace, providing persistent cross-session user memory for hermes-agent via Theory-of-Mind (ToM) reasoning and vector recall.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                   namespace: honcho                       │
│                                                          │
│  ┌──────────────────┐      ┌───────────────────────────┐ │
│  │  honcho-api      │      │  honcho-deriver           │ │
│  │  :8000           │      │  (background worker)      │ │
│  │  FastAPI +       │      │  python -m src.deriver    │ │
│  │  migrations      │      │                           │ │
│  └────────┬─────────┘      └────────────┬──────────────┘ │
│           │                             │                 │
│           └──────────────┬──────────────┘                 │
│                          ▼                               │
│              ┌───────────────────────┐                   │
│              │  honchodb (CNPG)      │                   │
│              │  PostgreSQL 17        │                   │
│              │  + pgvector ext       │                   │
│              │  2 replicas, 5Gi      │                   │
│              └───────────────────────┘                   │
└──────────────────────────────────────────────────────────┘
        ▲
        │  http://honcho.honcho.svc.cluster.local:8000
        │
┌───────┴───────────────────────────────────────────────────┐
│  namespace: hermes-agent                                   │
│  hermes-agent pod (honcho-seeder init → /opt/data/.hermes/│
│  honcho.json, memory.provider: honcho in config.yaml)     │
└───────────────────────────────────────────────────────────┘
```

| Component | Purpose |
|-----------|---------|
| **honcho-api** | REST API (`docker/entrypoint.sh` → alembic migrations + FastAPI on :8000). Migrations are idempotent and run on every start. |
| **honcho-deriver** | Background Theory-of-Mind worker. Reads sessions queued by the API and derives user facts into the vector store. |
| **honchodb (CNPG)** | CloudNativePG PostgreSQL 17 cluster with `pgvector` extension (standard bookworm image). Two replicas; S3 barman backup daily at 00:10. |
| **ExternalSecret `honcho-secrets`** | Pulls OpenRouter API key + S3 credentials from Bitwarden via ESO. |
| **Service `honcho`** | ClusterIP, port 8000. DNS: `honcho.honcho.svc.cluster.local:8000`. Not exposed outside the cluster (no HTTPRoute). |

## LLM Model Strategy

Honcho runs 9 distinct LLM module slots. All route through OpenRouter (`openai` transport) except embeddings.

### Primary / Fallback

Every module has a free-tier primary and a paid fallback. The fallback activates automatically on the **final retry attempt** — which covers 429 rate-limit exhaustion without any manual intervention.

| Module | Primary | Fallback |
|--------|---------|---------|
| Deriver | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Summary | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dream deduction | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dream induction | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dialectic minimal | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dialectic low | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dialectic medium | `deepseek/deepseek-v4-flash:free` (free) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dialectic high | `qwen/qwen3-235b-a22b-2507` ($0.071/$0.10) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |
| Dialectic max | `qwen/qwen3-235b-a22b-2507` ($0.071/$0.10) | `deepseek/deepseek-v4-flash` ($0.10/$0.20) |

Prices are per 1M input/output tokens.

### Embeddings

Embeddings use **Ollama** (already in cluster, CPU-only) to avoid OpenRouter's lack of embedding endpoint support:

- **Model**: `nomic-embed-text` (274 MB, 768 dimensions, fast on CPU)
- **Endpoint**: `http://ollama.ha-ollama.svc.cluster.local:11434/v1`
- **Cost**: free (local inference)
- **Dimensions**: `EMBEDDING_VECTOR_DIMENSIONS=768`, `DIMENSIONS_MODE=never` (Ollama ignores the dimensions parameter)

`nomic-embed-text` is included in Ollama's pull list via `cluster/apps/home-automation/ollama/values.yaml`.

## Secrets

| Secret key | Source (Bitwarden ID) | Used for |
|------------|----------------------|---------|
| `HONCHO_OPENROUTER_API_KEY` | `7ece641d-8f3e-42f6-b306-b45900a618ad` | All LLM calls via OpenRouter |
| `S3_ACCESS_KEY_ID` | `e00e1e38-ae37-479a-8b46-b409016331eb` | CNPG S3 backup |
| `S3_ACCESS_SECRET_KEY` | `4d5a418c-82ed-4b8e-bfbf-b40901634ea4` | CNPG S3 backup |

All secrets are provisioned by `ExternalSecret honcho-secrets` (ESO + `ClusterSecretStore bitwarden`). The CNPG operator additionally creates `honchodb-cnpg-app` automatically with `username` and `password` for the database connection.

## CNPG Database

- **Image**: `ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm` — bundles pgvector, no custom image needed
- **Extension**: `CREATE EXTENSION IF NOT EXISTS vector` runs via `bootstrap.initdb.postInitApplicationSQL` on cluster creation
- **Connection**: `DB_CONNECTION_URI` is built at runtime from `$(DB_USER):$(DB_PASS)` via Kubernetes dependent env vars (CNPG passwords are alphanumeric, URL-safe)
- **Backup**: barman to `s3://k8s-at-home-backup/cnpg/honcho` daily at 00:10, 10-day retention. `<secret:s3_endpoint>` resolved at sync time via `cluster-secrets` plugin.

## Helm Values (`values.yaml`)

| Key | Purpose |
|-----|---------|
| `honcho.image` | API + deriver image (`ghcr.io/plastic-labs/honcho:v3.0.7`) |
| `honcho.resources` | API container CPU/memory |
| `honcho.deriver.resources` | Deriver container CPU/memory |
| `openrouterBwsId` | Bitwarden secret ID for the OpenRouter API key |
| `pgsql-cnpg.*` | CloudNativePG cluster config (replicas, storage, backup, pgvector bootstrap) |

LLM module configuration lives entirely in `templates/_helpers.tpl` (`honcho.llmEnv` helper) — not in `values.yaml` — since the env var matrix is too large to template usefully.

## hermes-agent Integration

hermes-agent connects to Honcho via two additions applied at pod start by init containers:

1. **`config-seeder`** merges `memory.provider: honcho` into `/opt/data/config.yaml`
2. **`honcho-seeder`** deep-merges the `hermes-agent-honcho` ConfigMap into `/opt/data/.hermes/honcho.json`

The `honcho.json` declares all 7 Hermes profiles as Honcho hosts:

| Honcho host key | Hermes profile | aiPeer | workspace |
|----------------|----------------|--------|-----------|
| `hermes` | default | `hermes` | `hermes` |
| `hermes.orchestrator` | orchestrator | `orchestrator` | `hermes` |
| `hermes.devops` | devops | `devops` | `hermes` |
| `hermes.researcher` | researcher | `researcher` | `hermes` |
| `hermes.dotnet-dev` | dotnet-dev | `dotnet-dev` | `hermes` |
| `hermes.node-dev` | node-dev | `node-dev` | `hermes` |
| `hermes.mobile-dev` | mobile-dev | `mobile-dev` | `hermes` |

All profiles share `peerName: mmalyska` and `workspace: hermes`. Deep-merge strategy means `hermes honcho sync` additions to `honcho.json` survive pod restarts while ConfigMap changes propagate on next restart.

## Post-Deploy Validation

```bash
# All pods running
kubectl -n honcho get pods

# API health
kubectl -n honcho exec deploy/honcho-api -- curl -s http://localhost:8000/health

# pgvector extension present
kubectl -n honcho exec honchodb-cnpg-1 -- psql -U app app -c \
  "SELECT extname FROM pg_extension WHERE extname='vector';"

# honcho.json seeded onto hermes-agent PVC
kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- \
  cat /opt/data/.hermes/honcho.json

# Memory provider active (in Discord/Signal)
# hermes honcho status
```

## Maintenance

### Viewing Logs

```bash
# API (migrations + FastAPI)
kubectl logs deploy/honcho-api -n honcho --tail=100

# Deriver (background memory worker)
kubectl logs deploy/honcho-deriver -n honcho --tail=100 -f
```

### Updating the Image

Edit `values.yaml` → bump `honcho.image.tag` → commit → ArgoCD syncs both deployments.

### Checking CNPG Cluster Status

```bash
kubectl -n honcho get cluster honchodb-cnpg
kubectl -n honcho get pods -l cnpg.io/cluster=honchodb-cnpg
```

### Tuning Memory Behaviour

Edit `cluster/apps/default/hermes-agent/templates/honcho-configmap.yaml` and adjust:

- `dialecticCadence` — how often deep memory recall runs (default: every 2 messages)
- `contextCadence` — how often context is injected (default: every message)
- `dialecticDepth` — reasoning depth (1 = shallow, 2+ = more thorough but slower)
- `observationMode` / `recallMode` — observation and recall strategies

Changes take effect on the next hermes-agent pod restart (the `honcho-seeder` re-merges the ConfigMap).
