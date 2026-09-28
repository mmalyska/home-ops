# Swap the local LLM to LFM2.5-8B-A1B — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Gemma 4 26B-A4B-it (UD-Q2_K_XL) with LFM2.5-8B-A1B (UD-Q6_K_XL) as the model served by `llama-server` on nv1, and re-point every consumer (Hermes main model, Hermes's 7 local auxiliary tasks + compression, Honcho's 5 local model slots) at it — without repeating the memory incident from 2026-09-28.

**Architecture:** No architectural change. Same `llm` namespace, same `llama-server` Deployment (`cluster/apps/ai/llm/server`), same digest-pinned CUDA 12.6 image, same two-slot layout. Only the served model file changes, plus a new flag to keep small-budget calls cheap on a model that cannot fully disable its chain-of-thought the way Gemma 4 could.

**Tech Stack:** llama.cpp `llama-server` (image `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04`), Helm charts in `cluster/apps/ai/llm/server` and `cluster/apps/ai/hermes-agent`, Honcho env-var model config, ArgoCD ApplicationSet `appset-ai`.

**Spec:** `docs/superpowers/specs/2026-09-25-local-first-llm-design.md` (architecture is unchanged and still binding). This plan also argues from measurements recorded in `.superpowers/sdd/2026-09-25-local-first-llm/progress.md` (rulings R9–R12: the nv1 memory incident, the 12Gi-limit mistake, the Hermes 64K-context floor, and the 2026-09-28 LFM2.5 spike results) and from a throwaway spike run directly on nv1 on 2026-09-28 (not committed; results below).

## Context: why this plan exists

On 2026-09-28, `llama-server` running Gemma 4 26B-A4B at `-c 131072 -np 2` (two 64K-token slots, needed because Hermes hard-refuses any model under 64,000 tokens of context) was OOM-killed under real concurrent traffic (three near-simultaneous `hermes chat` calls), at `anon-rss 13.78 GB` against a 13Gi limit. A prior *sequential* memory test (one request at a time) had not caught this.

A follow-up research spike identified **LFM2.5-8B-A1B** (Liquid AI, 8.3B total / 1.5B active params) as a candidate that trades a small amount of general tool-calling quality for a much smaller footprint. A throwaway GPU spike on nv1 (`lfm-spike` pod, `llm` namespace, deleted after testing) measured, at the same `-c 131072 -np 2` config:

| | Gemma 4 26B-A4B (UD-Q2_K_XL) | LFM2.5-8B-A1B (UD-Q6_K_XL) |
|---|---|---|
| GGUF file size | 9.82 GiB | 7.21 GiB |
| Layers offloaded | 31/31 | 25/25 (full) |
| KV buffer @ 131072 ctx | 1243 MiB | 624 MiB |
| Idle/light-load pod memory | 10.2–11.1 GiB | 8.5–8.9 GiB |
| Generation speed | 15–16 tok/s | 26.7 tok/s |
| S1 quality probe (15 cases, title/approval/compression/JSON) | 15/15 (thinking off) | 15/15 (thinking always on) |
| Parallel tool calls (`parallel_tool_calls: true`) | 5/5 clean | 3/3 clean |
| Concurrency test (2 simultaneous ~3k-token-system-prompt requests) | **OOM-killed** (separate incident, same config) | Survived: memory 8663→8716 MiB, both answered in ~32s |

**The one real cost, untested until Task 2 below:** LFM2.5 is a "reasoning-only" model — it always emits chain-of-thought before answering (400–2000+ characters observed in the spike), unlike Gemma 4 which could be switched off with `chat_template_kwargs.enable_thinking=false`. Every aux-task call (titles, approval checks, JSON extraction) will cost more tokens and wall-clock than Gemma's thinking-off mode did, unless `llama-server`'s generic `--reasoning-budget` flag can suppress it — this is unverified and is Task 2.

