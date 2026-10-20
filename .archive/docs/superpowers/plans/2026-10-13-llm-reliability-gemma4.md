# Reliable Local LLM: Gemma 4 26B-A4B at One Slot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the multi-turn corruption (reasoning leaked into replies, mid-sentence truncation; 29.0% under real Hermes traffic on LFM2.5) by serving a non-hybrid model, Gemma 4 26B-A4B (UD-Q2_K_XL), at one slot, and prove it with a same-session measurement before swapping.

**Architecture:** Two phases with a hard gate between them. **Phase A** is a measurement: pause `llama-server` through git, run Gemma 4 as a throwaway pod labelled `app: llama-server` (so Hermes and Honcho reach it through the existing Service with no change), drive real Hermes traffic through it, resume production. **Phase B** runs only if the gate passes: one PR that changes the served model and the 15 consumer references, rolled out and re-verified. Gemma 4 has no recurrent state, so it is outside the llama.cpp#29002 bug class by architecture; `-np 1` removes the co-batching trigger regardless.

**Tech Stack:** `ghcr.io/mmalyska/llama-cpp-jetson:v0.6.0` (pinned digest, JetPack 7 / CUDA 13), `unsloth/gemma-4-26B-A4B-it-GGUF`, Helm chart `cluster/apps/ai/llm/server`, Hermes (`cluster/apps/ai/hermes-agent`), Honcho (`cluster/apps/ai/honcho`), kubectl/talosctl, Python 3 stdlib.

