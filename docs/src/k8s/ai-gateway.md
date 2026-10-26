# AI gateway (LiteLLM)

One OpenAI-compatible endpoint for every AI client in the cluster: `http://litellm.ai.svc.cluster.local:4000/v1`. The admin UI and API are on `envoy-internal` only (LAN). Clients hold a virtual key, never a provider key. Apps: `cluster/apps/ai/litellm-operator` (the home-operations operator, synced first) and `cluster/apps/ai/litellm` (the proxy, models, teams, database, Dragonfly, route). Each model, team and key is a resource (`LiteLLMModel`, `LiteLLMTeam`, `LiteLLMVirtualKey`), as in bjw-s `kubernetes/apps/ai`. Design and plan: `.plans/superpowers/specs/2026-10-26-ai-gateway-design.md`.

## Models

| Alias   | Backend                                            | Cost              |
| ------- | -------------------------------------------------- | ----------------- |
| `main`  | ChatGPT (Codex) subscription, see below            | none per token    |
| `cheap` | OpenRouter, `google/gemini-3.1-flash-lite`         | per token, capped |
| `local` | llama-server on nv1 (`llm` namespace)              | none              |
| `embed` | CPU llama.cpp embeddings server (nomic-embed-text) | none              |

`embed` is added in a later step of the plan.

## Fallbacks and budget

- `main` falls back to `cheap`, then `local`; `cheap` falls back to `local`.
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

`main` is the ChatGPT (Codex) subscription through LiteLLM's `chatgpt/` provider (`templates/models/main.yaml`). The model is `chatgpt/gpt-6.1-sol`; check OpenAI's Codex models page when it is retired.

- **One account:** every request uses the single login stored on the `litellm-chatgpt` PVC (`CHATGPT_TOKEN_DIR=/app/chatgpt_tokens`), whichever virtual key calls. Usage counts against that account's subscription limits.
- **No cost tracking:** LiteLLM records $0 for these models, so budgets never trigger on `main`. Fallback happens on errors (usage limit, 429), not on spend.
- **Fallbacks:** `main` to `cheap` to `local`.
- **Terms:** OpenAI has no explicit rule for using the Codex login in a self-hosted gateway, and its sanctioned route ("Sign in with ChatGPT") is approval-gated for hosted apps. This is a gray area; the account could be restricted. Anthropic's subscription is excluded for the opposite reason: its terms forbid it.
- **Single replica:** refresh tokens are single use, so `auth.json` must be writable and shared; the proxy runs one replica on a ReadWriteOnce volume.

### First login (and after revoking or losing the PVC)

The proxy cannot run the device-code flow itself, so sign in once from a terminal in the pod:

1. In ChatGPT's security settings, enable device code login for the account.
2. Run `kubectl -n ai exec -it deploy/litellm -- python -c "from litellm.llms.chatgpt.authenticator import Authenticator; Authenticator().get_access_token()"`.
3. Open the printed URL, enter the code, approve.
4. Restart the proxy by deleting the pod: `kubectl -n ai delete pod -l app.kubernetes.io/name=litellm`. `kubectl rollout restart` does nothing here, because the operator owns the pod template and drops the restart annotation. The proxy builds `main` only at startup; if it started before `auth.json` existed it skips `main` (log: "ChatGPT device-code login needs a human") and every request silently falls back to `cheap`.
5. Check with fallbacks off, so a fallback cannot hide a failure: `curl .../v1/chat/completions -d '{"model":"main","disable_fallbacks":true,...}'` must answer with `"model":"main"`. The result must still hold after another pod restart (the login lives on the PVC).

Access tokens last about ten days and are refreshed on use. To revoke: delete `auth.json` from the PVC, delete the proxy pod (step 4), and sign the session out in ChatGPT's security settings.
