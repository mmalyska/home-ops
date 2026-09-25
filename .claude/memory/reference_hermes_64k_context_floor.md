---
name: reference_hermes_64k_context_floor
description: Hermes Agent refuses any model below 64,000 tokens of context; llama-server slots are 32768 so the main model and compression must stay on the cloud
metadata:
  type: reference
---

Hermes (pinned `v2026.9.14`) raises `ValueError` in `agent_init._enforce_minimum_context` when the model's context window is below `MINIMUM_CONTEXT_LENGTH = 64_000` (only `lmstudio` with an explicit `model.context_length` is exempt), and `compression` aux has the same floor. It fails at agent construction, so `fallback_providers` never runs and every session/CLI one-shot fails ("Failed to initialize agent").

llama-server on nv1 runs `-c 65536 -np 2` = 32768 per slot, so a local main model was configured in #5314 and Hermes broke; it was restored to the cloud in the follow-up. A local Hermes main model needs `ctx / parallel >= 64000`, which costs memory nv1 barely has (see [[reference_llama_server_nv1_memory]]).

**Why:** the final whole-branch review found it after all six profiles and the default were switched; 17 requests I counted as "Hermes" were actually honcho-api. No real Hermes turn had been run.
**How to apply:** after any Hermes model/provider change, run `kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- hermes chat -q "ping"` before calling it done. Seeders only add keys, so a rollback must overwrite `base_url`/`api_key`/`context_length` explicitly.
