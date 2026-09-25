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

| Symptom                                                                                | Cause                                                | Fix                                                                                                             |
| -------------------------------------------------------------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| GPU pod `Pending`, `Insufficient nvidia.com/gpu`; node allocatable `nvidia.com/gpu: 0` | Kubelet restarted; plugin lost registration          | Watchdog fixes it in about a minute; manual: `kubectl rollout restart ds/nvidia-device-plugin -n nvidia-system` |
| Kubelet restarts every 10–20 min                                                       | Extra DHCP address on the NIC flapping the static IP | See below                                                                                                       |

## Talos: platform DHCP left in META (fixed 2026-09-25)

nv1 had a leftover platform network config in the Talos META partition (key `0x0a`) with `operators: [dhcp4 enP8p1s0]`. It leased `192.168.48.210` beside the static `192.168.48.5`; lease churn flapped `.5`, and Talos restarted the kubelet. Machine-config `dhcp: false` does **not** remove a platform-layer operator.

- Check: `talosctl -n 192.168.48.5 get operatorspecs` must be empty and `get addresses` must show only `192.168.48.5/24` on `enP8p1s0`.
- Fix: `talosctl -n 192.168.48.5 meta delete 0x0a` (no reboot needed).
- After a reinstall or reflash, re-check this: the key is not in git.
