---
name: project_nv1_drop_gemma_multi_model
description: Owner decided 2026-10-28 to stop using Gemma on nv1 and move to LFM3 plus tailored small models; one-GPU-unit constraint shapes the layout
metadata:
  type: project
---

On 2026-10-28 the owner decided to drop Gemma 4 on nv1 (Liquid AI says LFM3 is tailored for agents like Hermes) and to use more tailored models, since the node has ~10 GB more room without Gemma. Plan: `.plans/lfm3-llama-server/`.

**Why:** Gemma 4 26B Q2 left 0.5-0.8 GB headroom and forced `-np 1`; small specialised models free the node and allow parallel slots.
**How to apply:** do not re-argue keeping Gemma. Still verify before shipping: hybrid-state corruption at `-np` > 1 ([[reference_gemma4_single_slot_swap]]), Lingarr EN->PL quality (same model behind the LiteLLM `local` alias), and the one-GPU-unit limit (two GPU pods cannot coexist). Image must be llama.cpp >= v0.8.0 for LFM3. Test method: [[reference_nv1_gpu_test_pause]].

**Status 2026-10-29:** LFM3-1.7B Q8_0 is live (PRs #5977/#5978), tuned to `-c 131072 -np 1 --cache-ram 2048 --ctx-checkpoints 16`, sampling temp 0.1 / top-k 50 / repeat-penalty 1.1, KV q8_0/q8_0 (#5979, #5993). Speed ~1700 tok/s prefill, 26-30 tok/s gen, 0 corrupt in 70 turns at `-np 1`, node MemAvailable ~8 GB. It is NOT suitable for subtitle translation (invalid JSON, ~21% English left, batch drift), so Lingarr uses `cheap`; thinking-on also exhausts small token budgets, hence the `local-fast` alias. Still undecided: `-np 2` (own corruption run), ctx 262144, f16 KV, reasoning budget, QAD Q4_0, orphan Gemma file cleanup on the PVC. Details: `docs/src/k8s/nv1-jetson.md`, `.plans/lfm3-llama-server/tasks.md`.
