---
name: reference_jetson_llama_cuda_tag
description: nv1 CUDA image rules — JetPack 7 runs CUDA 13; builds without native sm_87 code need libnvidia-ptxjitcompiler (in the CDI libs since #5630)
metadata:
  type: reference
---

**Since 2026-10-08 nv1 runs JetPack 7.2 (CUDA 13.2 driver).** CUDA 13 images work; the old rule (NVIDIA `latest*` tags are CUDA 13 and silently fall back to CPU) applied to the JetPack 6 image only and matters again only for a rollback.
Serving image: `ghcr.io/mmalyska/llama-cpp-jetson` (native sm_87), pinned by digest in `cluster/apps/ai/llm/server/values.yaml`.

**PTX JIT:** a CUDA 13 build with no native sm_87 code (stock Ollama `cuda_v13`, PyTorch and vLLM wheels, which carry sm_80 code plus PTX) aborts at the first kernel with `CUDA error: PTX JIT compiler library not found`, even though discovery shows `compute=8.7 driver=13.2` and all layers offload. `libnvidia-ptxjitcompiler` is not in any L4T deb; `restore-libs` in `cluster/apps/system/nvidia/resources/cdi-setup.yaml` takes it from `cuda-compat-13-2` (595.71.05; the driver is 595.78, no problem seen).
Verified 2026-10-10: Ollama v0.40.2 100% on the GPU, qwen2.5:0.5b 89 tok/s, qwen3:4b 17.6 tok/s.
After any image bump check `ggml_cuda_init: found 1 CUDA devices` and the offload line in the startup log; the `LlamaServerSlow` alert (<8 tok/s) is the safety net.

**Why:** found during the JetPack 7.2 comparison test against the upstream JetPack 6 numbers (PRs #5630, #5633).
**How to apply:** if a GPU image aborts on JIT, check that `libnvidia-ptxjitcompiler.so.1` is in `/var/lib/nvidia-tegra-libs/tegra`. Memory limits: [[reference_llama_server_nv1_memory]]. Test method: [[reference_nv1_gpu_test_pause]].
