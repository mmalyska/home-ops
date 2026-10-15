---
name: reference_gemma4_single_slot_swap
description: nv1 serves Gemma 4 26B-A4B Q2 at -np 1 since 2026-10-15; why (hybrid corruption), what it costs, and why -np 2 and a bigger prompt cache do not fit
metadata:
  type: reference
---

Since 2026-10-15 `llama-server` runs `gemma-4-26B-A4B-it-UD-Q2_K_XL` at `-c 65536 -np 1 --cache-ram 640 --ctx-checkpoints 2 --n-predict 2048`, alias `gemma-4-26b-a4b` (PR #5702). It replaced LFM2.5-8B-A1B because LFM2.5's hybrid recurrent state is corrupted by llama.cpp under multi-sequence serving (#29002, open): 29.0% of real Hermes turns. Gemma has no recurrent state: 0 corrupt of 66 multi-turn tool-calling turns plus 0 of 10 on the live service.

- **One slot serializes sessions**: alone ~11-39 s per turn, generation ~18 tok/s, prefill ~210 tok/s. With the 640 MiB cache, 2 sessions take ~12-18 s (no tool) to ~22-42 s (tool) per turn; with 4 interleaved sessions 90-260 s. A full-toolset Hermes call is ~16K tokens (about 80 s cold); aux title generation can time out behind it.
- **`-np 2` does not fit**: needs `-c 131072`; idle node `MemAvailable` 0.55 GB, 0.29 GB under two sessions, node tools time out. Same config OOM-killed on 2026-09-28.
- **GPU memory is invisible to the pod cgroup** on this unified-memory board: watch node `MemAvailable` (`talosctl read /proc/meminfo`), never `kubectl top`.
- **`--cache-ram 640` is production** (trial 2026-10-15): one saved prompt state is ~276 MiB, so 256 rejects every entry; 640 holds two = two interleaved sessions, 3-4x faster per turn (no-tool 48-51 s -> 12-18 s). Steady node `MemAvailable` 0.86 GB, transient low 0.54 GB. No gain at 4 sessions (cyclic eviction) and a 0.48 GB dip there.
- **Runaway generation** blocks the only slot; `--n-predict 2048` caps it (verified). Hermes may retry on `finish_reason=length`.
- **Harness**: `docs/superpowers/plans/artifacts/2026-10-13-llm-reliability/hermes-corruption.py`; todo state does not survive `--resume`; wrap remote commands in `timeout -s KILL`; avoid the `file`/`terminal` toolsets (SSH to a remote host).

**Why:** three measured runs plus a live 2-session run, 2026-10-15; owner accepted 0.6-0.8 GB node headroom and the single-slot trade.
**How to apply:** do not propose `-np 2`, a prompt cache above 640 MiB, or a hybrid model (Qwen3.5/3.6, LFM, Granite) on nv1 without re-running the harness and the memory test. Related: [[reference_llama_server_nv1_memory]], [[reference_hermes_64k_context_floor]], [[reference_qwen36_nv1_benchmark]], [[reference_nv1_gpu_test_pause]].
