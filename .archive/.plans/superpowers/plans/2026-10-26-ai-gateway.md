# AI gateway (LiteLLM) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One LiteLLM gateway in the cluster that serves Codex-subscription `main`, OpenRouter `cheap`, Jetson `local` and CPU `embed`, with a 50 zl/month cap on pay-per-token spend, then move opencode, Honcho and Hermes onto it.

**Architecture:** Two apps, as in bjw-s `kubernetes/apps/ai`: `cluster/apps/ai/litellm-operator` (the home-operations operator chart) and `cluster/apps/ai/litellm` (a `LiteLLMProxy`, one `LiteLLMModel` per model, `LiteLLMTeam` and `LiteLLMVirtualKey` per client, a CNPG database from the local `pgsql-cnpg` chart, ExternalSecret, ServiceMonitor, optional Dragonfly for budget counters). Pattern source: `gh api repos/bjw-s-labs/home-ops/contents/kubernetes/apps/ai/litellm/app` and the operator README (`gh api repos/home-operations/litellm-operator/contents/README.md`). Earlier commits on this branch (config in `proxy_config` with `litellm-helm`) are superseded by Task 1.

**Tech Stack:** ArgoCD ApplicationSet, home-operations `litellm-operator` chart and CRDs (`litellm.home-operations.com/v1alpha1`), `charts/pgsql-cnpg`, External Secrets (Bitwarden), Envoy Gateway `envoy-internal`, Prometheus, Coder Terraform template.

