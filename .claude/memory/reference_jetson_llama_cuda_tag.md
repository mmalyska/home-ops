---
name: reference_jetson_llama_cuda_tag
description: NVIDIA llama_cpp image tags labelled latest* are CUDA 13 and silently fall back to CPU on nv1; use the pinned cu126 tag
metadata:
  type: reference
---

On nv1 (JetPack 6 / r36.5 driver) `ghcr.io/nvidia-ai-iot/llama_cpp:latest*` is built for CUDA 13, prints `CUDA driver version is insufficient` and silently runs on CPU (~6 tok/s instead of ~15). The working image is `b8708-r36.4-tegra-aarch64-cu126-22.04` pinned by digest in `cluster/apps/ai/llm/server/values.yaml`. Check `ggml_cuda_init: found 1 CUDA devices` and `offloaded 31/31 layers to GPU` in the startup log after any image bump; the `LlamaServerSlow` alert (<8 tok/s) is the safety net.

**Why:** hit during the local-first LLM work (2026-09-25); Renovate bumps of this image must not move to a CUDA 13 tag.
**How to apply:** verify the CUDA tag and startup log before merging any image update for llm-server. Memory limits: [[reference_llama_server_nv1_memory]].