**Current cluster state:** `cluster/apps/ai/llm/server` is at `replicaCount: 0` (from the spike's PR #5343; the revert PR #5346 restoring Gemma is intentionally **not merged** — the owner chose to go straight to this swap instead of restoring Gemma first). Hermes's main model, compression task, and 7 local aux tasks, and Honcho's 5 local slots, are all still configured (in git) to point at `gemma-4-26b-a4b` at `http://llama-server.llm.svc.cluster.local:8080/v1` — they are currently falling back to their cloud providers because the server is down. This is expected and accepted until this plan's Task 4/5 land.

## Global Constraints

- CUDA 12.6 image only, digest-pinned: `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04@sha256:8fa5df9a76d3ddce89ade0ae67822afdfac27a5fe3a9e5eff7b6dfd72cd34f6b`. Never `latest*` tags (CUDA 13, silent CPU fallback).
- Every model download is sha256-verified before the seeded chart trusts it (same pattern as the existing `fetch-model` init container).
- nv1's memory budget is real and tight: 15.6 GiB total, ~3.4 GiB used by the system. A pod memory limit must stay below ~13.4 GiB (the point at which the node itself starves) and must be proven against *concurrent, near-max-context* load — a sequential single-request test is **not sufficient evidence**, per the 2026-09-28 incident.
- Hermes hard-refuses any model with less than 64,000 tokens of context (`agent_init._enforce_minimum_context`); `auxiliary.compression` has the same floor. `model.context_length` in every Hermes profile must equal the server's real per-slot context (`ctx / parallel`).
- Hermes and Honcho config seeders only add/overwrite keys on the PVC, they never delete. Any task in this plan that changes `model.provider`/`base_url`/`api_key`/`context_length`/`default` must set every one of those keys explicitly, even ones that "shouldn't" need to change, so no stale value from the Gemma config survives (the #5318 lesson).
- PSA baseline labels on the `llm` namespace are unchanged; no new privileged containers.
- No secrets or the private domain literal in any committed file.

## Review Focus

1. **Reasoning suppression for small-budget calls, and whether it holds as context grows.** If `--reasoning-budget 0` (or an equivalent) does not actually shrink LFM2.5's output the way Gemma's `enable_thinking=false` did, every one of Hermes's 7 local aux tasks and Honcho's 5 local slots gets slower and more expensive the moment this rolls out. Worse, [nousresearch/hermes-agent#9344](https://github.com/NousResearch/hermes-agent/issues/9344) shows a different reasoning model returning empty responses once accumulated conversation context made reasoning-token consumption eat the entire output budget — a risk specifically for the `compression` task, which is Hermes's own rescue mechanism for an overgrown conversation and would be pointed at the same always-reasoning model. Task 2 must measure completion-token counts at small AND large context sizes, not just check one short response is non-empty.
2. **Concurrent load at production-representative context size.** The spike's concurrency test used short (~3k-token) system prompts. Real Hermes turns and Honcho's deriver calls can be much larger. Task 3 must reproduce near-65536-token contexts on *both* slots concurrently, repeatedly, or this plan repeats the exact mistake that caused the 2026-09-28 incident.
3. **Storage headroom during the swap.** The `llama-server-models` PVC is 20Gi and currently holds the ~9.82 GiB Gemma blob. Adding the ~7.21 GiB LFM2.5 file brings it to ~17 GiB before cleanup — tight but should fit; Task 1 must check `df`/`du` on the PVC before assuming so, and Task 7 removes the old blob once the swap is confirmed.
4. **License change.** LFM2.5 is LFM Open License v1.0 (free for organizations under $10M annual revenue — fine for this home-lab, but a different license family than Gemma's). Task 7 records this in the docs it already touches; it is not a blocker.
5. **Alert threshold validity.** `LlamaServerOnCpu` (`cluster/apps/ai/llm/server/templates/prometheusrule.yaml`) fires when CPU usage exceeds 3 cores, calibrated against Gemma's ~0.2–1.2 GPU-mode cores vs ~7 CPU-fallback cores. LFM2.5's compute profile (1.5B active params, different arch) was not measured for CPU usage in the spike. Task 6 must capture this number for the new model before trusting the existing threshold unchanged.

---

### Task 1: Swap the model in the `llm/server` chart

**Files:**
- Modify: `cluster/apps/ai/llm/server/values.yaml`

**Interfaces:**
- Consumes: nothing new (same chart shape as the Gemma config).
- Produces: `llama-server` Deployment serving `lfm2.5-8b-a1b` at `replicaCount: 1`, same `http://llama-server.llm.svc.cluster.local:8080/v1` endpoint, same `-c 131072 -np 2` (65536 tokens/slot).

- [ ] **Step 1: Check PVC headroom (read-only)**

```bash
kubectl -n llm get pvc llama-server-models
# The PVC is unmounted while replicaCount: 0; if you need live du output, mount
# it from a throwaway pod first. Otherwise trust the 20Gi capacity vs the two
# file sizes below (9.82 + 7.21 = ~17.03 GiB) and proceed.
```

- [ ] **Step 2: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/llm-server-lfm2.5
```

- [ ] **Step 3: Edit `values.yaml`**

Replace the `model:` block and set `replicaCount: 1`. The sha256 below is derived from HuggingFace's `x-linked-etag` for this LFS file — **verify it for real** against the first successful download (the `fetch-model` init container already does this: if it mismatches, the pod's init container fails loudly with a `sha256sum -c` error, which is exactly the check you want; do not skip verifying the container came up clean).

```yaml
server:
  replicaCount: 1
  image:
    repository: ghcr.io/nvidia-ai-iot/llama_cpp
    # CUDA 12.6 build for JetPack 6. NEVER use latest* tags (CUDA 13 does not
    # initialize on nv1's driver and silently falls back to CPU).
    tag: "b8708-r36.4-tegra-aarch64-cu126-22.04@sha256:8fa5df9a76d3ddce89ade0ae67822afdfac27a5fe3a9e5eff7b6dfd72cd34f6b"
  fetchImage: alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
  model:
    file: LFM2.5-8B-A1B-UD-Q6_K_XL.gguf
    url: https://huggingface.co/unsloth/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-UD-Q6_K_XL.gguf
    sha256: de2718c45e69587a0589ebe5f531ed4a99bccf341b2c122b6479ffe28929a9be
    size: "7742467680"
    alias: lfm2.5-8b-a1b
  # Total context; each of the `parallel` slots gets ctx/parallel. Hermes hard-
  # refuses to start a session on a model with less than 64,000 tokens of
  # context (agent_init._enforce_minimum_context), so each slot needs >= 64000;
  # 131072 total / 2 slots = 65536 per slot.
  # LFM2.5 is a reasoning-only model (always emits chain-of-thought); unlike
  # Gemma's chat_template_kwargs.enable_thinking, suppress it with
  # --reasoning-budget (verified in Task 2). Leave chatTemplateKwargs unset for
  # this model.
  reasoningBudget: 0 # verified in Task 2; -1 = unrestricted, 0 = end immediately
  # Memory budget on nv1 (15.6 GiB unified, ~3.4 GiB used by the system).
  # LFM2.5's footprint is smaller than Gemma's (measured in the 2026-09-28
  # spike: ~8.5-8.9 GiB light load vs Gemma's ~10.2-12.2 GiB), but re-verify
  # under concurrent near-max-context load in Task 3 before trusting this.
  cacheRam: 256 # MiB of host-RAM prompt cache
  ctxCheckpoints: 2 # per slot
  ubatch: 256 # physical batch; halves the compute buffer vs the 512 default
  ctx: 131072
  parallel: 2
  storage: 20Gi
  resources:
    requests:
      cpu: 500m
      memory: 9Gi
    # Re-tune after Task 3's concurrent test result; this starting point keeps
    # the same ~4 GiB of slack under the 13.4 GiB node-starvation point that
    # the Gemma config used, scaled to LFM2.5's smaller measured baseline.
    limits:
      memory: 11Gi
      nvidia.com/gpu: 1
```

In `cluster/apps/ai/llm/server/templates/deployment.yaml`, add the reasoning-budget flag next to the existing `--chat-template-kwargs` block:

```yaml
            - --chat-template-kwargs
            - {{ .Values.server.chatTemplateKwargs | default "{}" | quote }}
            - --reasoning-budget
            - {{ .Values.server.reasoningBudget | quote }}
```

(Change the existing `chatTemplateKwargs` line to use `| default "{}"` so a future model that doesn't set it — like this one — doesn't break the template. Do not add a `chatTemplateKwargs` value for LFM2.5.)

- [ ] **Step 4: Render and verify**

```bash
cd cluster/apps/ai/llm/server && helm lint . && helm template s . | grep -E '"-c"|"131072"|"--reasoning-budget"|"0"|replicas:|lfm2.5-8b-a1b'
```

Expected: `replicas: 1`, `--reasoning-budget` `"0"`, model file/alias referencing LFM2.5, `-c 131072 -np 2` unchanged.

- [ ] **Step 5: Commit and open the PR**

```bash
cd /workspaces/home-ops
git add cluster/apps/ai/llm/server
git commit -m "feat(llm): swap the served model to LFM2.5-8B-A1B"
git push -u origin feat/llm-server-lfm2.5
gh pr create --base main --label area/cluster --label enhancement --title "feat(llm): swap the served model to LFM2.5-8B-A1B" \
  --body "Supersedes #5346 (do not merge that one — it only restores Gemma). Replaces Gemma 4 26B-A4B with LFM2.5-8B-A1B (UD-Q6_K_XL, 7.21 GiB) based on the 2026-09-28 spike: smaller footprint (8.5-8.9 vs 10.2-12.2 GiB), faster (26.7 vs 15-16 tok/s), survived the concurrency test that OOM-killed Gemma, same 15/15 quality score. Sets replicaCount back to 1. Adds --reasoning-budget 0 since this model cannot disable chain-of-thought the way Gemma could (verification of that flag is Task 2 of docs/superpowers/plans/2026-09-28-llm-model-swap-lfm2.5.md, done before this is safe to merge)."
```

**Do not merge this PR until Task 2 has verified `--reasoning-budget 0` actually suppresses the chain-of-thought overhead.** Leave it open/draft until then.

---

### Task 2: Verify reasoning behavior — budget, growth under context, and per-call control (blocks Task 1's merge)

**Why this task is wider than "does the flag work":** [nousresearch/hermes-agent#9344](https://github.com/NousResearch/hermes-agent/issues/9344) documents a generic reasoning-model failure mode (reported against a different, cloud model — GLM-5-Turbo — nothing to do with `reasoning_effort`/`reasoning_overrides` or a local provider, but the mechanism is architecture-agnostic): as conversation context grows, a reasoning model allocates *progressively more* tokens to thinking, not a fixed per-call overhead. At ~53K tokens of accumulated context with a 16K output budget, reasoning alone consumed the whole budget and every reply came back empty (`finish_reason: length`). Their own recovery made it worse — retries appended more reasoning-only history, growing context further, and compression only fired *after* the failure. **This is a direct risk for us**, because this plan points both the main conversation *and* the `compression` task (Hermes's own rescue mechanism for an overgrown conversation) at the same always-reasoning model — if reasoning growth eats the compression call's budget too, there is no rescue path left. `--reasoning-budget` is a hard server-side cap, unlike relying on the model to self-regulate, and should structurally prevent this — but that must be verified under real context growth, not assumed from a short-prompt test.

**Files:**
- Create (scratch, not committed): `/tmp/lfm_reasoning_check.py`, `/tmp/lfm_reasoning_growth.py`

**Interfaces:**
- Consumes: a live `llama-server` running LFM2.5 (deploy Task 1's branch to a throwaway pod exactly like the 2026-09-28 spike, or merge Task 1 and test on the real Deployment if you're comfortable — either works, this task is read-only against whichever is running).
- Produces: a go/no-go verdict for Task 1's merge; the working `reasoningBudget` value; a decision on whether the main model and the aux tasks can run different reasoning policies on this one server, or must share one.

- [ ] **Step 1: Aux-shaped calls — does a budget suppress reasoning enough for small `max_tokens`?**

```python
#!/usr/bin/env python3
"""Step 1: does --reasoning-budget suppress LFM2.5's chain-of-thought the way
Gemma's enable_thinking=false did, for the short, low-max_tokens calls the 7
local aux tasks make?"""
import json, urllib.request

URL = "http://localhost:18100/v1/chat/completions"  # port-forward to the test server first
MODEL = "lfm2.5-8b-a1b"


def chat(max_tokens=400):
    body = {"model": MODEL, "max_tokens": max_tokens,
            "messages": [{"role": "system", "content": "Write a concise title (at most 8 words, no quotes) for this conversation."},
                         {"role": "user", "content": "user: my GPU pod is pending on the jetson node\nassistant: the device plugin lost registration after a kubelet restart"}]}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        d = json.load(r)
    m = d["choices"][0]["message"]
    return d["usage"]["completion_tokens"], len(m.get("reasoning_content") or ""), (m.get("content") or "").strip()


for i in range(3):
    ct, rc, content = chat()
    print(f"run{i+1}: completion_tokens={ct} reasoning_chars={rc} content={content!r}")
```

Run it (port-forward first: `kubectl -n llm port-forward pod/<the-test-pod-or-svc> 18100:8080`).

**Expected if `--reasoning-budget 0` works:** `completion_tokens` in the same range as Gemma's thinking-off numbers (single digits to ~10), `reasoning_chars` near 0, and `content` still a valid title. **If it doesn't work** (reasoning_chars stays in the 400-2000 range seen in the spike): try `--reasoning-budget 64` or `128` and re-run; find the smallest value that still produces a correct, non-empty `content`.

- [ ] **Step 2: Does the budget hold as a HARD cap when context is large? (the #9344 regression test)**

```python
#!/usr/bin/env python3
"""Step 2: reproduce the shape of nousresearch/hermes-agent#9344 — does
reasoning-token consumption grow with prompt/context size, and does
--reasoning-budget actually cap it regardless, or does it degrade the same
way GLM-5-Turbo did? Run at increasing context sizes and at a couple of
--reasoning-budget values (set via server restart between rounds, or run
one round per throwaway pod if you want them side by side)."""
import json, urllib.request

URL = "http://localhost:18101/v1/chat/completions"
MODEL = "lfm2.5-8b-a1b"
MAX_TOKENS = 500  # deliberately modest, like a real conversational turn budget


def chat(context_tokens_approx, max_tokens=MAX_TOKENS):
    filler = " ".join(f"Section {i}: the scheduler places pods on nodes based on resource requests, affinity and taints, item {i*7}."
                       for i in range(max(1, context_tokens_approx // 28)))  # ~28 tokens/sentence, rough
    body = {"model": MODEL, "max_tokens": max_tokens,
            "messages": [{"role": "user", "content": filler + "\nGiven the above, in one sentence, what should I check first if a pod is stuck Pending?"}]}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    m = d["choices"][0]["message"]
    return {"prompt_tokens": d["usage"]["prompt_tokens"], "completion_tokens": d["usage"]["completion_tokens"],
            "reasoning_chars": len(m.get("reasoning_content") or ""), "content_empty": not (m.get("content") or "").strip(),
            "finish_reason": d["choices"][0]["finish_reason"]}


for target in (1_000, 8_000, 20_000, 40_000, 55_000):
    print(target, chat(target))
```

Run this **at whatever `reasoningBudget` value Step 1 landed on** (not unrestricted — the whole point is to check the cap holds). **Pass:** `content_empty` is `False` and `finish_reason` is `"stop"` (not `"length"`) at every context size, and `reasoning_chars`/`completion_tokens` stay roughly flat rather than growing with `prompt_tokens`. **Fail (the #9344 pattern):** `content_empty` becomes `True` and `finish_reason` becomes `"length"` at larger context sizes, or `completion_tokens` climbs toward `max_tokens` as context grows — this means `--reasoning-budget` is a *soft* hint, not a hard cap, for this model/build, and you cannot trust a fixed `max_tokens` for either the main model or `compression` regardless of the budget value. If it fails, try a smaller budget (e.g. half of Step 1's value) and re-run the full sweep before concluding it's broken — don't stop at one data point.

- [ ] **Step 3: If Step 2 fails at any budget, do not proceed with `compression` on this model**

The compression task is Hermes's rescue mechanism for exactly the large-context scenario Step 2 tests. If it can't reliably produce non-empty output at 40-55K tokens of context, pointing `compression` at LFM2.5 recreates #9344's compounding failure (the rescue mechanism fails at the same time it's needed most). In that case: keep `compression` on the cloud (revert that part of Task 4), and record this as a ruling — LFM2.5 is usable for the main model and the other aux tasks, but not for compression, until upstream fixes make `--reasoning-budget` a true hard cap.

- [ ] **Step 4: Context-compounding check — already answered, confirm it still holds**

Checked directly against the pinned Hermes image (`v2026.9.24`) before writing this plan: `agent/message_sanitization.py`'s `_REASONING_ECHO_RULES` only requires reasoning-content echo-back for the `kimi`, `deepseek`, and `mimo` provider families (matched by provider name, model substring, or host). Everything else — including our `custom` provider pointing at `llama-server`/`lfm2.5-8b-a1b` — is on the "strict" side, where `apply_reasoning_content_policy` strips `reasoning_content` from replayed history entirely (`agent/message_sanitization.py:635-667`). **So reasoning traces do not compound into context turn-over-turn for our config** — each turn's reasoning cost is paid once and discarded, it doesn't inflate the next turn's prompt. Re-run this grep against whatever Hermes image tag is actually live before trusting it (Renovate bumps this image; the rule table could change):

```bash
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c \
  'grep -n "_REASONING_ECHO_RULES" -A6 /opt/hermes/agent/message_sanitization.py'
```

Expected: `lfm`/`liquid`/`custom` is not one of the listed families (kimi/deepseek/mimo). If a future Hermes version adds LFM2.5 to the echo-back list, re-evaluate — that would mean reasoning does compound and the growing-context risk in Step 2 gets worse, not just from the model's own behavior but from replayed history too.

- [ ] **Step 5: Can the main model and the aux tasks run different reasoning policies on one server?**

`--reasoning-budget` is a server-startup flag — one value for the whole server. Hermes has two *client-side* levers that might let the main model ask for something different per call: `agent.reasoning_effort` / `agent.reasoning_overrides.<model>` (main agent, resolved in `hermes_constants.resolve_reasoning_config`) and `auxiliary.<task>.reasoning_effort` (aux tasks, already in use elsewhere in this repo). Test whether either one actually changes LFM2.5's behavior for a `custom` provider (it may be a no-op if Hermes only wires `reasoning_effort` for providers with a recognized reasoning wire shape — OpenAI, Anthropic, DeepSeek — and not for generic OpenAI-compatible custom endpoints):

```bash
# from the Hermes pod, or via direct curl to the test server with the same body shape Hermes would send:
curl -s localhost:18101/v1/chat/completions -d '{"model":"lfm2.5-8b-a1b","max_tokens":500,"reasoning_effort":"low","messages":[{"role":"user","content":"What is 17*23?"}]}' | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["usage"]["completion_tokens"], len(d["choices"][0]["message"].get("reasoning_content") or ""))'
# compare against the same call with reasoning_effort omitted, and with {"chat_template_kwargs":{"thinking_budget":64}} instead
```

**If neither changes the output measurably:** there is no per-call override for this model on this server build — the server's one `--reasoning-budget` value has to serve both the main model and the aux tasks. Pick the value that keeps aux tasks correct (Step 1's finding) even if that's not the ideal value for main-model quality, and record this as a ruling. **If one does work:** set the server default to the aux-safe value (Step 1), and configure `agent.reasoning_overrides.lfm2.5-8b-a1b` (or the equivalent per-task `extra_body`) to request a higher budget for the main model specifically — record the exact config key used, since it isn't yet documented anywhere in this repo.

- [ ] **Step 6: Main-model-shaped quality check, at whatever policy Steps 1-5 landed on**

Reuse `tool_par.json`-style multi-tool prompts and a short multi-turn conversation (3-4 turns, each referencing the previous answer) at the chosen budget. Confirm tool calls stay well-formed (`parallel_tool_calls: true`, same as the 2026-09-28 spike's clean 3/3 result) and that answers remain coherent across turns. This is a lighter-weight sanity check than Step 2 — Step 2 is the one that must pass; this one confirms nothing regressed on ordinary use.

- [ ] **Step 7: Record the outcome and un-gate Task 1's PR**

Write down: the final `reasoningBudget` value, whether `compression` stays on LFM2.5 or moves to the cloud (Step 3), and whether a per-call override exists for the main model (Step 5) — in the PR description and in whatever ledger tracks this plan. Once recorded, remove Task 1's PR's draft/hold status and merge it.

---

### Task 3: Concurrent, near-max-context memory test (before touching Hermes/Honcho)

**Files:**
- Create (scratch, not committed): `/tmp/lfm_concurrent_max.py`

**Interfaces:**
- Consumes: the merged Task 1 Deployment, live and `Running`.
- Produces: a go/no-go verdict for Tasks 4 and 5, and (if it fails) a corrected `resources.limits.memory` / `cacheRam` / `ctxCheckpoints` for Task 1.

- [ ] **Step 1: Confirm the pod is healthy and idle-baseline memory**

```bash
kubectl -n llm get pod -l app=llama-server
kubectl -n llm top pod -l app=llama-server
kubectl -n llm logs deploy/llama-server -c llama-server | grep -E "ggml_cuda_init|offloaded|KV buffer|listening"
```

Expected: `ggml_cuda_init` succeeds, all layers offloaded, pod `Running`, memory close to the spike's ~8.5-8.9 GiB baseline.

- [ ] **Step 2: Fire concurrent near-64K-token requests on both slots, repeatedly**

```python
#!/usr/bin/env python3
"""Task 3: reproduce the exact failure mode from the 2026-09-28 Gemma OOM —
concurrent requests on both slots — but with each prompt near the real
65536-token slot ceiling, repeated several times to catch cumulative growth
(cache-ram, checkpoints) that a single pair of requests would miss."""
import json, threading, time, urllib.request, subprocess

URL = "http://localhost:18101/v1/chat/completions"
MODEL = "lfm2.5-8b-a1b"
BIG_DOC = " ".join(f"Section {i}: the scheduler places pods on nodes based on resource requests, affinity and taints, item {i*7}." for i in range(1800))  # ~53k tokens


def mem():
    top = subprocess.run("kubectl -n llm top pod -l app=llama-server --no-headers", shell=True, capture_output=True, text=True).stdout.split()
    return top[2] if len(top) > 2 else "?"


def call(name, results):
    body = json.dumps({"model": MODEL, "max_tokens": 300,
                        "messages": [{"role": "user", "content": BIG_DOC + "\nIn one sentence, what is this text about?"}]}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            data = json.load(r)
        results[name] = {"seconds": round(time.time() - t0, 1), "prompt_tokens": data["usage"]["prompt_tokens"]}
    except Exception as exc:
        results[name] = {"error": str(exc)}


for round_n in range(4):
    results = {}
    threads = [threading.Thread(target=call, args=(f"r{round_n}_{i}", results)) for i in range(2)]
    for t in threads: t.start()
    for t in threads: t.join()
    print(f"round {round_n}:", json.dumps(results), "mem=", mem())
```

Run: `kubectl -n llm port-forward svc/llama-server 18101:8080 & PF=$!; sleep 3; python3 /tmp/lfm_concurrent_max.py; kill $PF`

Also watch the node during the run: `watch -n5 'talosctl -n 192.168.48.5 read /proc/meminfo | grep MemAvailable'` (`TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig`).

**Expected:** all 8 requests (4 rounds × 2) succeed with no `error` key, pod has 0 restarts throughout (`kubectl -n llm get pod -l app=llama-server` unchanged `RESTARTS` column), node `MemAvailable` never drops below the `Nv1MemoryLow` alert threshold (400 MiB) — ideally staying well above it. **If it OOMs or comes close:** lower `resources.limits.memory` is not the fix (that caused the earlier OOM-kill-too-early mistake) — instead reduce `cacheRam` further (e.g. 128), `ctxCheckpoints` to 1, or consider `-np 1 -c 65536` (one slot) as the fallback, same options documented in the original 64K-floor PR (#5318).

- [ ] **Step 3: Record the result**

Whatever the outcome, record it (ledger, PR comment, or this plan's tracking doc) before proceeding to Task 4 — this is the check that was skipped for Gemma and caused the incident this plan exists to fix.

---

### Task 4: Point Hermes' main model, compression, and 7 local aux tasks at LFM2.5

**Files:**
- Modify: `cluster/apps/ai/hermes-agent/values.yaml`
- Modify: `cluster/apps/ai/hermes-agent/README.md`

**Interfaces:**
- Consumes: Task 1 (merged) + Task 2 (verified) + Task 3 (passed).
- Produces: default profile + 6 worker profiles' `model` and `auxiliary.compression` → `custom`/`lfm2.5-8b-a1b`; `web_extract`, `approval`, `title_generation`, `triage_specifier`, `kanban_decomposer`, `profile_describer`, `curator` → same model id (only the id changes; provider/base_url/api_key are already `custom`/llama-server/`local` from #5300).

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/hermes-lfm2.5
```

- [ ] **Step 2: Update every `model: gemma-4-26b-a4b` reference**

```bash
grep -n 'gemma-4-26b-a4b' cluster/apps/ai/hermes-agent/values.yaml
```

For each match under `hermes.config.model`, `hermes.config.auxiliary.*`, and `hermes.config.profileOverlays.researcher` (the `&localMainModel`/`&cloudMainModel` anchor — check which name is currently live and keep the same anchor name), change `default: gemma-4-26b-a4b` / `model: gemma-4-26b-a4b` to `lfm2.5-8b-a1b`. **Set every key explicitly** (`provider: custom`, `base_url: http://llama-server.llm.svc.cluster.local:8080/v1`, `api_key: local`, `context_length: 65536`) even where only the model id actually changed — do not rely on the old values already being correct on the PVC (the #5318 lesson: the seeder only adds/overwrites, so if this plan is applied out of order or partially, stale keys must not survive).

- [ ] **Step 3: Update the README**

In the "Local inference" section of `cluster/apps/ai/hermes-agent/README.md`, replace every mention of `gemma-4-26b-a4b` / "Gemma 4 26B-A4B" with `lfm2.5-8b-a1b` / "LFM2.5-8B-A1B", and add a line noting it always emits chain-of-thought (suppressed server-side via `--reasoning-budget`, see `docs/src/k8s/nv1-jetson.md`) instead of the `enable_thinking` toggle Gemma used.

- [ ] **Step 4: Verify and commit**

```bash
helm template hermes cluster/apps/ai/hermes-agent > /tmp/hermes.yaml && echo "helm OK"
grep -c 'gemma-4-26b-a4b' /tmp/hermes.yaml   # expect 0
grep -c 'lfm2.5-8b-a1b' /tmp/hermes.yaml     # expect >= 8 (default + 6 profiles + compression, roughly)
git add cluster/apps/ai/hermes-agent
git commit -m "feat(hermes): point the main model, compression and local aux tasks at LFM2.5-8B-A1B"
git push -u origin feat/hermes-lfm2.5
gh pr create --base main --label area/cluster --label enhancement --title "feat(hermes): point Hermes at LFM2.5-8B-A1B" \
  --body "After Tasks 1-3 of docs/superpowers/plans/2026-09-28-llm-model-swap-lfm2.5.md passed. Forward-overwrites provider/base_url/api_key/context_length everywhere so no stale gemma-4-26b-a4b config survives on the PVC."
```

- [ ] **Step 5: After merge (CONFIRM refresh), verify with real chat turns**

```bash
kubectl rollout status deploy/hermes-agent -n hermes-agent --timeout=300s
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c \
  "cd /opt/hermes && export PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:\$PATH && hermes chat -q 'Reply with the single word: pong'"
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c \
  "cd /opt/hermes && export PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:\$PATH && hermes -p devops chat -q 'Reply with the single word: pong'"
```

Expected: both answer "pong" without falling back to the cloud (check `kubectl -n llm logs deploy/llama-server -c llama-server --since=2m | grep 'POST /v1'` shows the request landed locally). This is the check that was skipped before #5314 broke Hermes the first time — do not skip it here either.

---

### Task 5: Point Honcho's 5 local model slots at LFM2.5

**Files:**
- Modify: `cluster/apps/ai/honcho/values.yaml` (or wherever `DERIVER_MODEL_CONFIG__MODEL` etc. are templated — check `cluster/apps/ai/honcho/templates/`)
- Modify: `cluster/apps/ai/honcho/README.md`

**Interfaces:**
- Consumes: Task 1 (merged) + Task 2 (verified) + Task 3 (passed). Independent of Task 4 (can be done in either order, or in parallel).
- Produces: `DERIVER_MODEL_CONFIG__MODEL`, `SUMMARY_MODEL_CONFIG__MODEL`, `DIALECTIC_LEVELS__{minimal,low,medium}__MODEL_CONFIG__MODEL` → `lfm2.5-8b-a1b` (transport/base_url already point at `llama-server` from #5297).

- [ ] **Step 1: Branch and find the exact env var source**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/honcho-lfm2.5
grep -rn 'gemma-4-26b-a4b' cluster/apps/ai/honcho/
```

- [ ] **Step 2: Replace every occurrence, verify, commit**

```bash
# edit the matched file(s) — replace gemma-4-26b-a4b with lfm2.5-8b-a1b in the 5 slots
helm template honcho cluster/apps/ai/honcho > /tmp/honcho.yaml && grep -c 'lfm2.5-8b-a1b' /tmp/honcho.yaml   # expect 5
git add cluster/apps/ai/honcho
git commit -m "feat(honcho): point local model slots at LFM2.5-8B-A1B"
git push -u origin feat/honcho-lfm2.5
gh pr create --base main --label area/cluster --label enhancement --title "feat(honcho): point Honcho at LFM2.5-8B-A1B" \
  --body "Deriver, summary and dialectic minimal/low/medium now use lfm2.5-8b-a1b instead of gemma-4-26b-a4b. Transport/base_url unchanged (still llama-server.llm.svc.cluster.local:8080/v1)."
```

- [ ] **Step 3: After merge (CONFIRM refresh), verify**

```bash
kubectl -n honcho rollout status deploy/honcho-api --timeout=200s
kubectl -n honcho rollout status deploy/honcho-deriver --timeout=200s
kubectl -n honcho get deploy honcho-deriver -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | grep MODEL_CONFIG__MODEL
```

---

### Task 6: Re-baseline the CPU-fallback alert threshold for LFM2.5

**Files:**
- Modify (only if the measured number differs meaningfully): `cluster/apps/ai/llm/server/templates/prometheusrule.yaml`

**Interfaces:**
- Consumes: `llama-server` running LFM2.5 in steady state (after Task 4/5 are live and getting real traffic for at least a few hours).

- [ ] **Step 1: Measure real GPU-mode CPU usage**

```bash
kubectl -n llm port-forward svc/prometheus-operated 19090:9090 -n monitoring & PF=$!; sleep 3
curl -s -G localhost:19090/api/v1/query --data-urlencode 'query=max_over_time((rate(container_cpu_usage_seconds_total{namespace="llm",container="llama-server"}[5m]))[6h:1m])' | jq .
kill $PF
```

- [ ] **Step 2: Compare against the `LlamaServerOnCpu` threshold (`> 3` cores)**

If LFM2.5's GPU-mode peak is comfortably below 3 cores (expected, given it's a smaller/faster model), leave the alert as-is — it was already calibrated with margin for Gemma (0.2-1.2 GPU-mode vs ~7 CPU-fallback). If it's not (e.g. LFM2.5's architecture is more CPU-hungry for some reason even on GPU), adjust the threshold and re-verify against a deliberate CPU-fallback test (temporarily point the image tag at a CUDA-13 build to force CPU mode, confirm the alert fires, then revert — or skip this negative test if it feels too risky and just document the assumption).

---

### Task 7: Clean up — old model blob, docs, memory notes

**Files:**
- Modify: `docs/src/k8s/nv1-jetson.md` (memory budget numbers, model name)
- Modify: `.claude/memory/reference_llama_server_nv1_memory.md`, `.claude/memory/reference_hermes_64k_context_floor.md`
- Delete (on the live PVC, not git): the old Gemma GGUF blob

- [ ] **Step 1: Free the old model file from the PVC**

```bash
kubectl -n llm exec deploy/llama-server -c llama-server -- ls -la /models
kubectl -n llm exec deploy/llama-server -c llama-server -- rm -f /models/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf /models/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf.ok
kubectl -n llm exec deploy/llama-server -c llama-server -- df -h /models
```

(**CONFIRM with the owner before deleting** — irreversible, though the file is re-downloadable from HuggingFace if ever needed again.)

- [ ] **Step 2: Update the nv1 runbook's memory-budget section**

Replace the Gemma-specific numbers in `docs/src/k8s/nv1-jetson.md`'s "Memory budget (llama-server)" section with LFM2.5's measured figures from Tasks 1-3 (idle baseline, concurrent-test result, the final `resources.limits.memory` value). Update the "Rules for GPU images" section if the model name is mentioned there.

- [ ] **Step 3: Update memory notes**

`reference_llama_server_nv1_memory.md`: update the model name and the measured numbers; keep the general lesson (llama-server's cache/checkpoint defaults starve the node) since that's model-agnostic.
`reference_hermes_64k_context_floor.md`: update the model name; the 64K-floor lesson itself is unchanged.
Add a new note (or extend an existing one) recording that LFM2.5 is "reasoning-only" and needs `--reasoning-budget`, not `chat_template_kwargs.enable_thinking`, to control chain-of-thought overhead — this is a genuinely different lesson from the Gemma one and the next person to swap models again will hit it.

- [ ] **Step 4: Commit and open the PR**

```bash
git add docs/src/k8s/nv1-jetson.md .claude/memory
git commit -m "docs: update nv1 runbook and memory notes for the LFM2.5 swap"
git push -u origin docs/llm-lfm2.5-cleanup
gh pr create --base main --label docs --title "docs: update nv1 runbook and memory notes for the LFM2.5 swap"
```

---

### Task 8: Close out the spike branches and do a final acceptance pass

- [ ] **Step 1: Close #5346** (restore-Gemma revert) as superseded, without merging it — Task 1 already set `replicaCount: 1` with the new model in place, so restoring Gemma first was never necessary.
- [ ] **Step 2: Final acceptance (read-only + one real interaction)**
  - `kubectl -n llm get pod -l app=llama-server` — 0 restarts since Task 1 merged.
  - `kubectl -n llm top pod -l app=llama-server` and the node's `MemAvailable` — comfortably within budget after a day of real (not synthetic) Hermes/Honcho traffic.
  - Send one real message to Hermes (Discord, since Signal is currently disabled per a separate unrelated change) and confirm a normal, correctly-tool-calling response.
  - Check `kubectl -n llm logs deploy/llama-server -c llama-server --since=24h | grep -ci -E "error|failed"` is low/zero.
- [ ] **Step 3: Record the outcome** in whatever ledger or PR discussion you're using to track this plan, including the final `reasoningBudget` and `resources.limits.memory` values landed on — the next person (or a future you) needs these numbers without re-deriving them.
