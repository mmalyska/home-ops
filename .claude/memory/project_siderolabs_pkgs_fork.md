---
name: mmalyska/siderolabs-pkgs fork
description: Details on the pkgs fork for the nvgpu kernel module build
type: project
---

`mmalyska/siderolabs-pkgs` fork, branch `feat/jetson-nvgpu`, local: `/tmp/mmalyska-pkgs/`.

Adds `nvgpu-driver-pkg` — out-of-tree OE4T nvgpu kernel module built against Talos kernel.

**Key files:**
- `nvgpu-driver/pkg.yaml` — bldr pkg, clones OE4T/linux-nvgpu, builds with `KCPPFLAGS=-include nv_compat.h NV_BUILD_KERNEL_INTERFACE=yes` against `/src`
- `nvgpu-driver/files/nvgpu-kernel-compat.patch` — stubs L4T-only BSP headers
- `nvgpu-driver/files/nv_compat.h` — kernel API compat shim

**CI produces:** `ghcr.io/mmalyska/nvgpu-driver-pkg` tagged `v1.12.0-50-ga92bed5`

**Why:** The OE4T nvgpu driver has L4T-specific BSP dependencies that must be stubbed for a standalone Talos kernel build.

**How to apply:** When updating kernel version, re-audit the compat header against new kernel APIs.
