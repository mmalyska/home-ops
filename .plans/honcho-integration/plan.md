# Honcho Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a self-hosted Honcho memory server and wire hermes-agent to use it as a persistent cross-session memory provider across all 7 Hermes profiles.

**Architecture:** New `cluster/apps/default/honcho/` Helm chart deploys Honcho API + Deriver as two Deployments, backed by CloudNativePG (pgvector-enabled standard image) in the `honcho` namespace. Hermes-agent gains `memory.provider: honcho` via the existing config-seeder, plus a new `honcho-seeder` init-container that deep-merges `honcho.json` onto the data PVC at `/opt/data/.hermes/honcho.json`.

**Tech Stack:** `ghcr.io/plastic-labs/honcho:v3.0.7` (GHCR published), CNPG `ghcr.io/cloudnative-pg/postgresql:17.6-standard-bookworm` (bundles pgvector), ESO + Bitwarden for secrets, existing `charts/pgsql-cnpg` subchart, OpenRouter via `LLM_OPENAI_API_KEY`.

---

## Phase 0 Research Summary

### Honcho server

- **Image**: `ghcr.io/plastic-labs/honcho:v3.0.7` on GHCR ✅
- **API container**: command `["sh", "docker/entrypoint.sh"]` → runs `scripts/provision_db.py` (alembic migrations) then starts FastAPI. Migrations are idempotent; run on every API restart.
- **Deriver container**: command `["/app/.venv/bin/python", "-m", "src.deriver"]` — background reasoning worker, separate Deployment.
- **DB**: PostgreSQL + pgvector mandatory (vector search). Use CNPG standard image `17.6-standard-bookworm` + `bootstrap.initdb.postInitApplicationSQL: ["CREATE EXTENSION IF NOT EXISTS vector"]`.
- **Redis**: Optional. Start with `CACHE_ENABLED=false`.
- **Migrations**: Handled by `docker/entrypoint.sh` before API starts (no separate Job needed).

### Database connection string

- CNPG creates k8s Secret `honchodb-cnpg-app` with `username` and `password` (alphanumeric, URL-safe).
- Use Kubernetes dependent env vars to build `DB_CONNECTION_URI`:
  ```
  DB_USER  ← secretKeyRef honchodb-cnpg-app/username
  DB_PASS  ← secretKeyRef honchodb-cnpg-app/password
  DB_CONNECTION_URI = "postgresql+psycopg://$(DB_USER):$(DB_PASS)@honchodb-cnpg-rw.honcho.svc.cluster.local:5432/app"
  ```

### LLM provider: OpenRouter (new dedicated key)

