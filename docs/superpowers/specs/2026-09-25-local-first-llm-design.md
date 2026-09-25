# Local-First LLM on Jetson (nv1) — Design Spec

**Date:** 2026-09-25  
**Status:** Draft — pending review  

## Problem

Hermes Agent and Honcho depend on cloud inference for everything except embeddings and (in-pod CPU) speech-to-text:

- All six Hermes profiles (`devops`, `dotnet-dev`, `mobile-dev`, `node-dev`, `orchestrator`, `researcher`) use `deepseek/deepseek-v4-pro` via OpenRouter; fallbacks are OpenRouter `deepseek-v4-flash` and Anthropic.
- About ten Hermes auxiliary tasks (title generation, compression, approval, curator, triage, kanban decomposer, …) use OpenRouter; vision uses Gemini via OpenRouter.
- Honcho's deriver, summary and dialectic LLM calls use OpenRouter.
- Hermes TTS provider is `edge` (Microsoft online voices) on the default profile and on every profile.

The Jetson Orin NX (nv1, 16 GB unified memory) is Ready and serves GPU workloads, but its only consumer is Ollama (embeddings for Honcho). Ollama cannot load Gemma 4 GGUFs (bundled llama.cpp lacks the `gemma4` architecture) and holds nv1's single GPU unit while idle.

## Goals

1. **Local-first inference:** Hermes and Honcho call a local model first; cloud providers are the automatic fallback (Hermes `fallback_providers`), so the stack keeps working when the internet drops and costs less when it is up.
2. Auxiliary tasks, Honcho memory calls, embeddings, STT and TTS have no cloud dependency in steady state.
3. Replace Ollama with a GitOps-managed llama.cpp deployment that is pinned, observable, and compatible with the Talos + CDI GPU stack on nv1.
4. Every rollout step is reversible independently.

## Non-Goals

- Matching `deepseek-v4-pro` quality locally. The local main model is a step down (see Quality).
- Strictly no-cloud operation (OpenRouter/Anthropic stay configured as fallbacks).
- Local vision in phase 1 (memory does not allow it, see Memory Budget); vision stays on the cloud provider.
- Automatic quality-based escalation to the cloud. Hermes falls back on errors and timeouts only.
- Patching the Jetson device plugin to advertise multiple GPU units (rejected alternative B).

## Measured Constraints (2026-09-25, nv1)

| Finding | Evidence |
|---|---|
| nv1 GPU is a single hard-coded device unit (`ID: "igpu0"`, no config). Only one pod/container can hold `nvidia.com/gpu`. | `schwankner/talos-jetson-orin` `plugins/jetson-device-plugin/main.go` |
| NVIDIA `llama_cpp:latest-jetson-orin` (rebuilt 2026-08-12) ships **CUDA 13.0.1**; nv1's JetPack 6 driver (r36.5, ptxjitcompiler 540.5.0) cannot init it → silent CPU fallback (6.2 tok/s, 7.4 cores). `b8708-r36.4-tegra-aarch64-cu126-22.04` (CUDA 12.6, built 2026-04-08) works. | `ggml_cuda_init: CUDA driver version is insufficient for CUDA runtime version`; registry image config |
| Gemma 4 26B-A4B `UD-Q2_K_XL` (10.5 GB) on llama-server, GPU, `-ngl 99 -fa on -ctk q8_0 -ctv q4_0 -c 16384 -np 1 --jinja`: **14.8–16.6 tok/s** decode; ~11.7 GiB pod memory; KV 130 MiB @16k. | Benchmark runs, this session |
| Gemma 4 E4B `Q4_K_M` (unsloth, 4.9 GB) on the same engine/flags: 13.7 tok/s; GPU model buffer 2.9 GiB; total ~5–6 GB. | Benchmark runs |
| Ollama E4B build loads 9.6 GB (weights 8.9 GiB); qwen3.5:9b (current) 8.8 tok/s. | Benchmark runs |
| llama-server defaults `parallel_tool_calls: false`. With `true`: 26B made both calls in 2/3 runs, E4B 3/3 (small sample). | Benchmark runs |
| Usable GPU memory ≈ 12.8 GiB of 15.5 GiB allocatable. | Ollama CUDA discovery log |
| Ollama 0.20.5 cannot load HF GGUFs of `gemma4` (`unknown model architecture`). | Ollama log |
| Google τ²-bench: 26B-A4B 68.2%, E4B 42.2%. | Google Gemma 4 model card |
| M720q nodes (mc1–mc3): 6 CPU, 32 GB each, ~18–20 GB free, control-plane (etcd) — CPU workloads need hard limits. | `kubectl top nodes` |

## Architecture

