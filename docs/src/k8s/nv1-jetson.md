# nv1 — Jetson Orin NX (GPU node)

nv1 (`192.168.48.5`) is a Jetson Orin NX 16 GB running Talos with a custom nvgpu (JetPack 6 / r36.5) stack. CPU and GPU share the 16 GB (about 12.8 GiB usable for models).

## How GPU access works

- `nvidia-cdi-setup` DaemonSet writes a CDI spec (device nodes + JetPack libs).
- `nvidia-device-plugin` advertises **exactly one** `nvidia.com/gpu` (hard-coded, no config). Only one pod at a time can hold it.
- A `kubelet-watchdog` sidecar restarts the plugin whenever the kubelet re-creates `kubelet.sock`. Without it, any kubelet restart leaves the node at `nvidia.com/gpu: 0` because the plugin never re-registers.
- Alert `NodeGpuUnavailable` fires when allocatable GPU is 0 for 5 minutes.

## Rules for GPU images

- Use CUDA **12.6** images only, pinned by digest (for llama.cpp: `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04`).
- Never use `latest*` tags: they moved to CUDA 13, which the JetPack 6 driver cannot initialize. llama.cpp then falls back to CPU **silently** (log line `ggml_cuda_init: failed to initialize CUDA: CUDA driver version is insufficient for CUDA runtime version`, ~6 tok/s).

## Symptoms and recovery

| Symptom                                                                                          | Cause                                                | Fix                                                                                                                 |
| ------------------------------------------------------------------------------------------------ | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| GPU pod `Pending`, `Insufficient nvidia.com/gpu`; node allocatable `nvidia.com/gpu: 0`           | Kubelet restarted; plugin lost registration          | Watchdog fixes it in about a minute; manual: `kubectl rollout restart ds/nvidia-device-plugin -n nvidia-system`     |
| Kubelet restarts every 10–20 min                                                                 | Extra DHCP address on the NIC flapping the static IP | See below                                                                                                           |
| `cilium-envoy`/`node-exporter` CrashLoopBackOff, DNS timeouts, llama-server slows to a few tok/s | Node-wide OOM (see memory budget below)              | Check `talosctl -n 192.168.48.5 dmesg \| grep -i oom` and `read /proc/meminfo`; keep llama-server within its budget |

## Talos: platform DHCP left in META (fixed 2026-09-25)

nv1 had a leftover platform network config in the Talos META partition (key `0x0a`) with `operators: [dhcp4 enP8p1s0]`. It leased `192.168.48.210` beside the static `192.168.48.5`; lease churn flapped `.5`, and Talos restarted the kubelet. Machine-config `dhcp: false` does **not** remove a platform-layer operator.

- Check: `talosctl -n 192.168.48.5 get operatorspecs` must be empty and `get addresses` must show only `192.168.48.5/24` on `enP8p1s0`.
- Fix: `talosctl -n 192.168.48.5 meta delete 0x0a` (no reboot needed).
- After a reinstall or reflash, re-check this: the key is not in git.

## Memory budget (llama-server)

nv1 has 15.6 GiB of unified memory. The system (Talos, kubelet, Cilium, DaemonSets) uses about 3.4 GiB, and the llama-server pod sits at **about 11.9 GiB right after warm-up** (weights 10.0 GiB, KV cache 0.76 GiB, compute buffers 0.6 GiB, CUDA context). That leaves roughly 1.3 GiB of node headroom, and the pod can grow to about 13.4 GiB before the node starves.

- Settings that fit (`cluster/apps/ai/llm/server/values.yaml`): memory limit `13Gi`, request `11Gi`, `--cache-ram 256`, `--ctx-checkpoints 2`, `-ub 256`. Measured steady state: 11.8–12.2 GiB, node `MemAvailable` about 1.3 GiB, 15–16 tok/s, no restarts across a sustained multi-prompt test.
- llama-server defaults do **not** fit: the host-RAM prompt cache defaults to 8192 MiB (about 88 MiB per 1k tokens) and each context checkpoint is 100–120 MiB (32 per slot). Left at defaults they starve the node, Talos' OOM controller kills besteffort system pods, and generation decays from about 14 to about 3 tok/s. It is not thermal.
- A pod limit of `12Gi` is too low (OOM-killed at about 12.5 GB); a limit above about 13.4 GiB gives no protection because the node runs out first.
- Gemma 4 thinks by default and reasoning consumes `max_tokens`, so small-budget calls return empty content. The server defaults to thinking off (`--chat-template-kwargs`); a request can opt in with `chat_template_kwargs.enable_thinking=true`.
- Before changing the model, quantization, context, slots or any of the flags above, re-run a sustained test with many different prompts and watch pod memory and node `MemAvailable` (`talosctl -n 192.168.48.5 read /proc/meminfo`).
- Smaller quants of the same model save little (IQ2_XXS is 9.24 GiB vs 9.82 GiB for the running Q2_K_XL); Gemma 4 E4B frees about 5 GiB but scored much lower on agentic tasks.