- New Bitwarden entry for OpenRouter key (separate from hermes-agent's key, for usage tracking).
- No global base URL env var in Honcho — must set `*__OVERRIDES__BASE_URL` per module.
- Modules: DERIVER, SUMMARY, EMBEDDING, 5 DIALECTIC levels (`DIALECTIC_LEVELS__{level}__MODEL_CONFIG__*`), DREAM (deduction + induction) = 10 modules × 3 env vars each.
- Models to use via OpenRouter (all `transport: openai`):

| Module                | Model                           | Reasoning                           |
| --------------------- | ------------------------------- | ----------------------------------- |
| DERIVER               | `google/gemini-flash-1.5`       | Cheap background worker             |
| SUMMARY               | `google/gemini-flash-1.5`       | Cheap summarisation                 |
| EMBEDDING             | `openai/text-embedding-3-small` | Standard embeddings via OpenRouter  |
| DIALECTIC minimal/low | `google/gemini-flash-1.5`       | Cost-efficient (default level used) |
| DIALECTIC medium      | `google/gemini-2.0-flash`       | Moderate quality                    |
| DIALECTIC high        | `anthropic/claude-3-5-haiku`    | High quality                        |
| DIALECTIC max         | `anthropic/claude-3-5-sonnet`   | Maximum quality                     |
| DREAM deduction       | `google/gemini-flash-1.5`       | Background consolidation            |
| DREAM induction       | `google/gemini-flash-1.5`       | Background consolidation            |

### hermes-agent profiles

Profiles are **imperative/stateful** (NOT declared in Helm). From README: `default`, `orchestrator`, `devops`, `researcher`, `dotnet-dev`, `node-dev`, `mobile-dev`.

Honcho host key mapping:

- `default` → `"hermes"` (aiPeer: `"hermes"`)
- `orchestrator` → `"hermes.orchestrator"` (aiPeer: `"orchestrator"`)
- `devops` → `"hermes.devops"` (aiPeer: `"devops"`)
- `researcher` → `"hermes.researcher"` (aiPeer: `"researcher"`)
- `dotnet-dev` → `"hermes.dotnet-dev"` (aiPeer: `"dotnet-dev"`)
- `node-dev` → `"hermes.node-dev"` (aiPeer: `"node-dev"`)
- `mobile-dev` → `"hermes.mobile-dev"` (aiPeer: `"mobile-dev"`)

### honcho.json delivery

- Target path: `/opt/data/.hermes/honcho.json` (on PVC `hermes-agent-data`)
- Strategy: **deep-merge** (ConfigMap overrides propagate; runtime additions from `hermes honcho sync` are preserved across restarts)
- Init-container `honcho-seeder`: uses hermes-agent image (has Python 3), runs a JSON deep-merge script identical in shape to the existing `config-seeder`

### S3 backup: enabled

Same S3 bucket and credentials as litellm (`k8s-at-home-backup`). Reuse same Bitwarden entries:

- `S3_ACCESS_KEY_ID`: `e00e1e38-ae37-479a-8b46-b409016331eb`
- `S3_ACCESS_SECRET_KEY`: `4d5a418c-82ed-4b8e-bfbf-b40901634ea4`

---

## File Map

### New: `cluster/apps/default/honcho/`

| File                                | Purpose                                                                               |
| ----------------------------------- | ------------------------------------------------------------------------------------- |
| `app-config.yaml`                   | ArgoCD ApplicationSet config, `namespace: honcho`, `SECRET_PROVIDER: cluster-secrets` |
| `Chart.yaml`                        | Local chart with `pgsql-cnpg` v1.2.0 dependency                                       |
| `values.yaml`                       | Image tag, resources, LLM env config, CNPG + S3 backup                                |
| `templates/externalsecret.yaml`     | `honcho-secrets`: OpenRouter key + S3 creds from Bitwarden                            |
| `templates/deployment-api.yaml`     | Honcho API Deployment                                                                 |
| `templates/deployment-deriver.yaml` | Honcho Deriver Deployment                                                             |
| `templates/service.yaml`            | ClusterIP Service port 8000                                                           |

### Modified: `cluster/apps/default/hermes-agent/values.yaml`

Add `memory.provider: honcho` under `hermes.config:`.

### New: `cluster/apps/default/hermes-agent/templates/honcho-configmap.yaml`

ConfigMap `hermes-agent-honcho` containing `honcho.json` with all 7 profile host blocks and tuning settings.

### Modified: `cluster/apps/default/hermes-agent/templates/deployment.yaml`

Add `honcho-seeder` init-container (after `config-seeder`) + `honcho-config` volume.

---

## Architecture Decisions

| Decision           | Choice                                       | Reason                                                                        |
| ------------------ | -------------------------------------------- | ----------------------------------------------------------------------------- |
| Two Deployments    | api + deriver                                | Different commands, restart policies                                          |
| pgvector           | CNPG standard image + postInitApplicationSQL | No custom image needed                                                        |
| Migrations         | Via entrypoint.sh on every API start         | Idempotent, matches upstream docker-compose                                   |
| Connection string  | K8s dependent env vars                       | Simple, CNPG passwords are alphanumeric                                       |
| Redis              | Disabled initially                           | Reduces deployment scope; can be added if latency is visible                  |
| LLM provider       | OpenRouter (new key)                         | Reuse OpenRouter account; separate key = isolated billing                     |
| honcho.json seeder | Deep-merge (Python in hermes-agent image)    | Preserves `hermes honcho sync` additions; ConfigMap values stay authoritative |
| Auth               | `AUTH_USE_AUTH=false`                        | ClusterIP only, never exposed outside cluster                                 |
| All 7 profiles     | Declared in initial honcho.json              | Avoids manual `hermes honcho sync` step; profiles match README                |

## Risks

| Risk                                          | Mitigation                                                                                                                             |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `honcho-ai` lazy-install fails on pod restart | Reinstalls on first use from PyPI (intended behavior per upstream). Monitor `hermes honcho status`.                                    |
| CNPG pgvector extension not found             | Standard image bundles pgvector; check CNPG pod logs if extension fails.                                                               |
| Deriver starts before DB is ready             | Deriver retries automatically; no ordering dependency needed.                                                                          |
| OpenRouter model names change                 | Pin exact model strings; update values.yaml if a model is deprecated.                                                                  |
| Embeddings not available via OpenRouter       | If `text-embedding-3-small` is unavailable via OpenRouter, add `LLM_OPENAI_API_KEY` pointing to real OpenAI for EMBEDDING module only. |
