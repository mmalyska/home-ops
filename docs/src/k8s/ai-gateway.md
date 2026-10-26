# AI gateway (LiteLLM)

One OpenAI-compatible endpoint for every AI client in the cluster: `http://litellm.ai.svc.cluster.local:4000/v1`. The admin UI and API are on `envoy-internal` only (LAN). Clients hold a virtual key, never a provider key. Apps: `cluster/apps/ai/litellm-operator` (the home-operations operator, synced first) and `cluster/apps/ai/litellm` (the proxy, models, teams, database, Dragonfly, route). Each model, team and key is a resource (`LiteLLMModel`, `LiteLLMTeam`, `LiteLLMVirtualKey`), as in bjw-s `kubernetes/apps/ai`. Design and plan: `.archive/.plans/superpowers/specs/2026-10-26-ai-gateway-design.md`.

## Models

| Alias   | Backend                                            | Cost              |
| ------- | -------------------------------------------------- | ----------------- |
| `main`  | ChatGPT (Codex) subscription, see below            | none per token    |
| `cheap` | OpenRouter, `google/gemini-3.1-flash-lite`         | per token, capped |
| `local` | llama-server on nv1 (`llm` namespace)              | none              |
| `embed` | CPU llama.cpp embeddings server (nomic-embed-text) | none              |

`embed` is the `LiteLLMModel` in `templates/models/embed.yaml` (768-dimension vectors; Honcho depends on the dimension).

## Fallbacks and budget

- `main` falls back to `cheap`, then `local`; `cheap` falls back to `local`.
- A failed deployment is skipped for 300 s (`cooldown_time`) instead of being retried on every request.
- The pay-per-token cap is `routerSettings.provider_budget_config.openrouter` in `templates/litellmproxy.yaml`: 13 USD per 30 days, about 50 zl. It is per provider on purpose: `litellm_settings.max_budget` is proxy-wide and would also block the free models.
- The spend counters live in a small Dragonfly (`litellm-dragonfly`), so a proxy restart does not reset the cap. Dragonfly itself has no persistence here; the prepaid OpenRouter balance is the hard ceiling.
- Alerts: `LiteLLMBudgetNearlyUsed` (under 20% left), `LiteLLMModelFailing` (over half of calls failing for 15 min).
- Dashboard: Grafana folder "AI", dashboard "AI gateway (LiteLLM)" (`cluster/apps/system/prometheus-stack/dashboards/litellm.json`, provisioned by the `ai-dashboards` ConfigMap). It shows traffic, tokens, latency, failures, fallbacks, deployment state and the OpenRouter budget. Counters restart with the proxy pod, so read it with `rate()`/`increase()`; calls made with the master key show up under team `None`.

## Teams and virtual keys

One `LiteLLMTeam` per client lives in `templates/teams.yaml`. The key itself is a `LiteLLMVirtualKey` (`proxyRef: litellm`, `proxyNamespace: ai`, `teamID`, `secretName`) kept next to the client app, so the operator writes the Secret into the client's namespace. No key is created by hand.

| Team       | Models                    |
| ---------- | ------------------------- |
| `hermes`   | `main`, `cheap`, `local`  |
| `honcho`   | `cheap`, `local`, `embed` |
| `opencode` | `main`, `cheap`, `local`  |

opencode in the Coder workspace is installed by the template startup script from a pinned GitHub release, checked against a SHA-256 in `workspace-template/main.tf` (`opencode_version`, `opencode_sha256`). It is not installed with the upstream install script. After a version bump, take the new digest from the release page and change both values together; a mismatch skips the install and the workspace still starts.

## main model login

`main` is the ChatGPT (Codex) subscription through LiteLLM's `chatgpt/` provider (`templates/models/main.yaml`). The model is `chatgpt/gpt-6.1-sol`; check OpenAI's Codex models page when it is retired.

- **One account:** every request uses the single login stored on the `litellm-chatgpt` PVC (`CHATGPT_TOKEN_DIR=/app/chatgpt_tokens`), whichever virtual key calls. Usage counts against that account's subscription limits.
- **No cost tracking:** LiteLLM records $0 for these models, so budgets never trigger on `main`. Fallback happens on errors (usage limit, 429), not on spend.
- **Fallbacks:** `main` to `cheap` to `local`.
- **Terms:** OpenAI has no explicit rule for using the Codex login in a self-hosted gateway, and its sanctioned route ("Sign in with ChatGPT") is approval-gated for hosted apps. This is a gray area; the account could be restricted. Anthropic's subscription is excluded for the opposite reason: its terms forbid it.
- **Single replica:** refresh tokens are single use, so `auth.json` must be writable and shared; the proxy runs one replica on a ReadWriteMany CephFS volume (`ceph-filesystem`), so the surge pod of a rollout can start on another node.

