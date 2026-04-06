---
name: Jetson GPU (nvgpu) Extension Project
description: Active project to build a custom Talos nvgpu extension for nv1 (Jetson Orin NX 16GB). Plan and patch log at docs/src/k8s/jetson-gpu.md
type: project
---

**Goal:** Get CUDA GPU compute working on nv1 (Jetson Orin NX 16GB, 192.168.48.5) in Talos.

**Why:** Jetson GPU is on the Tegra platform bus, not PCIe. The official siderolabs
`nvidia-open-gpu-kernel-modules-lts` extension is for discrete PCIe GPUs and will never work.
The correct driver is `nvgpu` from OE4T/linux-nvgpu (branch `patches-r36.5`).

**Current phase:** Phase 1 COMPLETE — BUILD EXIT CODE: 0 achieved against kernel 6.18.18.
Next: Phase 2 — create proper patch file + build Talos extension.

**Key insight:** The OE4T driver has ALL kernel compatibility code behind `#ifdef NV_*` guards.
No source patching is needed. Pass the right macros via `KCPPFLAGS="-include /path/nv_compat.h"`.

**NV_* macros required for kernel 6.18** (put in a force-include header):
- `NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS` (6.3+) — vm_flags_set/clear
- `NV_CLASS_CREATE_HAS_NO_OWNER_ARG` (6.4+) — class_create(name) no THIS_MODULE
- `NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG` (6.2+) — const struct device* in devnode
- `NV_FD_FILE_PRESENT` (6.9+) — fd_file(fd) accessor
- `NV_FD_EMPTY_PRESENT` (6.12+) — fd_empty(fd)
- `NV_HRTIMER_SETUP_PRESENT` (6.15+) — hrtimer_setup()
- `NV_LINUX_IOSYS_MAP_H_PRESENT` (5.18+) — linux/iosys-map.h
- `NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID` (6.11+) — void .remove
- Do NOT define `NV_MODULE_IMPORT_NS_CALLS_STRINGIFY` (6.18 uses string literal form)

**L4T-only stubs required** (headers not in vanilla kernel, not guarded by NV_* macros):
- `soc/tegra/virt/hv-ivc.h` → stub: `nvgpu_ivm.c`, `soc.c`, `contig_pool.c`
- `linux/platform/tegra/mc_utils.h` → stub: `platform_ga10b_tegra.c`

**Build command for kernel 6.18:**
```bash
KCPPFLAGS="-include /path/nv_compat.h" KBUILD_MODPOST_WARN=1 \
  make -j$(nproc) -C /path/to/kernel ARCH=arm64 \
  M=/path/to/nvgpu/drivers/gpu/nvgpu modules
```

**Gaps vs standard Talos NVIDIA flow (identified from Talos docs):**
- `machine.kernel.modules: [{name: nvgpu}]` missing — nvgpu.ko won't autoload on Talos
- `net.core.bpf_jit_harden: "1"` sysctl missing — required by nvidia-container-toolkit
- Device nodes differ: Jetson uses `/dev/nvgpu`, `/dev/nvhost-*`, `/dev/nvmap` (not `/dev/nvidia*`)
- `nvidia/k8s-device-plugin` uses NVML → finds 0 GPUs on Jetson; need CDI mode or custom plugin
- RuntimeClass `nvidia` still required for both Jetson and discrete GPU
- Container toolkit CDI spec must enumerate Tegra device paths manually (not NVML auto-generate)

**Commented placeholder added to talconfig.yaml** (nv1 node) for `machine.kernel.modules` + sysctl.

**Next steps:**
1. Create `provision/talos/patches/nvgpu-kernel-compat.patch` — unified diff of the L4T stubs
2. Package stubs + nvgpu.ko build into a Talos sysext OCI image
3. Update talconfig.yaml: remove `nvidia-open-gpu-kernel-modules-lts` + `nvidia-container-toolkit-lts`, add custom nvgpu extension
4. Configure CDI spec for Tegra device nodes + deploy k8s-device-plugin in CDI mode
5. Regenerate + apply Talos config to nv1

**Full plan:** `docs/src/k8s/jetson-gpu.md`
**Job file:** `cluster/.tools/nvgpu-build-test.yaml` (can be deleted — phase 1 done)
**How to apply:** Always load this memory when working on nv1, GPU, nvgpu, or Jetson topics.
