# AI gateway (LiteLLM) design

Date: 2026-10-26. Status: draft, awaiting approval.

## Intent and why

The Jetson (nv1) only fits small models, so answers were slow and poor. Pay-per-token API prices for top models are too high, and the Anthropic Pro subscription cannot be used by agents (Terms of Service). Hermes was archived on 2026-10-21 for exactly this reason (`.archive/cluster/ai/README.md`).

The owner uses AI daily and wants to move to a ChatGPT (Codex) subscription as the main model, with a cheap pay-per-token model as automatic fallback, inside a hard 50 zl/month budget for pay-per-token usage. The Anthropic Pro subscription (10 months left) will not be extended.

Put one gateway (LiteLLM) in the cluster as the single OpenAI-compatible endpoint, so clients never hold provider keys, spend is capped in one place, and models can be swapped without touching clients.

## Goals

- LiteLLM in the cluster with a Postgres database (CNPG, as other apps do), reachable in-cluster and on the LAN through `envoy-internal` only.
- Model aliases clients use, e.g. `main` and `cheap`, `embed`, `local`:
  - `main`: ChatGPT subscription via LiteLLM's ChatGPT provider (OAuth).
  - `cheap`: one pay-per-token model; when `main` fails (usage limit, rate limit, error) LiteLLM falls back to it automatically. The owner chose automatic fallback.
  - `embed`: the CPU llama.cpp embeddings server (restored from archive) for Honcho.
  - `local`: llama-server on nv1, for small background jobs (Hermes housekeeping, summarizing) where quality matters little.
- Hard monthly budget of 50 zl (converted to the provider's billing currency) on pay-per-token spend, enforced by LiteLLM; one virtual key per client with its own limit.
- Clients moved onto the gateway: restored Hermes, restored Honcho (Hermes memory), and opencode in Coder workspaces.
- Metrics scraped by Prometheus and an alert when budget use passes a threshold.

## Non-goals

- Not using the Anthropic subscription anywhere (blocked by its Terms of Service).
- No public exposure of the gateway; no external HTTPRoute.
- Not restoring speech-to-text/text-to-speech or other archived Hermes extras unless needed.
- Not replacing llama-server for Lingarr; it keeps working as is.
- The owner's JetBrains AI subscription (assumed: Junie, the IDE coding agent) stays an IDE-side tool on JetBrains' own quota; it is not routed through the gateway.

## Anti-goals (failure even if it works)

- Spend above the 50 zl budget without a hard stop.
- Provider keys, OAuth tokens or the master key committed to git or readable in manifests.
- Hermes or opencode silently stuck on a failing `main` with no fallback.
- Anonymous access to the gateway admin UI.

## Constraints

- GitOps via ArgoCD, app layout and secrets rules from `CLAUDE.md` (ExternalSecret for credentials, requests and memory limit on every container, no CPU limit).
- Hermes rejects models with under 64K context per slot; `local` on nv1 meets that today (`-c 65536 -np 1`), but only one request is served at a time.
- nv1 memory is tight (see memory notes); nothing new may be scheduled there.
- The ChatGPT provider needs an OAuth login that survives pod restarts; where its token is stored and how it is first obtained are open questions for the builder to verify.
- Whether OpenAI's terms allow subscription use through a gateway must be checked before relying on it.

## Decided by the owner

- Main model: ChatGPT (Codex) subscription, supported in LiteLLM (owner's statement).
- Fallback when the subscription limit is hit: automatically a cheap pay-per-token model.
- Budget: 50 zl/month for AI, pay-per-token side.
- The owner has existing OpenRouter credits; OpenRouter is the provider for `cheap` (and any other pay-per-token model). The credits do not expire and are extra on top of the 50 zl/month (owner's statement). The balance is not yet known.
- Fallback chain: `main` first, then `cheap` on OpenRouter. If the budget is used up, `main` keeps working (it costs nothing per token) and the gateway falls back to `local`.
- The owner wants to free resources on the Jetson: OpenRouter credits could replace `local` as the fallback, or `local` could become a lighter model. This is open (see below).
- The owner will do the one-time ChatGPT sign-in with me during step 1.
- Clients: Hermes with Honcho memory, and opencode in Coder workspaces.

## Builder's choices (my calls, not agreed with the owner)

- Use the home-operations LiteLLM operator (`oci://ghcr.io/home-operations/charts/litellm-operator`), as in the bjw-s home-ops repo, instead of one big `proxy_config`: the proxy, each model, each team and each virtual key are Kubernetes resources. This was the owner's decision on PR 5927; it replaces my earlier call to skip the operator.
- Budget counters: LiteLLM keeps provider-budget spend in memory unless Redis is set, so a restart resets the cap. The cluster already has `dragonfly-operator`; add a small Dragonfly instance for LiteLLM so the cap survives restarts (builder's call, to confirm with the owner).
- Namespace `ai`; new app `cluster/apps/ai/litellm`.
- Restore Hermes and Honcho from `.archive/cluster/ai/` in a second step, after the gateway works.
- Pick the cheap pay-per-token model (a DeepSeek or Gemini Flash class model) by price and quality at build time; it is served through OpenRouter, using the owner's credits.
- If the ChatGPT-subscription check fails (terms or LiteLLM support), stop and ask the owner before choosing another `main`.
- The Jetson model (my call, to be confirmed by measuring): keep the current model while Lingarr depends on it. Benchmark a lighter model for `local` (housekeeping, summaries, translation) and switch only if quality holds. Freed memory is a goal, not a requirement.
- Budget mechanics: LiteLLM budgets are in USD, so use a fixed USD figure close to 50 zl, reviewed when the exchange rate moves a lot. The cap applies only to pay-per-token models (`cheap`); `main`, `embed` and `local` cost nothing per token and are not counted. OpenRouter credits are prepaid, so the credit balance is a second, provider-side ceiling.
- `main` failure and retry: any error, rate-limit or usage-limit response triggers the fallback; a failed `main` goes into a cooldown (minutes, not seconds) so it is not hit again straight away; timeouts and stream errors are tuned at build time.
- Keys: one virtual key per client; Coder workspace keys delivered through the workspace template from a secret, not typed by hand.
- Honcho's embedding model and dimension must match its restored data; the builder reads the archived config and keeps the same model.
- Admin UI stays enabled but is never anonymous: master key only, LAN-only route.
- Web UI login: Kanidm/OAuth only if the cluster already has an auth pattern for it; otherwise master-key-protected and LAN-only.

## Left to the builder

- Exact chart (official LiteLLM Helm chart vs. app-template), versions, resources.
- Key and team layout, per-key budgets and rate limits.
- Alert rules and dashboard.
- Docs updates (`docs/`, network table if an IP is used) in the same PRs.

## Delivery order

1. Gateway alone with `main`, `cheap`, `local`, budget and fallback, tested with curl.
2. opencode in a Coder workspace pointed at it.
3. Embeddings server, Honcho, Hermes restored and pointed at it.
