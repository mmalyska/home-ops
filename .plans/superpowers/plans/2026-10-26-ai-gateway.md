# AI gateway (LiteLLM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One LiteLLM gateway in the cluster that serves Codex-subscription `main`, OpenRouter `cheap`, Jetson `local` and CPU `embed`, with a 50 zl/month cap on pay-per-token spend, then move opencode, Honcho and Hermes onto it.

**Architecture:** Restore the removed LiteLLM app (`cluster/apps/ai/litellm`, removed in commit `2b06f7d2`) with the `litellm-helm` chart and a CNPG database from the local `pgsql-cnpg` chart. Model routing, fallbacks and budgets live in `proxy_config` in `values.yaml`. Clients get one virtual key each. No LiteLLM operator.

**Tech Stack:** ArgoCD ApplicationSet, `litellm-helm` (oci://ghcr.io/berriai), `charts/pgsql-cnpg`, External Secrets (Bitwarden), Envoy Gateway `envoy-internal`, Prometheus, Coder Terraform template.

**Spec:** `.plans/superpowers/specs/2026-10-26-ai-gateway-design.md`

## Global Constraints

- Gateway is LAN-only: HTTPRoute on `envoy-internal` only, never `envoy-external`.
- The admin UI is never anonymous; master key only.
- Aliases clients use: `main`, `cheap`, `embed`, `local`.
- Fallback chain: `main` -> `cheap`; when the budget is used up, `main` keeps working and the gateway falls back to `local`.
- 50 zl/month cap applies only to `cheap` (pay-per-token); LiteLLM budgets are USD, so use a fixed USD figure close to 50 zl. `main`, `embed`, `local` are not counted.
- Provider keys, OAuth tokens and the master key live in Bitwarden + ExternalSecret only; never in git. Mark UUID lines `#gitleaks:allow #KEY_NAME`.
- Every container: CPU/memory requests and a memory limit, no CPU limit (`docs/src/k8s/resource-sizing.md`).
- Workloads reading the Secret at startup carry `secret.reloader.stakater.com/reload`.
- Do not schedule anything new on nv1; its memory is tight.
- Hermes needs >= 64K context per slot; `local` already provides it (`-c 65536 -np 1`).
- Never mutate cluster state (apply, sync, kubectl delete) without asking the owner first. Work in the `feat/ai-gateway` worktree; open a PR per delivery step.
- If the ChatGPT-subscription check (Task 3) fails, stop and ask the owner before choosing another `main`.
- Namespace is `litellm` (matches the removed app and the repo's one-namespace-per-app habit; the spec's "`ai`" meant the category directory `cluster/apps/ai`).

## Review Focus

- Budget exhausted: `cheap` returns 429/budget error, `main` still answers, and calls that need a fallback land on `local` (not an error to the client).
- `main` usage-limit response triggers the fallback and `main` then cools down instead of being retried on every request.
- A client key cannot call models it was not granted (Hermes key cannot use `main` if not allowed; embeddings-only key cannot chat).
- Pod restart does not lose the ChatGPT OAuth login or the master key; first start with an empty database comes up healthy.
- Embedding dimension from `embed` equals what the restored Honcho schema expects (nomic-embed-text v1.5, 768).
- `local` request while nv1 is busy (one slot) queues or times out with a clear error rather than hanging the client.

---

## Delivery step 1: gateway alone

### Task 1: Restore the LiteLLM app with `cheap`, `local`, DB and route

**Files:**
- Create: `cluster/apps/ai/litellm/{Chart.yaml,app-config.yaml,values.yaml}`
- Create: `cluster/apps/ai/litellm/templates/{httproute.yaml,api-externalsecret.yaml}`
- Reference: `git show 2b06f7d2^:cluster/apps/ai/litellm/<file>` for each file (they match the layout above)

**Interfaces:**
- Produces: Service `litellm` port 4000 in namespace `litellm`; Secret `litellm-secrets` with keys `LITELLM_MASTER_KEY`, `OPENROUTER_API_KEY`, `S3_ACCESS_KEY_ID`, `S3_ACCESS_SECRET_KEY`; model aliases `cheap` and `local`; CNPG cluster `litellmdb`.

- [ ] **Step 1: Restore files from `2b06f7d2^`** with `git show`, set `enabled: "true"` in `app-config.yaml`, bump `litellm-helm` to the latest 1.x release Renovate tracks and the CNPG image to the one `.archive/cluster/ai/honcho/values.yaml` uses (`17.6-standard-bookworm`).
- [ ] **Step 2: Rewrite `proxy_config.model_list`** to exactly two entries: `cheap` -> `openrouter/<model chosen by price/quality at build time, DeepSeek or Gemini Flash class>`, `local` -> `openai/gemma-4-26b-a4b` with `api_base: http://llama-server.llm.svc.cluster.local:8080/v1` and `api_key: local`. Remove the Anthropic/OpenAI credentials and keys.
- [ ] **Step 3: Rewrite `api-externalsecret.yaml`** with keys `LITELLM_MASTER_KEY`, `OPENROUTER_API_KEY`, `S3_ACCESS_KEY_ID`, `S3_ACCESS_SECRET_KEY`. Ask the owner which Bitwarden UUIDs exist: the old master-key and S3 UUIDs may still be valid; the OpenRouter key needs a new entry. Do not guess UUIDs.
- [ ] **Step 4: Set resources** (requests 100m/512Mi, memory limit 2Gi: the old audits show ~1 GiB use) and the CNPG backup destination under a new path `s3://.../cnpg/litellm`.
- [ ] **Step 5: Render and lint**
  Run: `cd cluster/apps/ai/litellm && helm dependency build . && helm template litellm . -f values.yaml | grep -E "kind: (Deployment|HTTPRoute|ExternalSecret|Cluster)$"`
  Expected: one each, no render error. Then `task lint:all` passes.
- [ ] **Step 6: Commit** `feat(litellm): restore the gateway with OpenRouter and local models`

### Task 2: Budget, per-client keys and fallback config

**Files:**
- Modify: `cluster/apps/ai/litellm/values.yaml` (`proxy_config`)

**Interfaces:**
- Consumes: aliases from Task 1.
- Produces: `router_settings` with `fallbacks: [{"main": ["cheap"]}]` (placeholder until Task 3 adds `main`), `cooldown_time` of 300s, `num_retries: 1`; `litellm_settings.max_budget` (fixed USD figure close to 50 zl, review against the exchange rate) with `budget_duration: 30d`, applied to `cheap` only; `general_settings.disable_spend_logs: false`.

- [ ] **Step 1: Add the settings above** and a per-key budget block as comments documenting the key layout: `hermes`, `honcho`, `opencode` (one key each, models limited to what each needs).
- [ ] **Step 2: Render** `helm template ... | grep -A3 -E "max_budget|cooldown_time|fallbacks"` shows the values from the Global Constraints.
- [ ] **Step 3: Ask the owner for approval, then deploy** (merge the PR, owner syncs). Verify from a port-forward, using the master key from the owner's shell:
  `curl -s localhost:4000/v1/chat/completions -H "Authorization: Bearer $KEY" -d '{"model":"cheap","messages":[{"role":"user","content":"say ok"}]}'` returns a completion; same for `local`.
- [ ] **Step 4: Create the three virtual keys** with `curl localhost:4000/key/generate` (`models`, `max_budget`, `key_alias`), store each in Bitwarden (owner action), and test that a key rejects a model outside its list with a 401/403.
- [ ] **Step 5: Budget test:** generate a throwaway key with `max_budget: 0.0001`, call `cheap` until it is rejected, then confirm a call to `local` still works. Delete the key.
- [ ] **Step 6: Commit/PR** `feat(litellm): budget cap, cooldown and per-client keys`

### Task 3: ChatGPT-subscription `main` (needs the owner)

**Files:**
- Modify: `cluster/apps/ai/litellm/values.yaml`, `cluster/apps/ai/litellm/templates/` (token storage as found)
- Create: `docs/src/k8s/ai-gateway.md` (section "main model login")

**Interfaces:**
- Produces: alias `main`; fallback `main -> cheap` active; a documented way to re-do the login.

- [ ] **Step 1: Check, before building.** Read LiteLLM's current docs (Context7) for the ChatGPT-subscription provider, and OpenAI's terms for subscription use through a gateway. If either blocks it, stop and ask the owner. Write the finding into `docs/src/k8s/ai-gateway.md`.
- [ ] **Step 2: Decide token storage** from the docs: where LiteLLM writes the OAuth token and whether it survives a restart (PVC mounted at that path, a DB, or an ExternalSecret re-seed). Add what is needed (for a PVC, a PVC manifest plus a `volumeMounts` entry; size 1Gi).
- [ ] **Step 3: Add `main`** to `model_list` and the real fallback `[{"main": ["cheap"]}]`, plus `context_window_fallbacks` and a `local` fallback for budget exhaustion as the Global Constraints require.
- [ ] **Step 4: With the owner, do the interactive device login** against the running pod (owner enters the code in a browser). Never paste tokens into chat or git.
- [ ] **Step 5: Verify:** `main` completes; delete the pod and confirm `main` still works after it restarts (Review Focus: login survives restart).
- [ ] **Step 6: Simulate a usage-limit response** (LiteLLM `mock_testing_fallbacks: true` on the request) and confirm the answer comes from `cheap` and `main` is cooled down on the next call.
- [ ] **Step 7: Commit/PR** `feat(litellm): add the ChatGPT subscription as main`

### Task 4: Metrics, alert and docs

**Files:**
- Create: `cluster/apps/ai/litellm/templates/servicemonitor.yaml` (or PodMonitor, match `cluster/apps/ai/llm/server/templates/podmonitor.yaml`), `cluster/apps/ai/litellm/templates/prometheusrule.yaml`
- Modify: `docs/src/k8s/ai-gateway.md`, `docs/src/k8s/network.md` or the LB/IP table only if an IP is used (none expected)

- [ ] **Step 1: Enable `litellm_settings.callbacks: ["prometheus"]`** and add the monitor.
- [ ] **Step 2: Add two alerts:** budget used > 80% of `max_budget`; `main` failure ratio > 50% over 15m.
- [ ] **Step 3: Verify:** `helm template` renders them; after sync the target is `up` in Prometheus (owner confirms or read-only query).
- [ ] **Step 4: Document** model aliases, fallback chain, key layout, login procedure, budget reset in `docs/src/k8s/ai-gateway.md`; add the plan to `.plans/list.md`.
- [ ] **Step 5: Commit/PR** `feat(litellm): metrics, alerts and docs`

## Delivery step 2: opencode in Coder

### Task 5: Point opencode workspaces at the gateway

**Files:**
- Modify: `cluster/apps/ai/coder/workspace-template/main.tf` (container env / opencode config), `cluster/apps/ai/coder/templates/externalsecret.yaml` if a key must reach the template

**Interfaces:**
- Consumes: the `opencode` virtual key from Task 2; URL `http://litellm.litellm.svc.cluster.local:4000/v1`.

- [ ] **Step 1: Read how the template passes env** and where opencode is configured (`main.tf` around the `kubernetes_deployment_v1.workspace` container). Deliver the key from a Kubernetes Secret via `secret_key_ref`, not as a Coder parameter.
- [ ] **Step 2: Provide an opencode provider config** pointing at the URL, with models `main`, `cheap`, `local` (OpenAI-compatible provider). Mount or write it at workspace start.
- [ ] **Step 3: `terraform validate`** passes; then follow the `coder-workspace-template-deploy` skill with the owner's confirmation.
- [ ] **Step 4: Verify** in a workspace: `opencode run "say ok"` with `main`, then force `cheap`.
- [ ] **Step 5: Commit/PR** `feat(coder): route opencode through the AI gateway`

## Delivery step 3: Honcho and Hermes

### Task 6: Restore embeddings and Honcho

**Files:**
- Move: `.archive/cluster/ai/llm-embeddings` -> `cluster/apps/ai/llm/embeddings`; `.archive/cluster/ai/honcho` -> `cluster/apps/ai/honcho` (follow `.archive/cluster/ai/README.md` Restore steps 1-3)
- Modify: `cluster/apps/ai/llm/app-config.yaml` (append embeddings entry with `appSubfolder: embeddings`), Honcho templates/externalsecret (LLM base URL -> gateway), LiteLLM `values.yaml` (add `embed`)

**Interfaces:**
- Produces: alias `embed` -> `openai/nomic-embed-text` at the embeddings Service; Honcho using key `honcho` for chat (`cheap` or `local`, builder picks by testing summary quality) and `embed` for vectors.

- [ ] **Step 1: Do the archive restore** exactly as the README describes; keep the embedding model (nomic-embed-text v1.5, 768-dim) so the schema matches.
- [ ] **Step 2: Replace the OpenRouter key in Honcho** with the gateway URL and the `honcho` key; update its ExternalSecret and Reloader annotation.
- [ ] **Step 3: Add `embed`** to LiteLLM; test `curl .../v1/embeddings` returns a 768-length vector.
- [ ] **Step 4: Render** both apps with `helm template`; `task lint:all`.
- [ ] **Step 5: Owner creates the empty `honchodb` data (new database, no data was kept) on first sync; verify Honcho `/health`.**
- [ ] **Step 6: Commit/PR** `feat(honcho): restore memory backend behind the AI gateway`

### Task 7: Restore Hermes on the gateway

**Files:**
- Move: `.archive/cluster/ai/hermes-agent` -> `cluster/apps/ai/hermes-agent`
- Modify: its `values.yaml` `hermes.config` (model blocks), `templates/externalsecret.yaml`
- Re-add the Renovate rule for `nousresearch/hermes-agent` (README step 4)

- [ ] **Step 1: Restore** per README steps 1, 3-4.
- [ ] **Step 2: Set `model` to the gateway:** `provider: custom`, `default: main`, `base_url: http://litellm.litellm.svc.cluster.local:4000/v1`, `api_key` from the `hermes` key via ExternalSecret; remove `fallback_providers` (the gateway handles fallback).
- [ ] **Step 3: Set auxiliary tasks** (title generation, compression, approval, web_extract, triage, kanban) to `local` through the gateway; vision to `cheap`. Compression needs >= 64K; verify with the Hermes startup log.
- [ ] **Step 4: Render** and lint; deploy with owner confirmation; test a Discord message end to end.
- [ ] **Step 5: Update `.archive/cluster/ai/README.md`** (restored items removed from the archived list).
- [ ] **Step 6: Commit/PR** `feat(hermes): restore the agent on the AI gateway`

### Task 8: Jetson model review and close-out

- [ ] **Step 1: Benchmark one lighter model** for `local` (housekeeping, summaries, Lingarr translation) against the current one with the paused-llama-server procedure from the nv1 notes (owner confirms the pause window).
- [ ] **Step 2: Switch only if quality holds;** record the result in `docs/src/k8s/nv1-jetson.md`.
- [ ] **Step 3: Move this plan and spec to `.archive/.plans/superpowers/{plans,specs}/`**, update links and both `list.md` files.
- [ ] **Step 4: Commit/PR** `chore(plans): archive ai-gateway`
