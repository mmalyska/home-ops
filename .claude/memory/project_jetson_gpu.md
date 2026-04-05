---
name: Jetson GPU (nvgpu) Extension Project
description: Active project to build a custom Talos nvgpu extension for nv1 (Jetson Orin NX 16GB). Plan and patch log at docs/src/k8s/jetson-gpu.md
type: project
---

**Goal:** Get CUDA GPU compute working on nv1 (Jetson Orin NX 16GB, 192.168.48.5) in Talos.

**Why:** Jetson GPU is on the Tegra platform bus, not PCIe. The official siderolabs
`nvidia-open-gpu-kernel-modules-lts` extension is for discrete PCIe GPUs and will never work.
The correct driver is `nvgpu` from OE4T/linux-nvgpu (branch `patches-r36.5`).

**Current phase:** Phase 1 — viability compilation test running as K8s Job on nv1.
Job file: `cluster/.tools/nvgpu-build-test.yaml`

**Kernel API patches discovered so far** (applied in the Job, needed for the real extension):
1. Multiple files — `vm_flags |=` read-only (kernel 6.3): use `vm_flags_set()`; `vm_flags &= ~` read-only: use `vm_flags_clear()` — apply across entire driver tree
2. `os/linux/ioctl.c` — `class_create` lost `THIS_MODULE` arg (kernel 6.4)
3. `os/linux/ioctl.c` — `devnode` callback `struct device *` → `const struct device *` (kernel 6.2)
4. `os/linux/*.c` — `struct fd` `.file` member removed (kernel 6.9): use `fd_file(fd)`
5. `os/linux/dmabuf_priv.c` (+ others) — `linux/dma-buf-map.h` removed (kernel 5.18): use `linux/iosys-map.h`; rename `struct dma_buf_map` → `struct iosys_map` and all `dma_buf_map_*`/`DMA_BUF_MAP_*` symbols
6. `os/linux/periodic_timer.c` (+ others) — `hrtimer_init` removed (kernel 6.15): replace two-line `hrtimer_init(x,clock,mode); x.function=cb;` with `hrtimer_setup(x, cb, clock, mode);` using `sed -z`
7. `os/linux/nvgpu_ivm.c`, `common/cbc/contig_pool.c` (+ more) — need `soc/tegra/virt/hv-ivc.h` (Tegra hypervisor/L4T only): grep all `.c` files including `hv-ivc.h`, replace with empty stubs (Makefile surgery breaks ifdef/endif balance)
8. `os/linux/module.c` — `platform_driver.remove` changed from `int(*)()` to `void(*)()` (kernel 6.11): change `gk20a_remove_wrapper` return type `int`→`void` + `return 0;`→`return;` using `sed -z`

**Gaps vs standard Talos NVIDIA flow (identified from Talos docs):**
- `machine.kernel.modules: [{name: nvgpu}]` missing — nvgpu.ko won't autoload on Talos
- `net.core.bpf_jit_harden: "1"` sysctl missing — required by nvidia-container-toolkit
- Device nodes differ: Jetson uses `/dev/nvgpu`, `/dev/nvhost-*`, `/dev/nvmap` (not `/dev/nvidia*`)
- `nvidia/k8s-device-plugin` uses NVML → finds 0 GPUs on Jetson; need CDI mode or custom plugin
- RuntimeClass `nvidia` still required for both Jetson and discrete GPU
- Container toolkit CDI spec must enumerate Tegra device paths manually (not NVML auto-generate)

**Commented placeholder added to talconfig.yaml** (nv1 node) for `machine.kernel.modules` + sysctl.

**Next steps:**
1. Run Job until BUILD EXIT CODE: 0 — collect any remaining patches
2. Package all patches + nvgpu.ko into a Talos sysext OCI image
3. Update talconfig.yaml: remove `nvidia-open-gpu-kernel-modules-lts` + `nvidia-container-toolkit-lts`, add custom nvgpu extension + activate commented patches block
4. Configure CDI spec for Tegra device nodes + deploy k8s-device-plugin in CDI mode
5. Regenerate + apply Talos config to nv1

**Full plan:** `docs/src/k8s/jetson-gpu.md`

**Why:** Getting GPU for ollama/whisper/piper workloads on nv1.
**How to apply:** Always load this memory when working on nv1, GPU, nvgpu, or Jetson topics.