**Spec:** `.archive/.plans/superpowers/specs/2026-10-26-ai-gateway-design.md`

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
- Namespace is `ai` (owner's decision). In-cluster URL: `http://litellm.ai.svc.cluster.local:4000/v1`. The removed app used namespace `litellm`, so change it in `app-config.yaml` and remember the CNPG Service is now `litellmdb-cnpg-rw.ai`.
- The Bitwarden entries from the removed app still exist (owner confirmed): reuse the master key and S3 UUIDs from `git show 2b06f7d2^:cluster/apps/ai/litellm/templates/api-externalsecret.yaml`. Only the OpenRouter key and the per-client keys need checking or adding; the archived Honcho OpenRouter entry (`.archive/cluster/ai/honcho/values.yaml`, `openrouterBwsId`) can supply the OpenRouter key.

## Review Focus

- Budget exhausted: `cheap` returns 429/budget error, `main` still answers, and calls that need a fallback land on `local` (not an error to the client).
- `main` usage-limit response triggers the fallback and `main` then cools down instead of being retried on every request.
- A client key cannot call models it was not granted (Hermes key cannot use `main` if not allowed; embeddings-only key cannot chat).
- Pod restart does not lose the ChatGPT OAuth login or the master key; first start with an empty database comes up healthy.
- Embedding dimension from `embed` equals what the restored Honcho schema expects (nomic-embed-text v1.5, 768).
- `local` request while nv1 is busy (one slot) queues or times out with a clear error rather than hanging the client.

---

## Delivery step 1: gateway alone

### Task 1: Operator app and proxy skeleton with `cheap` and `local`

**Files:**
- Create: `cluster/apps/ai/litellm-operator/{Chart.yaml,app-config.yaml,values.yaml}` (wrap `oci://ghcr.io/home-operations/charts/litellm-operator`, latest 0.0.x; `syncWave: "-1"`; webhook and leader election on, memory limit 128Mi as in bjw-s)
- Rework: `cluster/apps/ai/litellm/` — drop `litellm-helm` and `proxy_config`; keep `pgsql-cnpg` dependency, `templates/api-externalsecret.yaml`, route
- Create: `cluster/apps/ai/litellm/templates/{litellmproxy.yaml,models/cheap.yaml,models/local.yaml}`

**Interfaces:**
- Produces: `LiteLLMProxy/litellm` (image from `ghcr.io/berriai/litellm`, pinned by tag and digest, Renovate tracks it; `apiAccess.masterKeyRef` -> Secret `litellm-secrets` key `LITELLM_MASTER_KEY`; `DATABASE_URL` from the CNPG app secret `litellmdb-cnpg-app` key `uri`); `LiteLLMModel` `cheap` and `local` with `proxyRef: litellm`; Service `litellm:4000` in namespace `ai`; route on `envoy-internal` via `spec.route` hostnames `litellm.<secret:private-domain>`.

- [ ] **Step 1: Write the failing check** `check1.sh`: renders both apps and asserts the kinds `LiteLLMProxy`, `LiteLLMModel` (2), `ExternalSecret`, `Cluster`; no `litellm-helm`; route parent is `envoy-internal`; models are `cheap` (`openrouter/google/gemini-3.1-flash-lite`, key from `OPENROUTER_API_KEY`) and `local` (`openai/gemma-4-26b-a4b`, `apiBase` the llama-server Service). Run it; expect FAIL.
- [ ] **Step 2: Create the operator app.** CRDs must exist before the proxy app syncs: operator `syncWave` lower than litellm, and the litellm app syncs with `SkipDryRunOnMissingResource=true` (see `cluster/apps/system/tuppr/templates/*` for the pattern).
- [ ] **Step 3: Rework the litellm app** to the interfaces above. Resources: requests 100m/256Mi, memory limit 2Gi. Set `generalSettings.store_model_in_db: false`, `litellmSettings.callbacks: ["prometheus"]`, `routerSettings.cooldown_time: 300`, `num_retries: 1`. Admin UI: master key only, never anonymous (no Kanidm yet).
- [ ] **Step 4: Reuse the Bitwarden entries** (master key, S3 from `git show 2b06f7d2^:cluster/apps/ai/litellm/templates/api-externalsecret.yaml`; OpenRouter key from the archived Honcho UUID, owner to confirm). Add `LITELLM_SALT_KEY` (new entry, owner creates; encrypts stored credentials, must never change).
- [ ] **Step 5: Run `check1.sh`** until OK; `task lint:all` clean for the two apps.
- [ ] **Step 6: Commit** `feat(litellm): move the gateway to the LiteLLM operator`

### Task 2: Budget, fallbacks, teams and virtual keys

**Files:**
- Modify: `cluster/apps/ai/litellm/templates/litellmproxy.yaml` (`routerSettings`)
- Create: `cluster/apps/ai/litellm/templates/{teams.yaml,keys.yaml}`, optionally `dragonfly.yaml`

**Interfaces:**
- Produces: `routerSettings.provider_budget_config.openrouter` (`budget_limit: 13`, `time_period: 30d`), `fallbacks: [{cheap: [local]}]` (the `main -> cheap` entry is added in Task 3); one `LiteLLMTeam` per client with `secretName` `hermes-litellm`, `honcho-litellm`, `opencode-litellm`. The operator writes each key into that Secret in the key resource's own namespace, and `proxyNamespace: ai` lets a key live in the client's namespace, so create `opencode` in `coder` (where workspace pods can read it), and `hermes`/`honcho` with their apps in Tasks 6-7; Task 2 creates only the teams and a throwaway test key and `models` limited per the key table in the docs.

- [ ] **Step 1: Extend `check1.sh` into `check2.sh`**: assert the budget block, no `litellm_settings.max_budget`, cooldown 300, `cheap -> local` fallback, and three `LiteLLMTeam` with the model lists from the docs table. Expect FAIL.
- [ ] **Step 2: Implement** (budget via `routerSettings` free-form fields; keys per bjw-s `hermes/app/litellmvirtualkey.yaml`).
- [ ] **Step 3: Budget counters.** Provider-budget spend is in memory unless Redis is configured. Owner decision pending (spec "Builder's choices"): if yes, add a small Dragonfly instance (the cluster has `dragonfly-operator`) and `REDIS_HOST`/`REDIS_PORT` env plus `routerSettings.redis_host/redis_port`; if no, document the restart reset.
- [ ] **Step 4: Owner approves and deploys** (merge, sync operator first, then litellm). Verify via port-forward with the master key from the owner's shell: `cheap` and `local` complete; the operator-created key Secrets exist; a key rejects a model outside its list.
- [ ] **Step 5: Budget test:** throwaway `LiteLLMVirtualKey` with a tiny budget, call `cheap` until rejected, `local` still works. Delete it.
- [ ] **Step 6: Commit/PR** `feat(litellm): budget cap, teams and virtual keys`

### Task 3: ChatGPT-subscription `main` (needs the owner)

**Files:**
- Modify: `cluster/apps/ai/litellm/templates/litellmproxy.yaml` (env `CHATGPT_TOKEN_DIR=/app/chatgpt_tokens`, PVC volume and mount as in bjw-s), create `templates/pvc.yaml` (1Gi), `templates/models/main.yaml`
- Modify: `docs/src/k8s/ai-gateway.md` ("main model login")

**Interfaces:**
- Produces: `LiteLLMModel` `main` (`params.model: chatgpt/<current model>`, `info.mode: responses`, `additional_drop_params: [temperature]`, as bjw-s `models/chatgpt/*.yaml`), fallback `main -> cheap`, plus a final `local` fallback for budget exhaustion.

- [ ] **Step 1: Check, before building.** OpenAI terms for subscription use through a gateway, and LiteLLM's `chatgpt/` provider docs (Context7); bjw-s already runs it, which is evidence it works but not about the terms. If either blocks it, stop and ask the owner.
- [ ] **Step 2: Add the PVC, env and mount**, then `main` and the fallback. The OAuth token lives on the PVC at `CHATGPT_TOKEN_DIR`, so it survives restarts.
- [ ] **Step 3: With the owner, do the interactive device login** against the running pod. Never paste tokens into chat or git.
- [ ] **Step 4: Verify** `main` completes; delete the pod and confirm `main` still works after restart.
- [ ] **Step 5: Simulate a usage-limit response** (`mock_testing_fallbacks: true`) and confirm the answer comes from `cheap` and `main` cools down.
- [ ] **Step 6: Document** the login procedure; commit/PR `feat(litellm): add the ChatGPT subscription as main`

### Task 4: Metrics, alerts and docs

**Files:**
- Create: `cluster/apps/ai/litellm/templates/{servicemonitor.yaml,prometheusrule.yaml}` (ServiceMonitor as bjw-s `litellm/app/serviceMonitor.yaml`, label `release: prometheus-stack`; rules as already written in commit `659451a5`, copy them)
- Modify: `docs/src/k8s/ai-gateway.md` (already written; update the operator parts), `.github/mkdocs/mkdocs.yml` (nav entry exists)

- [ ] **Step 1: Write the failing check** (`check4.sh` from the branch history): ServiceMonitor with the release label, PrometheusRule with `LiteLLMBudgetNearlyUsed` and `LiteLLMModelFailing`, prometheus callback in the proxy settings. Expect FAIL after Task 1 removes the old chart.
- [ ] **Step 2: Implement** and rerun until OK.
- [ ] **Step 3: After deploy,** the target is `up` in Prometheus and the metric names in the rules exist on `/metrics` (read-only query; owner confirms).
- [ ] **Step 4: Commit/PR** `feat(litellm): metrics, alerts and docs`

## Delivery step 2: opencode in Coder

### Task 5: Point opencode workspaces at the gateway

**Files:**
- Modify: `cluster/apps/ai/coder/workspace-template/main.tf` (container env / opencode config), `cluster/apps/ai/coder/templates/externalsecret.yaml` if a key must reach the template

**Interfaces:**
- Consumes: Secret `opencode-litellm` (key `key`; confirm the key name in the operator README or a created Secret) from a `LiteLLMVirtualKey` named `opencode` that this task adds in the `coder` namespace with `proxyNamespace: ai`; URL `http://litellm.ai.svc.cluster.local:4000/v1`.

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
- [ ] **Step 2: Replace the OpenRouter key in Honcho** with the gateway URL and the `honcho-litellm` Secret from a `LiteLLMVirtualKey` named `honcho` in the Honcho namespace (`proxyNamespace: ai`); update its Reloader annotation.
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
- [ ] **Step 2: Set `model` to the gateway:** `provider: custom`, `default: main`, `base_url: http://litellm.ai.svc.cluster.local:4000/v1`, `api_key` from the `hermes-litellm` Secret of a `LiteLLMVirtualKey` named `hermes` (`proxyNamespace: ai`); remove `fallback_providers` (the gateway handles fallback).
- [ ] **Step 3: Set auxiliary tasks** (title generation, compression, approval, web_extract, triage, kanban) to `local` through the gateway; vision to `cheap`. Compression needs >= 64K; verify with the Hermes startup log.
- [ ] **Step 4: Render** and lint; deploy with owner confirmation; test a Discord message end to end.
- [ ] **Step 5: Update `.archive/cluster/ai/README.md`** (restored items removed from the archived list).
- [ ] **Step 6: Commit/PR** `feat(hermes): restore the agent on the AI gateway`

### Task 8: Jetson model review and close-out

- [x] **Step 1 (skipped by the owner 2026-10-26, moved to `.plans/TODO.md`): Benchmark one lighter model** for `local` (housekeeping, summaries, Lingarr translation) against the current one with the paused-llama-server procedure from the nv1 notes (owner confirms the pause window).
- [x] **Step 2 (skipped with Step 1): Switch only if quality holds;** record the result in `docs/src/k8s/nv1-jetson.md`.
- [x] **Step 3: After Task 9 is done, move this plan and spec to `.archive/.plans/superpowers/{plans,specs}/`**, update links and both `list.md` files.
- [x] **Step 4: Commit/PR** `chore(plans): archive ai-gateway`

### Task 9: Harden the apps in `ai`, `honcho` and `llm`

Audit on 2026-10-26 (`kubectl get pods -o json`, securityContext per container): the operator and the CNPG pods already run non-root, read-only root, `drop: [ALL]`, seccomp `RuntimeDefault`. `litellm`, `litellm-dragonfly`, `honcho-api`, `honcho-deriver`, `llama-server` and `llm-embeddings` set none of that. No NetworkPolicy exists in `ai`, `honcho` or `llm`. Namespaces `ai` and `llm` enforce Pod Security `baseline`; `honcho` has no Pod Security label. The goal is the same posture on every container, with no change in behaviour.

**Files:**
- Modify: `cluster/apps/ai/litellm/templates/litellmproxy.yaml` (`securityContext`, `podSecurityContext`, writable `emptyDir` mounts), `cluster/apps/ai/litellm/values.yaml` (Dragonfly chart values), `cluster/apps/ai/honcho/templates/deployment-*.yaml`, `cluster/apps/ai/llm/embeddings/templates/deployment.yaml`, `cluster/apps/ai/llm/server/templates/*` (check GPU/CDI first)
- Create: `cluster/apps/ai/litellm/templates/networkpolicy.yaml`, matching policies in the `honcho` and `llm` apps
- Modify: `cluster/apps/ai/honcho/app-config.yaml` (`managedNamespaceMetadata` Pod Security labels), `docs/src/k8s/ai-gateway.md` (a "Hardening" section)

**Interfaces:**
- Consumes: the operator CRD fields `LiteLLMProxy.spec.securityContext` / `podSecurityContext` / `volumes` / `volumeMounts`.
- Produces: one security baseline per container that later apps (Hermes, Task 7) copy.

- [ ] **Step 1: Check that the CNI enforces NetworkPolicy** (`kubectl -n kube-system get pods`, CNI name and its docs). If it does not, drop Steps 6-7 and note it here.
- [ ] **Step 2: Write the check first.** A script (git-ignored, in the ledger workspace) that renders each app with `helm template` and asserts with `yq` that every container has `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, and `readOnlyRootFilesystem: true` unless a ruling in the ledger names why not. Run it; it must fail on the six workloads above.
- [ ] **Step 3: Harden one workload at a time** in this order: `llm-embeddings`, `honcho-api`/`honcho-deriver`, `litellm-dragonfly`, `litellm`, then `llama-server` only if the Jetson CDI/GPU path still works (otherwise ledger a ruling and leave it). **Owner ruling 2026-10-26: do not harden anything on the Jetson, so `llama-server` stays as it is and `llm` stays on `baseline`.**. For each: find the writable paths the image needs (`/tmp`, caches, `/app/chatgpt_tokens`), mount `emptyDir` for them, find a working non-root UID, render, then deploy with the owner's confirmation and check the pod starts and answers (Honcho `/health`, `embed` returns 768 dims, `main`/`cheap`/`local` answer, Dragonfly counters still shared).
- [ ] **Step 4: Turn off the ServiceAccount token** (`automountServiceAccountToken: false`) on `honcho-api`, `honcho-deriver` and `llm-embeddings`, which never call the Kubernetes API.
- [ ] **Step 5: Add Pod Security labels** to the `honcho` namespace (`enforce`/`warn`/`audit` at `baseline`, like `ai` and `llm`); try `restricted` on `ai` after Step 3 and keep it only if every pod still admits.
- [ ] **Step 6: NetworkPolicies, default deny ingress** in each of the three namespaces, with explicit allows: Envoy Gateway to `litellm:4000`; the `coder`, `honcho` (and later `hermes-agent`) namespaces to `litellm:4000`; Prometheus (`monitoring`) to `litellm:4000` metrics and the CNPG/Dragonfly metrics ports; the operator to `litellm:4000`; `litellm` to its Postgres and Dragonfly; `ai` to `llm-embeddings:8080` and `llama-server:8080`; Lingarr's namespace to `llama-server:8080`; `honcho` to its Postgres. No egress policy: `litellm` must reach OpenRouter and ChatGPT, so an allow-list there is brittle.
- [ ] **Step 7: Apply policies one namespace at a time** and run the full client check after each (opencode in a Coder workspace, Honcho, Prometheus target up, Lingarr).
- [ ] **Step 8: Document and commit/PR per workload group:** `docs/src/k8s/ai-gateway.md` "Hardening" section with the baseline and the per-workload exceptions; `feat(ai): harden the gateway workloads`, `feat(ai): add network policies`.

**Review Focus:**
- A read-only root filesystem breaking a rarely used path (LiteLLM UI log writes, Honcho migrations, ChatGPT token refresh writing `auth.json`): exercise a token refresh and a Honcho migration, not only a health check.
- A NetworkPolicy blocking a path nobody tests daily (Prometheus scrape, CNPG backups to S3, the operator calling the admin API, webhook calls to the operator).
- Rolling a hardened `litellm` with the ReadWriteMany login volume: the new pod must read the existing `auth.json` under the new UID (volume ownership, `fsGroup`).
