---
name: reference_qwen36_nv1_benchmark
description: Qwen3.6-35B-A3B at 2-bit does not fit nv1 (node MemAvailable 0.4 GB idle); 27B/3-bit and up are out; next step is hardware
metadata:
  type: reference
---

Benchmarked 2026-10-13 on nv1 with `llama-cpp-jetson` v0.6.0 and production flags. UD-IQ2_XXS (10.0 GiB) loads and runs at 15.9 tok/s (LFM2.5: 26.6), quality 19/20 with thinking off, but the idle node is left with 0.40-0.47 GB `MemAvailable` (gate 0.8 GB). UD-IQ2_M (10.7 GiB) fails to load (`cudaMalloc` OOM on the weight buffer, NvMap error 12). The concurrent-load and corruption tests were not run because of the memory result. Details and the table: `docs/src/k8s/nv1-jetson.md` ("Qwen3.6-35B-A3B benchmark").

**Why:** unified memory, 15.6 GiB with ~3.4 GiB for the system; weights above ~9-10 GiB leave no headroom. See [[reference_llama_server_nv1_memory]].
**How to apply:** do not propose a Qwen3.6/3.8 swap on nv1; a dense 27B at 2-bit is slower still. Any bigger model needs a 24 GB-class GPU. Pause procedure for a retest: [[reference_nv1_gpu_test_pause]]. The test pods can share the Service by carrying `app: llama-server` and the PVC, so Hermes needs no config change.