```
                    ┌──────────────── Hermes (hermes-agent ns) ────────────────┐
                    │  main model + aux tasks + STT + TTS                       │
                    └───┬───────────────┬───────────────┬──────────────┬───────┘
        provider:custom │   STT_OPENAI_ │               │ tts:piper    │ fallback_providers
        (per-task       │   BASE_URL    │               │ (in pod)     │ (on error/timeout)
         base_url)      ▼               ▼               ▼              ▼
   ┌───────────────────────┐  ┌────────────────┐  ┌──────────┐  ┌──────────────────────┐
   │ llama-server (nv1 GPU)│  │ whisper server │  │ Honcho   │  │ OpenRouter / Anthropic│
   │ Gemma 4 26B-A4B Q2    │  │ (M720q CPU)    │  │ deriver/ │  └──────────────────────┘
   │ -np 2, /metrics       │  └────────────────┘  │ summary  │
   └───────────────────────┘                      └────┬─────┘
                                              LLM ▲     │ embeddings
                                                  │     ▼
                                       llama-server (nv1)   ┌──────────────────────┐
                                                            │ embeddings server    │
                                                            │ (M720q CPU, nomic)   │
                                                            └──────────────────────┘
```

Only `llama-server` on nv1 holds the GPU. Everything else is CPU on the M720q nodes or in-pod.

## Components

### 1. `llm` app (nv1, GPU) — llama-server

