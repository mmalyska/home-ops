---
name: L4T packages for CUDA on Orin
description: Where nvidia-l4t-core and nvidia-l4t-cuda packages live and how to install them
type: reference
---

`nvidia-l4t-core` and `nvidia-l4t-cuda` are in the `t234` repo (NOT `common`).

URL pattern: `https://repo.download.nvidia.com/jetson/t234/pool/main/n/{pkg}/{pkg}_{version}_arm64.deb`

Correct r36.4.0 timestamp: `20240912212859`

`libcuda.so.1` installed to `/usr/lib/aarch64-linux-gnu/tegra/` with symlinks `libcuda.so.1` → `libcuda.so.1.1` and `libcuda.so` → `libcuda.so.1.1`.

`dpkg -x` preserves all symlinks — no maintainer scripts needed.
