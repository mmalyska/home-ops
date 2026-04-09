# Plan: Build nvmap.ko as Part of nvgpu Module Infrastructure

## Context

Phase 0 CUDA validation on nv1 (Jetson Orin NX 16 GB) revealed that `libcuda.so.1` (L4T r36.4.0)
unconditionally opens `/dev/nvmap` at init via `NvRmMemInitNvmap`. The OE4T nvgpu.ko that is
currently deployed does **not** provide nvmap — it is a separate Tegra BSP kernel module that
lives in `drivers/video/tegra/nvmap` inside `OE4T/linux-nv-oot` (branch `patches-r36.5`).

**Objective**: build nvmap.ko, package it as a Talos system extension, deploy it on nv1 alongside
the existing nvgpu extension, and re-run the CUDA probe to confirm `cuInit(0)` returns 0.

The work touches three repos:
- `mmalyska/siderolabs-pkgs` fork — builds driver packages (branch `feat/jetson-nvgpu`)
- `mmalyska/siderolabs-extensions` fork — builds Talos extensions (branch `feat/jetson-nvgpu`)
- `home-ops` (this repo) — `talconfig.yaml` for nv1

---

## Task 1 — Add nvmap-driver-pkg to mmalyska-pkgs ✅

**Status**: Complete — committed and pushed to `feat/jetson-nvgpu`.

### 1.1 — Pin linux-nv-oot source in Pkgfile ✅

Added to `Pkgfile` alongside existing `jetson_nvgpu_*` vars:

```yaml
# renovate: datasource=git-refs versioning=git depName=https://github.com/OE4T/linux-nv-oot.git
jetson_nvmap_ref: ea32e7f97dd04c3f75aadc22424dc63568387120
jetson_nvmap_sha256: 9d2d70a121a418be307e3d1cd3c74d9ae9398e7abc756304d614e998dfd6f342
jetson_nvmap_sha512: 5645163e964bfb13d7aa2ee1749188fe40a1fe9012080f548548f7dc70e4397a762c161041d8d209d2cd969cbb4aab36ea5c560ef5967946eeb3f1dd16335b9c
```

### 1.2 — Create nvmap-driver/pkg.yaml ✅

Key differences from `nvgpu-driver/pkg.yaml`:
- Source: `linux-nv-oot` (NOT linux-nvgpu)
- Build directory: `drivers/video/tegra/nvmap` (NOT `drivers/gpu/nvgpu`)
- Extra make vars: `srctree.nvidia-oot`, `srctree.nvconftest`, `CONFIG_ARCH_TEGRA=y`, `CONFIG_TEGRA_OOT_MODULE=m`
- Extra KCPPFLAGS: `-I/nv-oot/include -I/conftest` (nvmap includes + conftest.h)
- Conftest setup step: copy `scripts/conftest/*` to `/conftest/nvidia/`

**Potential compat issues to resolve during build**:
- `NVMAP_CONFIG_SCIIPC=y` (auto-set for kernel 5.10+) pulls in `nvmap_sci_ipc.c` which needs
  `<linux/nvscierror.h>` and `<linux/nvsciipc_interface.h>` — both are in `linux-nv-oot/include/linux/`,
  so they should be found via `-I/nv-oot/include`
- `CONFIG_ARCH_TEGRA=y` must be accepted by the kernel build; if it causes issues, try passing
  as `KCPPFLAGS="-DCONFIG_ARCH_TEGRA=1 ..."`
- If build fails with missing symbols, may need to set `NVMAP_CONFIG_SCIIPC=n` explicitly

### 1.3 — Combine nvmap-driver-pkg into nvgpu-driver CI workflow ✅

Both `nvgpu-driver-pkg` and `nvmap-driver-pkg` are built in a single `make` invocation in
`.github/workflows/nvgpu-driver.yaml`. This avoids building the kernel twice — the `kernel-build`
stage is cached by BuildKit and reused by both packages.

```bash
make kernel nvgpu-driver-pkg nvmap-driver-pkg \
  PLATFORM=linux/arm64 ...
```

---

## Task 2 — Extend the existing nvgpu extension to include nvmap

**Rationale**: nvmap is always required for nvgpu/CUDA to function — they are never independently
useful on nv1, track the same L4T r36.5 release, and should always be co-versioned. bldr
`pkg.yaml` supports multiple `image:` dependencies. Combining them into a single `nvgpu`
extension keeps `talconfig.yaml` and the installer workflow unchanged.

**Critical files**:
- `nvidia-gpu/nvgpu/pkg.yaml` — add `nvmap-driver-pkg` dependency
- `nvidia-gpu/nvgpu/files/nvgpu.conf` — add nvmap softdep
- `nvidia-gpu/nvgpu/manifest.yaml.tmpl` — update description

### 2.1 — Add nvmap-driver-pkg as second dependency in nvgpu/pkg.yaml

```yaml
name: nvgpu
variant: scratch
dependencies:
  - stage: base
  - image: "{{ .BUILD_ARG_PKGS_PREFIX }}/nvgpu-driver-pkg:{{ .BUILD_ARG_PKGS }}"
  - image: "{{ .BUILD_ARG_PKGS_PREFIX }}/nvmap-driver-pkg:{{ .BUILD_ARG_PKGS }}"  # ← add
steps:
  - install:
      - mkdir -p /rootfs/usr/lib/modules /rootfs/usr/local/lib/modprobe.d
      - cp /pkg/files/nvgpu.conf /rootfs/usr/local/lib/modprobe.d/nvgpu.conf
      - cp -R /usr/lib/modules/* /rootfs/usr/lib/modules
finalize:
  - from: /rootfs
    to: /rootfs
  - from: /pkg/manifest.yaml
    to: /
```