- New ApplicationSet app under `cluster/apps/ai/llm/` (namespace `llm`, Service `llama-server`), replacing `ollama`.
- Image: `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04`, **pinned by digest**. Never use `latest*` tags (CUDA 13). Renovate cannot track these tags; bumps are manual and must re-verify CUDA init.
- Model: Gemma 4 26B-A4B `UD-Q2_K_XL` GGUF from `unsloth/gemma-4-26B-A4B-it-GGUF`, on a dedicated PVC, fetched once by an init container with a checksum check.
- Flags (starting point, to be tuned in validation): `-ngl 99 -fa on -ctk q8_0 -ctv q4_0 --jinja -np 2 -c 32768 --cache-ram 1024 --metrics --host 0.0.0.0 --port 8080`, sampling `temperature=1.0 top_p=0.95 top_k=64` (Google's recommendation).
- Deployment: `strategy: Recreate`, `nodeSelector: accelerator=jetson-orin`, toleration for `nvidia.com/gpu=present`, `nvidia.com/gpu: 1`, memory limit sized to the measured peak (≈13 Gi), readiness on `/health`, ClusterIP Service on 8080. No HTTPRoute (LAN/in-cluster only); optional `--api-key` from an ExternalSecret.
- Clients must send `parallel_tool_calls: true`.
- Observability: PodMonitor on `/metrics`; alerts for llama-server down and for `nvidia.com/gpu` allocatable = 0 on nv1.

### 2. Embeddings server (M720q, CPU)

- llama.cpp CPU server (`--embedding`) with `nomic-embed-text` v1.5 GGUF, 2 vCPU limit, low priority, on an x86 node (not nv1).
- Honcho: point `EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL` (in `cluster/apps/ai/honcho/templates/_helpers.tpl`) at it. Vector dimension (768) must stay identical to avoid re-embedding.
- Must be live and Honcho repointed **before** Ollama stops (GPU exclusivity).

### 3. Speech-to-text (M720q, CPU)

- OpenAI-compatible faster-whisper server (`/v1/audio/transcriptions`); model `large-v3-turbo` int8 (or `medium` if CPU speed demands), hard CPU limit (≤3 cores).
- Hermes: `stt.provider: openai` with `STT_OPENAI_BASE_URL` (env) and a placeholder key. The current in-pod `local` `base` model remains the fallback provider.
- Candidate image: a Jetson-oriented Speaches build exists (`ghcr.io/cappyt/jetson-speaches`, JetPack 6 / r36.4) but this component runs on x86 CPU, so a CPU/multi-arch Speaches or faster-whisper-server image is used instead. Image choice is a validation item.

### 4. Text-to-speech (in Hermes pod)

- Current provider is **`edge` (cloud)** on the default config and every profile. Switch to the local `piper` provider (`en_US-lessac-medium`, already in Hermes' config schema).
- Validation item: confirm the piper binary and voice are present in the pinned Hermes image; if not, `neutts` (local) or a small piper sidecar.

### 5. Hermes configuration

- Default profile (seeded from `values.yaml`): `model.provider: custom`, `base_url: http://llama-server.llm.svc.cluster.local:8080/v1`, `default: gemma-4-26b-a4b` (served model name, final value after S2); each `auxiliary.*` block gets `provider: custom` + `base_url` (Hermes labels non-OpenRouter aux providers "experimental" — validate each task); `fallback_providers`: OpenRouter `deepseek/deepseek-v4-pro`, then Anthropic (existing entries).
- **Design work item:** the six worker profiles keep their own `config.yaml` on the PVC (`provider: openrouter`, `default: deepseek-v4-pro`) and are managed imperatively. Local-first for profiles requires extending the `config-seeder` init container to deep-merge per-profile overlays (from a ConfigMap) into `/opt/data/profiles/<name>/config.yaml`, not just the default config.
- Per-task `reasoning_effort` can disable Gemma thinking mode on cheap tasks.

### 6. Honcho configuration

- Deriver, summary and dialectic model configs (`DERIVER_MODEL_CONFIG__*`, `SUMMARY_MODEL_CONFIG__*`, `DIALECTIC_LEVELS__*__MODEL_CONFIG__*`) point at llama-server via `OVERRIDES__BASE_URL`; the existing `FALLBACK__*` settings keep OpenRouter as the fallback.

## Data Flow and Failure Behavior

1. Hermes/Honcho → local llama-server (timeouts tuned per task).
2. On error/timeout → next provider in `fallback_providers` (OpenRouter → Anthropic).
3. llama-server restart, cold start (1–2 min model load from Ceph) or nv1 GPU loss → cloud fallback covers it while the internet is up. If both the internet and the local server are down, that is an outage (accepted).
4. Single model, `-np 2`: main-agent turns, aux tasks and Honcho background work share ~16 tok/s; validation must show acceptable latency for interactive turns.

## Prerequisites (before the rollout)

1. PRs merged: #5291 (`dhcp: false` for nv1), #5292 (resume Ollama auto-sync — moot once `ollama` is retired but keeps state clean in the interim).
2. nv1 META key `0x0a` deleted (done 2026-09-25 with `talosctl meta delete 0x0a`; it is not in git — the value was a leftover platform DHCP operator). Note this in `docs/` (Talos runbook) so a reinstall does not reintroduce it.
3. **Device-plugin self-heal.** The Jetson device plugin never re-registers after a kubelet restart, so nv1 silently drops to `nvidia.com/gpu: 0`. The image is distroless (no exec probe). Add a sidecar (`shareProcessNamespace: true`, digest-pinned alpine) that restarts the plugin process when `kubelet.sock` is re-created.
4. 24 hours with no kubelet restart on nv1 (before the fixes: restarts every ~12–18 min, 2026-09-25).
5. Ollama PVC is already 40 Gi (#5289) so both model sets fit during the transition.

## Rollout (each step reversible)

| Step | Change | Rollback |
|---|---|---|
| 1 | Deploy CPU embeddings server; repoint Honcho embeddings. Ollama still up. | Repoint Honcho to Ollama. |
| 2 | Stop Ollama (scale 0 + auto-sync handled via PR), deploy `llm` (llama-server, 26B). | Scale `llm` to 0, scale Ollama to 1. |
| 3 | Repoint Hermes aux tasks and Honcho LLM calls to llama-server (cloud fallback stays). | Revert values; both revert to OpenRouter. |
| 4 | Main model: canary one profile (e.g. `researcher`), observe, then remaining profiles. Requires the per-profile seeder change. | Revert the profile overlay. |
| 5 | STT to the CPU whisper server; TTS `edge` → `piper`. | Restore previous providers. |
| 6 | Retire the `ollama` app per the app-removal procedure (manual `kubectl delete application`, check PVC before deleting). | n/a |

## Validation Spikes (before steps 3–5)

| # | Question | Pass criteria |
|---|---|---|
| S1 | Does Q2 26B-A4B give acceptable output on real Hermes aux prompts (title, compression, approval, curator, triage)? | Side-by-side with `deepseek-v4-flash`; no systematic failures |
| S2 | `-np 2` behavior with Hermes + Honcho traffic concurrently | Interactive turn latency within budget; no OOM |
| S3 | CPU faster-whisper `large-v3-turbo` speed on M720q under a 3-core limit | Acceptable real-time factor for Signal voice notes; etcd unaffected |
| S4 | Honcho embeddings against llama-server `nomic-embed-text` | Same dimension; cosine similarity vs Ollama vectors ≈ 1 (else plan re-embedding) |
| S5 | Hermes `provider: custom` with tools + `parallel_tool_calls` against llama-server | Tool loop works end-to-end |
| S6 | Piper binary + voice present in the pinned Hermes image | Local TTS plays; else neutts/sidecar |

## Risks

| Risk | Mitigation |
|---|---|
| Q2 quantization degrades quality; main agent weaker than `deepseek-v4-pro` | Local-first with cloud fallback; canary one profile; per-profile choice later |
| Memory: ~12 of ~12.8 GiB usable; no room for vision or a second model | Vision stays cloud; context/KV tuning; re-measure after config changes |
| Single GPU unit blocks side-by-side pods | Design puts all GPU use in one pod; peripherals on CPU nodes |
| GPU registration lost after any kubelet restart | Self-heal sidecar (prerequisite) + alerting |
| Wrong CUDA image (13) silently falls back to CPU | Pin CUDA 12.6 digest; startup check/alert on `ggml_cuda_init` failure or low tok/s |
| Renovate cannot track NVIDIA image tags | Manual bump procedure with CUDA-init verification |
| CPU workloads on control-plane nodes affect etcd | Hard CPU limits, low priority, anti-affinity from heavy tenants |
| Single-maintainer STT image | Fall back to in-pod `local` whisper |

## Open Items

- Canary profile for step 4 (default: `researcher`).
- Whether to keep `qwen3.5:9b` / E4B for anything (currently neither is planned).
- Final served model name and context size after S2.
- Exact CPU whisper/embedding images (S3, S4).
- Revisit vision-on-Jetson once real memory numbers with `-np 2` are known.
