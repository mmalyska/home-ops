---
name: Jetson GPU (nvgpu) project — nv1
description: Status and key details for the Jetson Orin NX nvgpu Talos extension project
type: project
---

nv1 is a Jetson Orin NX 16GB at 192.168.48.5. Phase 3 IN PROGRESS (as of 2026-04-08). Pkgs fork CI passing, extensions fork CI pending. Phase 4: update talconfig.yaml.

**Key technical details:**
- OE4T nvgpu driver needs `KCPPFLAGS` with `nv_compat.h` force-include (`NV_*` macros for kernel 6.18)
- Stubs needed for L4T-only headers: `soc/tegra/virt/hv-ivc.h` and `linux/platform/tegra/mc_utils.h`
- Repos: `mmalyska/siderolabs-pkgs` `feat/jetson-nvgpu`, `mmalyska/siderolabs-extensions` `feat/jetson-nvgpu`
- PKGS tag: `v1.12.0-50-ga92bed5`

**On Talos upgrade:** retag pkgs fork, update extensions workflow PKGS default, run pkgs CI first then extensions.

**Gaps vs standard flow:** need `machine.kernel.modules nvgpu`, `net.core.bpf_jit_harden` sysctl, CSV mode for device plugin (not NVML).

**Plan docs:** `docs/src/k8s/jetson-gpu.md`, CUDA follow-up: `docs/src/k8s/jetson-cuda-extension.md`

**Why:** Adding GPU acceleration to the home cluster for ML/AI workloads on the Jetson node.

**How to apply:** When working on Jetson/nvgpu issues, check these repos and phase status first.
