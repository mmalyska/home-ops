---
name: Jetson container runtime — CSV approach, not CDI
description: Jetson Orin requires nvidia-container-runtime with CSV-based plugin, not CDI
type: project
---

CDI approach is wrong for Jetson Orin. Jetson requires `nvidia-container-runtime` with CSV-based plugin system (libnvidia-container Tegra mode), NOT CDI.

**Correct approach:**
1. Install `nvidia-container-toolkit` Talos extension with Tegra CSV support
2. Configure containerd to use `nvidia-container-runtime`
3. Use L4T base images (`l4t-base`/`l4t-cuda`) not generic CUDA images

CSV files at `/etc/nvidia-container-runtime/host-files-for-container.d/*.csv` define device/lib injection.

`libcuda.so` from `nvidia-l4t-cuda` is a dGPU shim (wants `/dev/nvidiactl`) — wrong lib for Orin.

Device nodes are `/dev/nvhost-*` not `/dev/nvgpu/igpu0/*` for the CSV plugin.

Reference: https://nvidia.github.io/container-wiki/toolkit/jetson.html and `libnvidia-container/design/mount_plugins.md`

**Why:** CDI requires device enumeration at runtime that doesn't work for Jetson's integrated GPU model.

**How to apply:** When configuring GPU containers on nv1, always use CSV/Tegra mode, never CDI.