**Spec:** none; the decision record is the 2026-10-13 design discussion. Context: `.plans/TODO.md` (#29002 tracking, 29.0% real-traffic measurement, `-np 1` + `--ctx-checkpoints 0` = 5.0%), `docs/src/k8s/nv1-jetson.md` (memory budget, Qwen3.6 result), `.archive/docs/superpowers/plans/2026-09-28-llm-model-swap-lfm2.5.md` (the swap this reverses), `.claude/memory/reference_nv1_gpu_test_pause.md` (pause procedure).

## Why this model and this shape

| Fact                                                                                                                                                                                                                                                                        | Source                                                       |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| llama.cpp#29002 (hybrid co-batching corrupts recurrent state) is **open, no fix PR**; #28007 / #29918 / #25004 are open; by merge date v0.6.0 (upstream 2026-10-05) holds #27530 and #29856 and only #26004 is newer; none of them is the bug (build contents not verified) | checked 2026-10-13                                           |
| LFM2.5: 29.0% corrupt (n=100, real Hermes traffic, `-np 2`, 4 checkpoints); 5.0% (n=180) at `-np 1`, `--ctx-checkpoints 0`                                                                                                                                                  | `.plans/TODO.md`                                             |
| Qwen3.5/3.6 are the same hybrid class and do not fit nv1 anyway                                                                                                                                                                                                             | `docs/src/k8s/nv1-jetson.md`                                 |
| Gemma 4 26B-A4B Q2_K_XL: 9.82 GiB, ~15 tok/s, 15/15 aux probes, 5/5 clean parallel tool calls, was production until 2026-09-30                                                                                                                                              | `.archive/docs/superpowers/plans/2026-09-28-llm-model-swap-lfm2.5.md` |
| Its only failure was memory: OOM-killed at `anon-rss 13.78 GB` at `-c 131072 -np 2` under 3 concurrent `hermes chat` calls; steady 11.8-12.2 GiB with 1.3 GiB node headroom at `-c 65536 -np 2`                                                                             | same + `nv1-jetson.md`                                       |

`-c 65536 -np 1` keeps the KV buffer at the size that was stable (about 620 MiB, half of the 131072 figure that OOM'd) and gives the single slot 65536 tokens, which clears Hermes' 64,000 floor.

## Candidate file (verified from the Hugging Face tree API, 2026-10-13)

| File                                 |       Bytes |  GiB | SHA-256                                                            |
| ------------------------------------ | ----------: | ---: | ------------------------------------------------------------------ |
| `gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf` | 10546934240 | 9.82 | `2a1d26dfe6ea00a467940a5728316af6edb366bbdba950d65b85d232392fb658` |

URL: `https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf`. The PVC (30Gi) holds LFM2.5 (7.21 GiB) plus this (9.82 GiB) = 17 GiB. The QAT Q4 variant (14.2 GB) does not fit nv1 and is not considered.

## Global Constraints

- **Never mutate cluster state without explicit user confirmation** (CLAUDE.md): every `kubectl apply/delete/annotate`, every merge and Argo refresh is preceded by asking.
- The pause is **git-only** (`server.replicaCount: 0`, marked TEMPORARY); `kubectl scale` and `selfHeal` patches do not stick. Only one GPU pod at a time.
- **Memory limits stay `13Gi` limit / `9Gi` request** (a limit above ~13.4 GiB gives no protection; node starves first). Memory gate: pod working set <= 12.5 GiB **and** node `MemAvailable` >= 0.5 GB at every sample. The owner accepted the 0.6-0.7 GB steady state measured on Gemma 4 (2026-10-15), so the original 0.8 GB bar is waived; 0.5 GB stays as the abort floor (the Qwen3.6 run sat at 0.4 GB idle and was stopped).
- Hermes needs `ctx / parallel >= 64000` per slot and `model.context_length` equal to the real per-slot size (65536 here). The profile seeders only add or overwrite keys: on any consumer move, set `provider`, `default`, `base_url`, `api_key` and `context_length` explicitly.
- Image stays the pinned `llama-cpp-jetson:v0.6.0` digest; a newer build is a separate change.
- Gemma thinks by default and its reasoning eats `max_tokens`: the server default is `--chat-template-kwargs '{"enable_thinking":false}'`. The chart always renders `--reasoning-budget`, so Gemma sets `reasoningBudget: -1` (unrestricted; `0` is broken on this build per the LFM2.5 spike).
- Downtime is expected during Phase A: `LlamaServerUnavailable` goes critical after 10 minutes and Hermes/Honcho fall back to cloud. Budget **about 2-3 hours** (real Hermes turns are long and serialize through one slot); have the resume PR ready before pausing and consider doing it overnight.
- No secrets, no private domain literal, no Claude attribution in commits or PR bodies.

## Review Focus

1. **One slot serializes everything.** Hermes main turns, 8 aux tasks and Honcho's deriver/summary/dialectic all queue behind each other. A deferred request that times out falls back to the cloud (cost and latency, not an outage), but a p95 turn latency that doubles is the real cost of this plan. Task 4 measures p50/p95 per turn and the Prometheus `llamacpp:requests_deferred` peak; the gate caps p95 at 2x the baseline arm.
2. **Memory is the old failure.** The OOM was at `-np 2 -c 131072` under concurrent turns. The new shape has half the KV, but 4 profiles alternating in one slot also thrash the host-RAM prompt cache (`--cache-ram 256`, ~3 entries of 70-86 MiB). Watch for reprocessing-driven latency, not just RSS.
3. **Q2 tool-calling and quality for the main model.** LFM2.5 was chosen partly for aux cost; Gemma 4 at 2-bit must hold up for Hermes' main-model tool calls. The Hermes harness counts non-zero exits and the quality probe covers tool calls; a corrupt-looking reply that is really a failed tool call must be distinguished in the logs.
4. **Stale config on the PVC.** Hermes profile overlays are merged on every start but never delete keys; a profile still carrying `lfm2.5-8b-a1b` would 404 against Gemma. Task 7 greps the live config in the pod, not just git.
5. **Thinking mode.** Server-side thinking is off; a request can opt in. Small-budget calls (titles, Honcho deriver) must return content with thinking off. Quality probes include 5 title calls with `max_tokens: 32`.

## Decision gates

**Gate A (Phase A to Phase B), all must hold for the Gemma arm:**

| Gate       | Pass                                                                                                                                                |
| ---------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Corruption | <= 1 corrupt in >= 100 real Hermes turns (95% upper bound about 5%), and strictly below arm B / C if those were run                                 |
| Fits       | pod <= 12.5 GiB and node `MemAvailable` >= 0.5 GB at every sample (owner accepted 0.6-0.7 GB steady state on 2026-10-15; 0.5 GB is the abort floor) |
| Speed      | single-stream generation >= 12 tok/s with the slot busy                                                                                             |
| Latency    | Hermes p95 turn <= 2x arm C p95 if C was run, otherwise <= 180 s                                                                                    |
| Quality    | `probe.py quality` >= 19/20 and `hermes chat -q "ping"` answers                                                                                     |

**Ambiguous result (1 < corrupt <= 5 of 100):** run arm B and arm C in the same window for the contrast before deciding. **Fail (corrupt > 5, or fits fails):** stop, record, and keep LFM2.5 at `-np 1`/`--ctx-checkpoints 0` as the documented mitigation (a config-only PR).

---

## Phase A: measure

### Task 1: Artifacts and prefetch (no downtime)

**Files:**

- Create (already in this PR): `.archive/docs/superpowers/plans/artifacts/2026-10-13-llm-reliability/server-pod.yaml`, `hermes-corruption.py` (multi-turn, tool-calling; replaces the retired single-turn `.sh`)
- Reuse: `.archive/docs/superpowers/plans/artifacts/2026-10-13-qwen3.6-bench/{prefetch-pod.yaml,probe.py,load.py}`

**Interfaces:**

- Consumes: the running `llama-server` and the `llama-server-models` PVC (30Gi, 7.2 GiB used).
- Produces: `/models/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf` and its `.ok` marker on the PVC.

- [ ] **Step 1: Read-only checks**

```bash
kubectl -n llm get deploy llama-server
kubectl -n llm get pvc llama-server-models
kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- ls /opt/data/profiles
```

Expected: 1/1, PVC Bound 30Gi, a list of profile names (note them for Task 4).

- [ ] **Step 2: Ask the user, then prefetch the Gemma file**

```bash
W=.archive/docs/superpowers/plans/artifacts/2026-10-13-qwen3.6-bench
sed -e 's|__MODEL_FILE__|gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf|g' \
    -e 's|__MODEL_URL__|https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf|' \
    -e 's|__MODEL_SHA256__|2a1d26dfe6ea00a467940a5728316af6edb366bbdba950d65b85d232392fb658|g' \
    -e 's|__MODEL_SIZE__|10546934240|' $W/prefetch-pod.yaml | kubectl apply -f -
kubectl -n llm wait --for=jsonpath='{.status.phase}'=Succeeded pod/qwen-prefetch --timeout=20m
kubectl -n llm logs pod/qwen-prefetch | tail -5
kubectl -n llm delete pod qwen-prefetch --wait=true
```

Expected: `...: OK`, and `df -h /models` shows about 12 GiB free.

### Task 2: Pause and resume PRs

**Files:**

- Modify: `cluster/apps/ai/llm/server/values.yaml` (`server.replicaCount`), on two branches.

**Interfaces:**

- Produces: PR-pause (`replicaCount: 0`) and a draft PR-resume (a clean revert), both opened before the GPU is touched.

- [ ] **Step 1: Pause branch from a worktree**

```bash
git worktree add .worktrees/chore/llm-pause-gemma-reliability -b chore/llm-pause-gemma-reliability origin/main
```

In the new worktree set, in `cluster/apps/ai/llm/server/values.yaml`:

```yaml
# TEMPORARY (2026-10-13): paused for the Gemma 4 reliability measurement on
# nv1's single GPU. The resume PR restores 1. Do not leave at 0.
replicaCount: 0
```

- [ ] **Step 2: Render, commit, push, PR**

```bash
( cd cluster/apps/ai/llm/server && helm template llm-server . -f values.yaml | grep -n "replicas:" )   # expect replicas: 0
git add cluster/apps/ai/llm/server/values.yaml
git commit -m "chore(llm): pause llama-server for the Gemma 4 reliability test on nv1"
git push -u origin chore/llm-pause-gemma-reliability
gh pr create --title "chore(llm): pause llama-server for the Gemma 4 reliability test on nv1" \
  --body "Temporary: replicaCount 0 so a throwaway pod can use nv1's single GPU; a resume PR follows. Plan: .archive/docs/superpowers/plans/2026-10-13-llm-reliability-gemma4.md"
```

- [ ] **Step 3: Resume branch** (after the pause PR is on `main`): create `chore/llm-resume-after-gemma-test`, `git revert --no-edit <pause-merge-sha>`, amend the message to `chore(llm): resume llama-server after the Gemma 4 reliability test`, push, `gh pr create --draft`.

### Task 3: Pause llama-server (downtime starts)

- [ ] **Step 1: Warn the user** (2-3 h, critical alert after 10 min, cloud fallback) and get an explicit go.
- [ ] **Step 2: Merge PR-pause, refresh, confirm the GPU is free**

```bash
kubectl -n argocd annotate application llm-server argocd.argoproj.io/refresh=hard --overwrite
kubectl -n llm get deploy llama-server          # READY 0/0
kubectl describe node nv1 | grep -A8 "Allocated resources" | grep nvidia   # nvidia.com/gpu 0
```

### Task 4: The Gemma arm (decisive; about 2 h)

**Files:**

- Reuse: `server-pod.yaml` (this plan), `probe.py`, `load.py` (Qwen bench artifacts), `hermes-corruption.py` (multi-turn, tool-calling; replaces the retired single-turn `.sh`).

**Interfaces:**

- Consumes: Task 3 (GPU free), Task 1 file on the PVC.
- Produces: `QUALITY n/20`, peak pod RSS and min node `MemAvailable`, single-stream tok/s, `CORRUPTION x/y` and `LATENCY p50/p95` under real Hermes traffic.

- [ ] **Step 1: Start the arm with the production flag set for Gemma**

```bash
A=.archive/docs/superpowers/plans/artifacts/2026-10-13-llm-reliability
sed -e 's|__MODEL_FILE__|gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf|' \
    -e 's|__ALIAS__|lfm2.5-8b-a1b|' -e 's|__CTX__|65536|' -e 's|__NP__|1|' \
    -e "s|__EXTRA_ARGS__|--chat-template-kwargs '{\"enable_thinking\":false}' --cache-ram 256 --ctx-checkpoints 2|" \
    $A/server-pod.yaml | kubectl apply -f -
kubectl -n llm wait --for=condition=Ready pod/rel-server --timeout=10m
kubectl -n llm logs pod/rel-server | grep -iE "cuda|offload|n_slots|failed" | head
kubectl -n llm top pod rel-server --no-headers
TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig talosctl -n 192.168.48.5 read /proc/meminfo | grep MemAvailable
```

`--alias lfm2.5-8b-a1b` keeps Hermes and Honcho untouched during the measurement. Expected: GPU init, `n_slots = 1`, `n_ctx_slot = 65536`, idle pod about 10-11 GiB. **Stop here if idle `MemAvailable` < 0.8 GB** (the Qwen failure mode) and go to Task 5.

- [ ] **Step 2: Quality, speed, thinking**

```bash
kubectl -n llm port-forward pod/rel-server 8080:8080 >/tmp/rel-pf.log 2>&1 &
echo $! > /tmp/rel-pf.pid; sleep 4
W=.archive/docs/superpowers/plans/artifacts/2026-10-13-qwen3.6-bench
BASE=http://127.0.0.1:8080/v1 python3 -I $W/probe.py quality | tail -25
```

Expected: `QUALITY` >= 19/20. Gibberish means a CUDA 13.2 numerical issue: retry the arm once with `-ctk bf16 -ctv bf16` and record both.

- [ ] **Step 3: Memory under load (one slot: two requests queue, so each round is serial)**

```bash
cat >/tmp/rel-sampler.sh <<'EOS'
#!/bin/bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
while [ -f /tmp/rel-sampler.run ]; do
  echo "$(date +%T) $(kubectl -n llm top pod rel-server --no-headers | awk '{print $3}') $(talosctl -n 192.168.48.5 read /proc/meminfo | grep MemAvailable | awk '{print $2}')kB"
  sleep 20
done
EOS
chmod +x /tmp/rel-sampler.sh; touch /tmp/rel-sampler.run; /tmp/rel-sampler.sh >/tmp/rel-mem.log 2>&1 &
BASE=http://127.0.0.1:8080/v1 ROUNDS=2 python3 -I $W/load.py | tee /tmp/rel-load.log
```

Abort at once (kill `load.py` by PID from `ps`, not `pkill -f`) if `MemAvailable` drops below 600000 kB.

- [ ] **Step 4: Real Hermes traffic (the deciding measurement)**

```bash
# 4 profiles x 5 rounds x 5-turn conversations = 100 turns (60% need a todo tool call);
# profile names from Task 1. TOOLSETS defaults to todo: do NOT use file/terminal, which route
# over SSH to a remote host in this cluster's Hermes config.
OUT=/tmp/hermes-gemma python3 -I $A/hermes-corruption.py 5 <p1> <p2> <p3> <p4> | tee /tmp/rel-gemma.log
kill "$(cat /tmp/rel-pf.pid)"; rm -f /tmp/rel-sampler.run
sort -k2 -n /tmp/rel-mem.log | tail -3
```

Expected final lines `CORRUPTION x/100` and `LATENCY p50=.. p95=..`. Honcho traffic also reaches this pod while it runs; that is the realistic mix, leave it. Evaluate Gate A.

- [ ] **Step 5: Contrast arms (only if 1 < corrupt <= 5, or you want the same-session numbers)**

Delete `rel-server`, then repeat Steps 1-4 changing only the substitutions:

| Arm                   | `__MODEL_FILE__`                | `__CTX__` / `__NP__` | `__EXTRA_ARGS__`                                                                         |
| --------------------- | ------------------------------- | -------------------- | ---------------------------------------------------------------------------------------- |
| B: LFM2.5 mitigated   | `LFM2.5-8B-A1B-UD-Q6_K_XL.gguf` | 65536 / 1            | `--chat-template-kwargs '{}' --reasoning-budget 64 --cache-ram 2048 --ctx-checkpoints 0` |
| C: LFM2.5 as deployed | `LFM2.5-8B-A1B-UD-Q6_K_XL.gguf` | 131072 / 2           | `--chat-template-kwargs '{}' --reasoning-budget 64 --cache-ram 2048 --ctx-checkpoints 4` |

Expected C near 29%, B near 5%. Record the `LATENCY` line for C as the denominator of the latency gate.

### Task 5: Resume production (downtime ends)

- [ ] **Step 1: Ask the user, then delete the test pod and merge PR-resume**

```bash
kubectl -n llm delete pod rel-server --ignore-not-found --wait=true
kubectl -n argocd annotate application llm-server argocd.argoproj.io/refresh=hard --overwrite
kubectl -n llm rollout status deploy/llama-server --timeout=10m
kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- hermes chat -q "ping" | tail -4
```

Expected: 1/1, a reply, about 25 tok/s on the GPU.

- [ ] **Step 2: Cleanup depends on Gate A.** If it **failed**, remove the Gemma file with a one-shot pod (`rm /models/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf*`), then stop and write the results (Task 9). If it **passed**, **keep the file** (the `.ok` marker makes the swap skip the download) and continue to Phase B.

---

## Phase B: swap (only if Gate A passed)

### Task 6: Switch the served model

**Files:**

- Modify: `cluster/apps/ai/llm/server/values.yaml`

**Interfaces:**

- Consumes: Gemma file already on the PVC (marker present).
- Produces: `llama-server` serving alias `gemma-4-26b-a4b` at `-c 65536 -np 1`.

- [ ] **Step 1: Branch** `feat/llm-server-gemma4-single-slot` from `origin/main` in its own worktree.

- [ ] **Step 2: Replace the model-dependent keys** (leave `image`, `fetchImage`, `storage`, `resources.requests` alone)

```yaml
model:
  file: gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf
  url: https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf
  sha256: 2a1d26dfe6ea00a467940a5728316af6edb366bbdba950d65b85d232392fb658
  size: "10546934240"
  alias: gemma-4-26b-a4b
# One slot of 65536 tokens: clears Hermes' 64,000 floor and removes the
# co-batching trigger of llama.cpp#29002. Gemma 4 has no recurrent state, so
# the hybrid-state corruption (29.0% on LFM2.5 under real traffic) does not apply.
ctx: 65536
parallel: 1
# Server-wide default; a request can opt in with chat_template_kwargs.enable_thinking=true.
chatTemplateKwargs: '{"enable_thinking":false}'
# The chart always renders --reasoning-budget; -1 is "unrestricted" (0 breaks the parser).
reasoningBudget: -1
# Memory budget measured in Phase A; re-derive from Task 4's numbers if they moved.
cacheRam: 256
ctxCheckpoints: 2
ubatch: 256
```

- [ ] **Step 3: Render and check the flags**

```bash
( cd cluster/apps/ai/llm/server && helm template llm-server . -f values.yaml | grep -nE "gemma|\-c$|\-np|reasoning-budget|chat-template-kwargs|cache-ram|ctx-checkpoints" -A1 )
```

Expected: `-c 65536`, `-np 1`, `--reasoning-budget -1`, `--chat-template-kwargs {"enable_thinking":false}`, `--cache-ram 256`, `--ctx-checkpoints 2`.

### Task 7: Move the consumers (same PR)

**Files:**

- Modify: `cluster/apps/ai/hermes-agent/values.yaml` (10 refs: `model.default`, 8 auxiliary/overlay `model:` entries, overlay `default`), `cluster/apps/ai/honcho/templates/_helpers.tpl` (5 refs: deriver, summary, dialectic minimal/low/medium), `cluster/apps/ai/hermes-agent/README.md`, `cluster/apps/ai/honcho/README.md`.

- [ ] **Step 1: Replace the alias and verify nothing is missed**

```bash
sed -i 's/lfm2\.5-8b-a1b/gemma-4-26b-a4b/g' \
  cluster/apps/ai/hermes-agent/values.yaml cluster/apps/ai/honcho/templates/_helpers.tpl \
  cluster/apps/ai/hermes-agent/README.md cluster/apps/ai/honcho/README.md
git grep -n "lfm2\.5-8b-a1b" -- cluster docs/src            # expect no cluster hits; docs/src history mentions are fine
git grep -c "gemma-4-26b-a4b" -- cluster/apps/ai/hermes-agent/values.yaml cluster/apps/ai/honcho/templates/_helpers.tpl   # expect 10 and 5
```

- [ ] **Step 2: Fix the stale comments** in `hermes-agent/values.yaml` (the block above `model:` and the `compression` note) to say `llama-server runs -c 65536 -np 1 (one slot of 65536 tokens)`, and in the Hermes README replace the "Known limitation, accepted 2026-09-30" bullet with a short "history" note pointing to this plan and to `.plans/TODO.md`. The README's LFM2.5 reasoning-budget bullet becomes: Gemma 4 thinks by default; suppressed server-side with `enable_thinking:false`, request opt-in.

- [ ] **Step 3: Render everything**

```bash
( cd cluster/apps/ai/hermes-agent && helm dependency build . >/dev/null 2>&1; helm template hermes . -f values.yaml >/dev/null && echo hermes-ok )
( cd cluster/apps/ai/honcho && helm dependency build . >/dev/null 2>&1; helm template honcho . -f values.yaml | grep -c "gemma-4-26b-a4b" )   # expect 5
task lint:all
```

- [ ] **Step 4: Commit, push, PR** `feat(llm): serve Gemma 4 26B-A4B at one slot to remove hybrid-state corruption`, body linking the Phase A numbers and the gates.

### Task 8: Roll out and verify (30-60 min)

- [ ] **Step 1: After merge and refresh**, confirm the pod loads Gemma on the GPU with no download (`skipping download` in the init log), the alias is `gemma-4-26b-a4b`, and `llm-server`, `hermes-agent` and `honcho` are Synced/Healthy.
- [ ] **Step 2: Stale-config check inside the pod** (Review Focus 4)

```bash
kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- grep -rn "lfm2.5-8b-a1b" /opt/data/profiles /opt/data/config.yaml 2>/dev/null | head
```

Expected: nothing. Any hit: overwrite `provider`/`default`/`base_url`/`api_key`/`context_length` for that profile explicitly through `profileOverlays` and re-check; never edit the PVC by hand.

- [ ] **Step 3: Production re-measurement.** Run `hermes-corruption.py 5 <4 profiles>` against the live service (no pause needed) and `probe.py quality`; expect the Phase A numbers.
- [ ] **Step 4: Watch for 24 h:** `LlamaServerSlow` (< 8 tok/s), `LlamaServerOnCpu`, `llamacpp:requests_deferred`, node `MemAvailable`, and Hermes fallback-to-cloud rate.
- [ ] **Rollback:** revert the swap PR; the LFM2.5 file stays on the PVC, so the previous config returns without a download. `ctx 131072 / parallel 2` is restored with it.

### Task 9: Record

**Files:**

- Modify: `docs/src/k8s/nv1-jetson.md` (new "Gemma 4 reliability test (2026-10-13)" section with the arm table, plus the memory-budget bullets updated for `-np 1`), `.plans/TODO.md` (#29002 entry: corruption now moot for the served model; keep the watch for the next hybrid candidate), `.claude/memory/` (update `reference_llama_server_nv1_memory.md` and `reference_hermes_64k_context_floor.md`; add `reference_llm_corruption_mitigation.md`; one index line each in `MEMORY.md`).

- [ ] **Step 1: Write the section from `/tmp/rel-*.log` and `/tmp/hermes-*/`** (arm table with CORRUPTION, LATENCY, memory min/peak, tok/s, quality).
- [ ] **Step 2: Commit and PR** `docs(nv1): Gemma 4 reliability test results`.

## Self-review

- **Coverage:** measure first behind a hard gate (Tasks 4-5), swap in one PR with consumer moves (6-7), verified rollout and rollback (8), and recorded results (9). Each gate row maps to a Task 4 step.
- **Known gaps stated:** the original 29% harness was never committed; `hermes-corruption.py` re-creates it (multi-turn, tool-calling) and the plan re-measures in the same session rather than trusting the old number. n=100 gives a 95% upper bound of about 5% at one corrupt turn, which is why the gate is "<= 1 of 100" and the contrast arms exist for the ambiguous band.
- **Names consistent:** pods `rel-server`, `qwen-prefetch` (reused manifest); alias `lfm2.5-8b-a1b` during Phase A, `gemma-4-26b-a4b` after the swap; branches `chore/llm-pause-gemma-reliability`, `chore/llm-resume-after-gemma-test`, `feat/llm-server-gemma4-single-slot`.
