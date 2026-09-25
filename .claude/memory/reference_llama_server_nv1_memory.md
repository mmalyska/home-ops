---
name: reference_llama_server_nv1_memory
description: llama-server on the 16 GB Jetson nv1 has almost no memory headroom; prompt-cache/checkpoint defaults and low limits cause node-wide OOM or pod kills
metadata:
  type: reference
---

nv1 (Orin NX, 15.6 GiB unified) runs llama-server with Gemma 4 26B-A4B Q2_K_XL. Pod working set is ~11.9 GiB right after warm-up; the system uses ~3.4 GiB, so the pod can grow to ~13.4 GiB before the node starves.

- llama-server defaults (`--cache-ram` 8192 MiB, `--ctx-checkpoints` 32, each checkpoint ~100-120 MiB for Gemma's sliding window) starve the node: Talos OOM controller then kills besteffort system pods (cilium-envoy, node-exporter, NFD go CrashLoopBackOff, DNS times out) and generation speed decays from 14 to ~3 tok/s. Not thermal.
- A pod memory limit of 12Gi OOM-kills llama-server (baseline is ~11.9 GiB). Working config: limit 13Gi, request 11Gi, `--cache-ram 256`, `--ctx-checkpoints 2`, `-ub 256` (chart `cluster/apps/ai/llm/server`).
- Gemma 4 thinks by default and reasoning eats `max_tokens` (empty `content`, finish_reason=length). Server default is `--chat-template-kwargs '{"enable_thinking":false}'`; requests opt in with `chat_template_kwargs.enable_thinking=true`.
- Avoid `pkill -f`/`pgrep -f ... | kill` in Bash tool commands: the pattern matches the tool's own shell (exit 144). List PIDs with `ps` and kill by number.

**Why:** a prompt-cache diagnosis by the user found the root cause after I misread it as throttling; my first fix (12Gi limit) was itself wrong.
**How to apply:** before changing llama-server memory flags, quantization, context or parallel slots, re-check pod working set and node `MemAvailable` (`talosctl -n 192.168.48.5 read /proc/meminfo`) under a sustained multi-prompt test, not just a single request. See [[reference_gateway_dns_architecture]] only for unrelated routing.
