# LFM3-1.7B replaces Gemma 4 on nv1

Started 2026-10-28. Owner decision: stop using Gemma; Liquid AI positions LFM3 as tailored for agents like Hermes.

## Context

- nv1 llama-server (`cluster/apps/ai/llm/server`) serves Gemma 4 26B-A4B Q2 at `-np 1` (~11.9 GiB, 0.5-0.8 GB node headroom).
- LFM3 needs llama.cpp >= v0.8.0 (arch support PR ggml-org/llama.cpp#31252 merged 2026-10-27). Image `ghcr.io/mmalyska/llama-cpp-jetson` is on v0.7.0; v0.8.0 build is run mmalyska/containers/actions/runs/40725111771.
- Model: `LiquidAI/LFM3-1.7B-GGUF`, license `lfm1.0`. Q8_0 = 1846238496 bytes, sha256 8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6.
  Other quants: Q4_K_M 1.1 GB, QAD-Q4_0 1.05 GB, BF16 3.47 GB. Recommended sampling: temp 0.1, top-k 50, repeat penalty 1.1.
- Memory is no longer the constraint (~2 GB model vs ~10.5 GB), so `-np`, ctx and cache limits can be revisited.

## Risks (verify, do not assume)

1. Hybrid conv/attention state: LFM2.5 corrupted 29% of multi-turn Hermes output under multi-slot serving (llama.cpp#29002). Re-run `.archive/.plans/superpowers/plans/artifacts/2026-10-13-llm-reliability/hermes-corruption.py` at -np 1, 2, 4 before shipping more than one slot.
2. Lingarr (EN->PL subtitle translation) and Honcho use the `local` LiteLLM alias -> same model. Polish quality of a 1.7B model is unverified; sample a real subtitle batch before cutover.
3. Chat template / tool-call format and thinking toggle for LFM3 are undocumented on the model page; check `--jinja` output on the first load. `chatTemplateKwargs` may not apply.
4. No pause window: ArgoCD selfHeal (`cluster/apps/ai/llm/app-config.yaml`, selfHeal: true) reverts manual changes, so the live llama-server pod is the test subject (Recreate hands over the single GPU); roll back by reverting the PR. Each flag experiment (-np, checkpoints) is a values.yaml commit.
5. Hermes needs >= 64K context per slot (`ctx / parallel`).

## Hybrid-state fixes upstream (checked 2026-10-28)

- #29002 (co-batching corrupts the recurrent/short-conv state, LFM2 / LFM2.5) is **still open** with no linked fix. Multi-slot stays unproven; test it.
- ggml-org/llama.cpp#30666 "server : fix swa checkpoint invalidation logic" (merged 2026-10-19) is in v0.8.0, not v0.7.0. A maintainer (tdakhran) pointed to it on 10-27 as the fix for the related single-sequence variant (13.6% corruption at `-np 1` with `--ctx-checkpoints 2` on LFM2.5-8B-A1B). LFM3 also has SWA layers, so the checkpoint settings matter: re-run the harness with checkpoints on and off.
- Nothing else touching recurrent/hybrid state was merged recently; #31252 (LFM3 support) is the only LFM3 model change.
- Action: retest LFM2.5-8B-A1B-style replay on v0.8.0 as well; the owner's earlier tests were on b9660.

## vLLM as an alternative (checked 2026-10-28)

- vllm-project/vllm has no LFM3 PR or issue found; latest release v0.32.0 (2026-10-18) predates LFM3 (2026-10-27), so it cannot serve LFM3 until a later release. Re-check after v0.33.
- Unified-memory profiling has been a recurring vLLM bug on Jetson/UMA (#13131, #35313, #35920, all closed): its startup memory check is the risk on a board with ~0.5 GB headroom; would need an explicit low `--gpu-memory-utilization`.
- vLLM and PyTorch wheels need the PTX JIT library (present in the CDI libs since #5630), and there is no known-good aarch64 JetPack 7 / CUDA 13 image yet; we would build one like llama-cpp-jetson.
- Upside to test later: continuous batching and its own hybrid-state handling may avoid llama.cpp#29002 at -np > 1. One model per process, so it does not solve the multi-model/one-GPU question either.
- Decision: stay on llama.cpp for the LFM3 cutover; revisit vLLM when it supports LFM3 and a Jetson image exists.

## Tuning notes from the model cards (read 2026-10-28, for the later settings pass)

Sources: https://huggingface.co/LiquidAI/LFM3-1.7B and https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF.

- **Sampling, general (chat, tool use, agents, coding):** temperature 0.1, top-k 50, repetition penalty 1.1. **Math/STEM:** temperature 1.0, top-p 0.95, top-k 20. min-p and presence penalty are not mentioned. The card's own benchmarks used temperature 0.6, top-p 0.95 (an eval setup, not a recommendation). Our server sets none of these (`cluster/apps/ai/llm/server/templates/deployment.yaml` has no `--temp`, `--top-k`, `--repeat-penalty`), so clients decide; the llama-server flags set defaults that a request overrides.
- **Thinking:** on by default (the generation prompt ends with an opening think tag). Off via the template kwarg `enable_thinking` set to false, which the card warns "can be inconsistent, especially for reasoning-heavy tasks". Reasoning from turns before the latest user message is dropped unless the kwarg `preserve_thinking` is true; the v0.8.0 log says the template supports preserving reasoning and it is enabled by default (disable with `--no-reasoning-preserve`), which costs tokens in long Hermes sessions.
- **Tool calls:** XML (`<tool_call>`, `<function=NAME>`, `<parameter=NAME>`); the harness must keep passing the tool schemas on every request and keep the current turn's assistant content and reasoning in history. Deferred tools (`defer_loading`, `tool_reference` parts) are supported; llama.cpp#31256 added deferred-tools support to the server. Check with a real tool call before trusting Hermes on it.
- **Output length:** the Transformers example uses 2048 max new tokens; with thinking on, budget well above that.
- **Context:** 256K trained (input plus output); we run 65536 per slot.
- **Quantization:** no recommendation between Q8_0 (running), Q4_K_M and the QAD Q4_0 ("trained to recover the accuracy lost to Q4_0 quantization", 1.05 GB). KV cache quantization is not discussed; our `-ctk q8_0 -ctv q4_0` is hard-coded in the deployment template and untested for LFM3 (q4_0 values on only 6 global attention layers; try f16 or q8_0 since memory is plentiful).
- **Limitations (card):** "not recommended for agentic coding or complex multi-step reasoning because of its small size"; for knowledge-heavy tasks use retrieval or search. This bears directly on Hermes: expect weak long-horizon tool use and consider a larger model for the main loop (see the multi-model section).
- **Tuning checklist:** (1) client or server sampling defaults per consumer (Lingarr translation may dislike repetition penalty 1.1; test 1.0); (2) `--reasoning-budget` instead of -1 to bound thinking on small calls; (3) `--no-reasoning-preserve` if long sessions bloat; (4) KV cache types; (5) Q8_0 against QAD Q4_0 quality and speed; (6) `-ub`, `--cache-ram`, `--ctx-checkpoints` now that memory is free; (7) `--n-predict` cap with thinking on.

## Files to change

- `cluster/apps/ai/llm/server/values.yaml` (image tag+digest, model block, ctx/parallel, cache, resources, comments)
- `cluster/apps/ai/litellm/templates/models/local.yaml` (model: openai/<new alias>)
- `docs/src/k8s/nv1-jetson.md`, `docs/src/k8s/media.md`, `cluster/apps/ai/honcho/README.md` (alias mentions)
- `.claude/memory/` Gemma/nv1 memory files, update after cutover

## Status

Waiting for the v0.8.0 image. Worktree `.worktrees/feat/lfm3-llama-server`, branch `feat/lfm3-llama-server`. No cluster changes made.

## Multi-model layout (owner direction 2026-10-28)

Dropping Gemma frees ~10 GB on nv1, so use tailored models instead of one generalist. Candidates from https://docs.liquid.ai/lfm/models/complete-library (tool-calling/reasoning per model is NOT on that page; check each model card):

- Main agent / tool calling (Hermes): LFM3-1.7B (256K ctx). Larger fallback if quality is short: LFM2.5-8B-A1B (128K) or LFM2.5-24B-A2B (131K); both are hybrids, so the corruption risk applies.
- Routing / classification / scoring: d1-2B or d1-omni-600M (GGUF Q8_0/BF16/F16 only).
- Translation for Lingarr (EN->PL): no Liquid model listed for Polish (LFM2-350M-ENJP-MT is EN/JP). Keep a general model for it or evaluate LFM3-1.7B on Polish first.
- Vision: LFM3-VL-2B (needs mmproj). Embeddings: LFM2.5-Embedding-350M (today `llm/embeddings` serves a separate model; do not re-embed without a reason, see reference_uncased_bert_embeddings).

**Constraint:** one GPU unit, the Deployment uses `Recreate` and `nvidia.com/gpu: 1`, so two llama-server pods cannot both get the GPU. Options to evaluate:

1. llama-server router mode (several models in one process; confirm it exists in v0.8.0 and how it handles memory and per-model args).
2. One GPU pod for the main model, small models on CPU pods on other nodes.
3. GPU time-slicing in the NVIDIA device plugin config (cluster change, check the Talos/Jetson CDI setup first).

**GPU sharing findings (2026-10-28):** the plugin is a custom CDI one (`ghcr.io/schwankner/jetson-device-plugin:v1.0.0`, `cluster/apps/system/nvidia/resources/device-plugin.yaml`) with no args or env, and docs/src/k8s/nv1-jetson.md says it advertises exactly one `nvidia.com/gpu` (hard-coded). Raising the limit in the pod does nothing; sharing needs a plugin that advertises N IDs. Allocate always returns the same CDI device (`nvidia.com/gpu=0`), so N advertised IDs would all map to it. Upstream source not found publicly (repo 404 via API), so that means a fork or a replacement plugin. There is no Orin MIG; concurrent processes just time-slice the iGPU, with no memory isolation (unified memory, invisible to cgroups), so a node-wide OOM risk remains. It does not add throughput: the GPU already runs ~95% busy during one request. Prefer option 1 (router mode, one pod) first.

**Plugin source read (schwankner/talos-jetson-orin, plugins/jetson-device-plugin/main.go, ~150 lines Go):** `ListAndWatch` sends one hard-coded device `{ID: "igpu0"}`; `Allocate` ignores which IDs were requested and always returns the same sentinel DeviceSpec `/dev/nvgpu/igpu0/ctrl` plus CDI device `nvidia.com/gpu=0`. So sharing = advertise N IDs (e.g. `igpu0-0..N-1`, N from an env var such as `GPU_REPLICAS`) and keep `Allocate` as is; nothing else is per-device. Needs our own build (fork, like llama-cpp-jetson in mmalyska/containers) and a DaemonSet image bump; the watchdog sidecar is unaffected. Reject requests for more than one unit per container (nothing to gain). Cluster change: the plugin restart briefly re-registers the resource; running GPU pods are not evicted but confirm before applying.

Decide after the single-model LFM3 test passes; the LiteLLM gateway then gets one alias per role.

## Closed 2026-10-29

LFM3-1.7B Q8_0 is live on nv1 (`-c 131072 -np 1`, cache 2048 MiB, 16 checkpoints, sampling temp 0.1 / top-k 50 / repeat-penalty 1.1, KV q8_0/q8_0). Results and numbers are in `docs/src/k8s/nv1-jetson.md`. Not suitable for subtitle translation (Lingarr uses `cheap`). The Gemma file was deleted from the PVC; the 7.7 GB LFM2.5 file remains. Unfinished items moved to `.plans/TODO.md`: thinking-on `local` for Hermes aux tasks and Honcho, nv1 alert thresholds, and the optional experiments (`-np 2`, 262144 context, f16 KV, QAD Q4_0, multi-model layout).
