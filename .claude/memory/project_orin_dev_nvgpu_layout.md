---
name: Orin /dev/nvgpu device layout
description: On Orin t234, /dev/nvgpu is a directory with sub-devices, not a char device
type: project
---

On Orin (t234), `/dev/nvgpu` is a DIRECTORY not a char device.

Structure: `/dev/nvgpu/igpu0/` with 13 sub-devices: `as`, `channel`, `ctrl`, `ctxsw`, `dbg`, `nvsched`, `nvsched_ctrl_fifo`, `power`, `prof`, `prof-ctx`, `prof-dev`, `sched`, `tsg`.

The flat `/dev/nvhost-*` devices (`nvhost-as-gpu`, `nvhost-ctrl-gpu`, etc.) also exist alongside. There is NO `/dev/nvmap` on Orin.

CDI `l4t.csv` must list `/dev/nvgpu/igpu0/*` not `/dev/nvgpu`.

`l4t-cuda:12.2.12-runtime` does NOT have `libcuda.so.1` (Tegra driver lib). Tegra `libcuda.so.1` comes from `nvidia-l4t-cuda` APT package, installed on top of `l4t-base:r36.2.0` image.

**Why:** Incorrect device paths in CDI spec cause container GPU access failures.

**How to apply:** Always use `/dev/nvgpu/igpu0/*` pattern in any CSV/CDI device lists for Orin.