The `cp -R /usr/lib/modules/*` step copies from the last mounted image layer — with two image
dependencies, bldr overlays both into the build container, so modules from both images are present
under `/usr/lib/modules/`.

### 2.2 — Add nvmap softdep to nvgpu.conf

Append to `nvidia-gpu/nvgpu/files/nvgpu.conf`:

```
# nvmap must be loaded before nvgpu (required by libcuda.so.1)
softdep nvgpu pre: nvmap
```

### 2.3 — Update manifest.yaml.tmpl description

```
description: |
  [{{ .TIER }}] This system extension provides the OE4T/linux-nvgpu and OE4T/linux-nv-oot
  (nvmap) kernel modules built against a specific Talos version, for NVIDIA Jetson Orin NX
  devices. nvgpu provides the Tegra GPU driver; nvmap provides /dev/nvmap required by
  libcuda.so.1.
```

### 2.4 — Push and verify CI

```bash
cd /tmp/mmalyska-extensions
git checkout feat/jetson-nvgpu
git add nvidia-gpu/nvgpu/
git commit -c commit.gpgsign=false -m "feat: include nvmap module in nvgpu extension"
git push
```

Verify: the rebuilt `ghcr.io/mmalyska/nvgpu:<tag>` contains both `nvgpu.ko` and `nvmap.ko`.
The installer workflow is unchanged — it still bakes one extension image.

---

## Task 3 — Update talconfig.yaml for nv1

**Critical file**: `provision/talos/talconfig.yaml`

Note: No new extension entry needed — the existing `nvgpu` extension reference already covers
both modules after Task 2. Only the image digest needs to be updated to the new build.

### 3.1 — Update the nvgpu extension digest in nv1 node config

Find the `nv1` node section, update the nvgpu image digest to the new tag that includes nvmap:

```yaml
extensions:
  - image: ghcr.io/mmalyska/nvgpu:<new-tag>@sha256:<new-digest>
```

Get the new digest from the CI build output or:

```bash
crane digest ghcr.io/mmalyska/nvgpu:<pkgs-tag>
```

### 3.2 — Regenerate and apply

```bash
task talos:generate
task talos:apply NODE=192.168.48.2   # nv1 = mc1
```

Then upgrade nv1 to the new installer image (which has both nvgpu + nvmap baked in).
Use `--stage` so the upgrade is staged and applied on the next reboot, avoiding timeout:

```bash
talosctl upgrade --nodes 192.168.48.2 \
  --image ghcr.io/mmalyska/talos-nv1-installer:<talos-version> \
  --stage
```

---

## Task 4 — Validate /dev/nvmap and CUDA

### 4.1 — Verify nvmap device node appears

```bash
talosctl -n 192.168.48.2 dmesg | grep nvmap
```

Expected: `nvmap: initialized` log line, `/dev/nvmap` char device present.

### 4.2 — Re-run cuInit probe

Re-deploy the cuda-probe pod from `cluster/apps/default/cuda-test/`.
Expected: `cuInit(0)` returns 0 (CUDA_SUCCESS).

### 4.3 — Clean up cuda-test namespace

```bash
kubectl delete namespace cuda-test
```

### 4.4 — Update docs

Update `docs/src/k8s/jetson-cuda-extension.md`:
- Mark OQ-13 (BLOCKER: nvmap) as RESOLVED
- Add Phase 0 completion status with cuInit result
- Document nvmap source: OE4T/linux-nv-oot patches-r36.5

---

## Verification

End-to-end validation:
1. `docker run --rm ghcr.io/mmalyska/nvgpu:<tag> find / -name nvmap.ko` — confirms module built
2. `talosctl -n 192.168.48.2 dmesg | grep -i nvmap` — confirms module loaded on nv1
3. `talosctl -n 192.168.48.2 read /dev/nvmap` — confirms device node exists
4. cuda-probe pod logs show `cuInit returned: 0` — CUDA unblocked

---

## Key References

| Item | Location |
|------|----------|
| nvmap source | `OE4T/linux-nv-oot` `patches-r36.5` at `drivers/video/tegra/nvmap/` |
| nvmap ref (pinned) | `ea32e7f97dd04c3f75aadc22424dc63568387120` |
| Conftest headers | `linux-nv-oot/scripts/conftest/` → copy to `/conftest/nvidia/` |
| nvmap includes needed | `linux-nv-oot/include/` (nvmap.h, nvmap_t19x.h, nvscierror.h, nvsciipc_interface.h) |
| pkgs nvmap-driver/pkg.yaml | `mmalyska/siderolabs-pkgs` `feat/jetson-nvgpu` |
| pkgs CI workflow | `.github/workflows/nvgpu-driver.yaml` (builds both packages) |
| extensions nvgpu/pkg.yaml | `mmalyska/siderolabs-extensions` `feat/jetson-nvgpu` |
| nv1 node config | `provision/talos/talconfig.yaml` |
