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

1. **Reasoning suppression for small-budget calls.** If `--reasoning-budget 0` (or an equivalent) does not actually shrink LFM2.5's output the way Gemma's `enable_thinking=false` did, every one of Hermes's 7 local aux tasks and Honcho's 5 local slots gets slower and more expensive the moment this rolls out — a regression a real user would notice immediately as "Hermes feels slower now." Task 2 must measure completion-token counts before and after, not just check the response is non-empty.
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

### Task 2: Verify reasoning suppression (blocks Task 1's merge)

**Files:**
- Create (scratch, not committed): `/tmp/lfm_reasoning_check.py`

**Interfaces:**
- Consumes: a live `llama-server` running LFM2.5 with `--reasoning-budget 0` (deploy Task 1's branch to a throwaway pod exactly like the 2026-09-28 spike, or merge Task 1 and test on the real Deployment if you're comfortable — either works, this task is read-only against whichever is running).
- Produces: a go/no-go verdict for Task 1's merge, and (if budget 0 is too aggressive) the actual working value for `reasoningBudget`.

- [ ] **Step 1: Compare token cost with and without the budget**

```python
#!/usr/bin/env python3
"""Task 2: does --reasoning-budget suppress LFM2.5's chain-of-thought the way
Gemma's enable_thinking=false did? Compare completion_tokens for the same
trivial prompt at a few budget values."""
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

**Expected if `--reasoning-budget 0` works:** `completion_tokens` in the same range as Gemma's thinking-off numbers (single digits to ~10), `reasoning_chars` near 0, and `content` still a valid title. **If it doesn't work** (reasoning_chars stays in the 400-2000 range seen in the spike): try `--reasoning-budget 64` or `128` (a small but non-zero budget) and re-run; find the smallest value that still produces a correct, non-empty `content`. Record whatever value you land on in `server.reasoningBudget` (Task 1's values.yaml) and in the PR description before merging.

- [ ] **Step 2: If no budget value works, stop and report**

If even a moderate budget (e.g. 256) still produces empty `content` (the same failure mode Gemma had with thinking on and a small `max_tokens`), the fallback is **not** to ship LFM2.5 for the 7 local aux tasks — keep those on Gemma or on the cloud, and only use LFM2.5 for the main model / compression (which already use larger `max_tokens` budgets and tolerate more reasoning overhead). Record this as a ruling in whatever ledger you're tracking this plan under, and adjust Task 4 accordingly (skip re-pointing the aux tasks).

- [ ] **Step 3: Un-gate Task 1's PR**

Once you have a working `reasoningBudget` value and it's reflected in Task 1's branch, remove the draft/hold status and merge it.

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
