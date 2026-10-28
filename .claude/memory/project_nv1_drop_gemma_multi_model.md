---
name: project_nv1_drop_gemma_multi_model
description: Owner decided 2026-10-28 to stop using Gemma on nv1 and move to LFM3 plus tailored small models; one-GPU-unit constraint shapes the layout
metadata:
  type: project
---

On 2026-10-28 the owner decided to drop Gemma 4 on nv1 (Liquid AI says LFM3 is tailored for agents like Hermes) and to use more tailored models, since the node has ~10 GB more room without Gemma. Plan: `.plans/lfm3-llama-server/`.

**Why:** Gemma 4 26B Q2 left 0.5-0.8 GB headroom and forced `-np 1`; small specialised models free the node and allow parallel slots.
**How to apply:** do not re-argue keeping Gemma. Still verify before shipping: hybrid-state corruption at `-np` > 1 ([[reference_gemma4_single_slot_swap]]), Lingarr EN->PL quality (same model behind the LiteLLM `local` alias), and the one-GPU-unit limit (two GPU pods cannot coexist). Image must be llama.cpp >= v0.8.0 for LFM3. Test method: [[reference_nv1_gpu_test_pause]].
