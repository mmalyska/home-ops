# AI gateway (LiteLLM)

One OpenAI-compatible endpoint for every AI client in the cluster: `http://litellm.ai.svc.cluster.local:4000/v1`. The admin UI and API are on `envoy-internal` only (LAN). Clients hold a virtual key, never a provider key. App: `cluster/apps/ai/litellm`. Design and plan: `.plans/superpowers/specs/2026-10-26-ai-gateway-design.md`.

## Models

| Alias   | Backend                                            | Cost              |
| ------- | -------------------------------------------------- | ----------------- |
| `main`  | ChatGPT (Codex) subscription, see below            | none per token    |
| `cheap` | OpenRouter, `google/gemini-3.1-flash-lite`         | per token, capped |
| `local` | llama-server on nv1 (`llm` namespace)              | none              |
| `embed` | CPU llama.cpp embeddings server (nomic-embed-text) | none              |

`main` and `embed` are added in later steps of the plan; until then only `cheap` and `local` exist.

## Fallbacks and budget

- `cheap` falls back to `local`. `main` will fall back to `cheap` once it exists.
- A failed deployment is skipped for 300 s (`cooldown_time`) instead of being retried on every request.
- The pay-per-token cap is `router_settings.provider_budget_config.openrouter` in `values.yaml`: 13 USD per 30 days, about 50 zl. It is per provider on purpose: `litellm_settings.max_budget` is proxy-wide and would also block the free models.
- The cap is counted in memory, so a pod restart resets it. The prepaid OpenRouter balance is the hard ceiling.
- Alerts: `LiteLLMBudgetNearlyUsed` (under 20% left), `LiteLLMModelFailing` (over half of calls failing for 15 min). Metric names come from LiteLLM's docs; check them against `/metrics` after the first deploy.

## Virtual keys

One key per client, created with `POST /key/generate` using the master key, and kept in Bitwarden:

| Key        | Models                    |
| ---------- | ------------------------- |
| `hermes`   | `main`, `cheap`, `local`  |
| `honcho`   | `cheap`, `local`, `embed` |
| `opencode` | `main`, `cheap`, `local`  |

## main model login

Filled in when `main` is added (plan task 3): terms check, where the OAuth token is stored, and how to redo the login.