### First login (and after revoking or losing the PVC)

The proxy cannot run the device-code flow itself, so sign in once from a terminal in the pod:

1. In ChatGPT's security settings, enable device code login for the account.
2. Run `kubectl -n ai exec -it deploy/litellm -- python -c "from litellm.llms.chatgpt.authenticator import Authenticator; Authenticator().get_access_token()"`.
3. Open the printed URL, enter the code, approve.
4. Restart the proxy by deleting the pod: `kubectl -n ai delete pod -l app.kubernetes.io/name=litellm`. `kubectl rollout restart` does nothing here, because the operator owns the pod template and drops the restart annotation. The proxy builds `main` only at startup; if it started before `auth.json` existed it skips `main` (log: "ChatGPT device-code login needs a human") and every request silently falls back to `cheap`.
5. Check with fallbacks off, so a fallback cannot hide a failure: `curl .../v1/chat/completions -d '{"model":"main","disable_fallbacks":true,...}'` must answer with `"model":"main"`. The result must still hold after another pod restart (the login lives on the PVC).

Access tokens last about ten days and are refreshed on use. To revoke: delete `auth.json` from the PVC, delete the proxy pod (step 4), and sign the session out in ChatGPT's security settings.

## Hardening

Every workload in `ai` and `honcho` runs with `runAsNonRoot`, `allowPrivilegeEscalation: false`, a read-only root filesystem, `capabilities.drop: [ALL]` and seccomp `RuntimeDefault`, and the pods that never call the Kubernetes API have `automountServiceAccountToken: false`. The `ai` and `honcho` namespaces enforce Pod Security `restricted`; `llm` stays on `baseline`.

| Workload                       | User                  | Writable paths                                                                                   |
| ------------------------------ | --------------------- | ------------------------------------------------------------------------------------------------ |
| `litellm`                      | 65534                 | `/tmp` (emptyDir, also `HOME`), `/app/chatgpt_tokens` (CephFS, `fsGroup`)                        |
| `litellm-dragonfly`            | 999                   | none                                                                                             |
| `honcho-api`, `honcho-deriver` | 100:101 (image's own) | `/tmp`, `/app/lancedb_data` (emptyDir; pgvector is the vector store, so nothing is stored there) |
| `llm-embeddings`               | 65534                 | model volume (`fsGroup`)                                                                         |

**Exception: `llama-server` on the Jetson is not hardened.** It needs the CDI/GPU device path and runs as root; the owner decided not to touch it, so `llm` cannot move to `restricted` while it runs there.

A new workload in these namespaces has to meet the same baseline or `restricted` admission rejects it. The Honcho and embeddings entries above show the pattern to copy.

### Network policies

Cilium enforces `NetworkPolicy`. The gateway, its Postgres and Dragonfly, Honcho and its Postgres, the embeddings server and `llama-server` each have a default-deny ingress policy with explicit allows:

| Target                            | Allowed from                                                                                                            |
| --------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `litellm:4000`                    | `envoy-gateway`, `coder`, `honcho`, `hermes-agent`, `lingarr` (in `media`), the `ai` namespace (operator), `monitoring` |
| `litellm-dragonfly:6379`          | `litellm` pods; `:9999` from `dragonfly-system` and the replicas                                                        |
| `litellmdb-cnpg`, `honchodb-cnpg` | the owning app (`:5432`), the instances themselves, `cnpg`, `monitoring` (`:9187`)                                      |
| `honcho-api:8000`                 | `hermes-agent`                                                                                                          |
| `honcho-deriver`                  | nothing (queue worker)                                                                                                  |
| `llm-embeddings:8080`             | `litellm` pods in `ai`                                                                                                  |
| `llama-server:8080`               | `litellm` pods in `ai`; `monitoring` (metrics)                                                                          |

Policies select the pods above, not the whole namespace, because the `litellm-operator` pod must stay reachable by the API server for its admission webhook. There is no egress policy: the gateway has to reach OpenRouter and ChatGPT. Every model call goes through the gateway: a new client gets a team, a virtual key and an entry in the `litellm` policy, and nothing may call `llama-server` or `llm-embeddings` directly. The `llama-server` policy is ingress-only and leaves the Jetson node itself untouched. Lingarr is a client too (team `lingarr`, alias `local`); its key is entered once in the Lingarr UI (Settings, Translation, Local AI) because Lingarr stores it encrypted and ignores a plain `LOCAL_AI_API_KEY`.
