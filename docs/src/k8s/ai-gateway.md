# AI gateway (LiteLLM)

One OpenAI-compatible endpoint for every AI client in the cluster: `http://litellm.ai.svc.cluster.local:4000/v1`. The admin UI and API are on `envoy-internal` only (LAN). Clients hold a virtual key, never a provider key. Apps: `cluster/apps/ai/litellm-operator` (the home-operations operator, synced first) and `cluster/apps/ai/litellm` (the proxy, models, teams, database, Dragonfly, route). Each model, team and key is a resource (`LiteLLMModel`, `LiteLLMTeam`, `LiteLLMVirtualKey`), as in bjw-s `kubernetes/apps/ai`. Design and plan: `.plans/superpowers/specs/2026-10-26-ai-gateway-design.md`.

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
- The pay-per-token cap is `routerSettings.provider_budget_config.openrouter` in `templates/litellmproxy.yaml`: 13 USD per 30 days, about 50 zl. It is per provider on purpose: `litellm_settings.max_budget` is proxy-wide and would also block the free models.
- The spend counters live in a small Dragonfly (`litellm-dragonfly`), so a proxy restart does not reset the cap. Dragonfly itself has no persistence here; the prepaid OpenRouter balance is the hard ceiling.
- Alerts: `LiteLLMBudgetNearlyUsed` (under 20% left), `LiteLLMModelFailing` (over half of calls failing for 15 min). Metric names come from LiteLLM's docs; check them against `/metrics` after the first deploy.

## Teams and virtual keys

One `LiteLLMTeam` per client lives in `templates/teams.yaml`. The key itself is a `LiteLLMVirtualKey` (`proxyRef: litellm`, `proxyNamespace: ai`, `teamID`, `secretName`) kept next to the client app, so the operator writes the Secret into the client's namespace. No key is created by hand.

| Team       | Models                    |
| ---------- | ------------------------- |
| `hermes`   | `main`, `cheap`, `local`  |
| `honcho`   | `cheap`, `local`, `embed` |
| `opencode` | `main`, `cheap`, `local`  |

## main model login

Filled in when `main` is added (plan task 3): terms check, the token PVC (`CHATGPT_TOKEN_DIR`), and how to redo the login.
