# nvgpu Extension — Upgrade & Maintenance Guide

When a new Talos release bumps the kernel version, the `nvgpu` extension may fail to build.
This guide explains how to investigate and fix it.

> **Related docs:**
> - [jetson-gpu.md](jetson-gpu.md) — full architecture and build plan
> - [jetson-cuda-extension.md](jetson-cuda-extension.md) — CUDA extension plan

---

## Background: what changes on a Talos upgrade

A Talos upgrade bumps the kernel version (e.g., 6.18 → 6.19) **and** the PKGS tag (the OCI image
set that Talos uses for kernel builds). Both must be updated together. This triggers up to three
failure modes:

| Failure mode | Symptom | Root cause |
|---|---|---|
| **NV_* macro mismatch** | Compile error in `nvgpu/os/linux/` or `nvgpu/drivers/gpu/nvgpu/` | A kernel API changed; nvgpu has an `#ifdef NV_*` guard for it, but `nv_compat.h` is not updated |
| **New L4T stub needed** | `fatal error: some/l4t/header.h: No such file` | OE4T upstream added new L4T-BSP-only code without a vanilla alternative |
| **Extensions CI "not found"** | `ghcr.io/mmalyska/nvgpu-driver-pkg:<pkgs-tag>: not found` | pkgs fork git tag missing — see below |

---

## Critical: pkgs fork git tag must match the PKGS tag

The extensions `pkg.yaml` pulls the driver package as:

```
ghcr.io/mmalyska/nvgpu-driver-pkg:{{ .BUILD_ARG_PKGS }}
```

The bldr tool derives the image tag from `git describe --tag --match 'v[0-9]*'` on the pkgs repo.
**If the pkgs fork has no matching git tag, bldr falls back to the short commit SHA** (e.g.
`8f563d4`) and the extensions CI fails with `not found` even though the pkgs CI passed.

### Fix: tag the pkgs fork before the extensions build

```bash
# 1. Find the new PKGS tag from the Talos release
# https://github.com/siderolabs/talos/blob/<version>/pkg/machinery/gendata/data/pkgs
NEW_PKGS_TAG=v1.XX.Y-N-gabcdef0

# 2. Get the current HEAD of feat/jetson-nvgpu on the pkgs fork
HEAD=$(git -C /tmp/mmalyska-pkgs rev-parse HEAD)

# 3. Create and push the tag
git -C /tmp/mmalyska-pkgs tag ${NEW_PKGS_TAG} ${HEAD}
git -C /tmp/mmalyska-pkgs push origin ${NEW_PKGS_TAG}

# 4. Update the hardcoded PKGS default in the extensions workflow
# mmalyska/siderolabs-extensions/.github/workflows/nvgpu.yaml
# Change: default: "v1.12.0-50-ga92bed5"
# To:     default: "${NEW_PKGS_TAG}"

# 5. Wait for pkgs CI to finish and publish nvgpu-driver-pkg:${NEW_PKGS_TAG}
# THEN trigger extensions CI — not before
gh run list --repo mmalyska/siderolabs-pkgs --branch feat/jetson-nvgpu --limit 3
```

**Order matters:** pkgs CI must complete and publish the image **before** the extensions CI runs.
Triggering them in parallel will always fail.

---

## Step 1 — Identify the target kernel version

```bash
# In mmalyska/siderolabs-pkgs, find the kernel version for the new Talos release
grep -n "kernel\|KERNEL" Pkgfile | head -20

# Cross-reference with Talos release notes:
# https://github.com/siderolabs/talos/releases
```

---

## Step 2 — Reproduce the build failure locally

```bash
cd /tmp/mmalyska-pkgs    # or wherever the pkgs fork is checked out
make nvgpu-driver \
  PLATFORM=linux/arm64 \
  REGISTRY=ghcr.io \
  USERNAME=mmalyska \
  PUSH=false \
  2>&1 | tee /tmp/nvgpu-build.log
```

Collect the full error output — this is your ground truth.

---

## Step 3 — Check if OE4T upstream already fixed it

Before patching locally, check if `patches-r36.5` received new commits since the pinned ref:

```bash
# Clone or update the nvgpu repo
git clone --depth=50 --branch patches-r36.5 https://github.com/OE4T/linux-nvgpu.git /tmp/nvgpu
# or: git -C /tmp/nvgpu fetch origin

# Compare pinned commit vs branch HEAD
PINNED=$(grep jetson_nvgpu_ref Pkgfile | awk '{print $2}')
git -C /tmp/nvgpu log ${PINNED}..origin/patches-r36.5 --oneline
```

If upstream has new commits that fix the build error, bump the ref in `Pkgfile` and regenerate
checksums (see [Step 7](#step-7--bump-the-nvgpu-source-ref) below).

---

## Step 4 — Categorize the error

### Case A: NV_* macro missing (most common)

**Symptom:**
```
error: implicit declaration of function 'foo_new_api'
error: 'FOO' undeclared
```

The nvgpu driver wraps every kernel API change behind an `#ifdef NV_*` guard. When a guard macro
is not defined, the compiler picks the wrong branch.

**Investigation:**

```bash
# 1. Find the NV_* guard that covers the failing symbol
grep -rn "ifdef NV_" /tmp/nvgpu/drivers/gpu/nvgpu/ | grep -i "foo"

# 2. Check whether the new kernel has the feature
#    (the kernel source is available inside the build container at /src)
grep -rn "foo_new_api" /src/include/ /src/kernel/ 2>/dev/null | head -10
```

**Fix:**

If the new kernel **has** the new API:
```c
// Add to nvgpu-driver/files/nv_compat.h with a comment
/* foo_new_api() replaced foo_old_api() in 6.XX */
#define NV_FOO_PRESENT
```

If the new kernel does **not** have the new API (or the feature was removed):
- Do NOT define the macro — the `#else` branch of the guard handles the old API.
- If a previously-defined macro is now wrong, **remove** it from `nv_compat.h`.

> **Critical:** Getting the direction wrong compiles but produces wrong runtime behavior.
> Always read the `#ifdef`/`#else` block in the nvgpu source to confirm which branch is new vs old.

---

### Case B: Missing L4T-only header

**Symptom:**
```
fatal error: soc/tegra/some/bsp/header.h: No such file or directory
fatal error: linux/platform/tegra/some_header.h: No such file or directory
```

These headers are Tegra BSP / L4T-only and do not exist in a vanilla kernel.

**Investigation:**

```bash
# Find which .c file includes the missing header
grep -rn "some/bsp/header.h" /tmp/nvgpu/drivers/gpu/nvgpu/ --include="*.c"

# Verify the code in that file is dead on bare-metal
# (look for Tegra hypervisor IVC usage, BSP memory controller code, etc.)
head -50 /tmp/nvgpu/drivers/gpu/nvgpu/path/to/the/file.c
```

**Fix:** Add a stub entry to `nvgpu-driver/files/nvgpu-kernel-compat.patch`:

```diff
--- a/drivers/gpu/nvgpu/path/to/the/file.c
+++ b/drivers/gpu/nvgpu/path/to/the/file.c
@@ -1,N +1,2 @@
-/* original content */
+/* stub: L4T-only header (some/bsp/header.h) not available on vanilla kernel. */
+/* This file contains Tegra BSP-only code unused on bare-metal nv1. */
```

Verify the patch applies cleanly:
```bash
git clone --depth=1 --branch patches-r36.5 https://github.com/OE4T/linux-nvgpu.git /tmp/nvgpu-test
git -C /tmp/nvgpu-test apply nvgpu-driver/files/nvgpu-kernel-compat.patch
```

---

### Case C: Linker error / undefined symbol

**Symptom:**
```
ERROR: modpost: "some_kernel_symbol" [nvgpu.ko] undefined!
```

A kernel export was renamed or removed.

**Investigation:**

```bash
# Check if the symbol still exists in the new kernel
grep -rn "EXPORT_SYMBOL.*some_kernel_symbol" /src/ 2>/dev/null

# Check git history of the relevant header
git -C /path/to/kernel-source log --oneline -- include/linux/relevant_header.h | head -10
```

If the symbol was renamed (new name has an NV_* guard in nvgpu) → add the appropriate `NV_*`
macro to `nv_compat.h`.

If the symbol was removed entirely and nvgpu has no guard for it → open an issue on
[OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) upstream.

---

## Step 5 — Document changes in nv_compat.h

Every entry in `nv_compat.h` must have a comment explaining the kernel version and the API change:

```c
/* foo_new_api() replaced foo_old_api() in 6.XX */
#define NV_FOO_PRESENT

/* bar_struct.field removed in 6.YY — use bar_get_field() instead */
#define NV_BAR_HAS_FIELD
```

This is the primary reference for future debugging — treat it as a changelog.

---

## Step 6 — Rebuild and verify

```bash
make nvgpu-driver \
  PLATFORM=linux/arm64 \
  REGISTRY=ghcr.io \
  USERNAME=mmalyska \
  PUSH=false
```

Expected output ends with:
```
Successfully built <image-id>
```

The build also runs `fhs-validator /rootfs` and checks that all `.ko` files lack the module
signature marker — both are part of the `test:` step in `pkg.yaml`.

---

## Step 7 — Bump the nvgpu source ref

If OE4T upstream fixed the issue or you want to track a newer commit:

```bash
NEW_REF=<new-commit-sha>

# Regenerate checksums
SHA256=$(curl -sL "https://github.com/OE4T/linux-nvgpu/archive/${NEW_REF}.tar.gz" | sha256sum | awk '{print $1}')
SHA512=$(curl -sL "https://github.com/OE4T/linux-nvgpu/archive/${NEW_REF}.tar.gz" | sha512sum | awk '{print $1}')

echo "jetson_nvgpu_ref: ${NEW_REF}"
echo "jetson_nvgpu_sha256: ${SHA256}"
echo "jetson_nvgpu_sha512: ${SHA512}"
```

Update `Pkgfile` lines 201–204 in `mmalyska/siderolabs-pkgs`:

```yaml
# renovate: datasource=git-refs versioning=git depName=https://github.com/OE4T/linux-nvgpu.git
jetson_nvgpu_ref: <NEW_REF>
jetson_nvgpu_sha256: <SHA256>
jetson_nvgpu_sha512: <SHA512>
```

Also update the VERSION prefix in `nvidia-gpu/nvgpu/vars.yaml` in the extensions repo to match
the first 7 characters of the new commit SHA.

---

## Step 8 — Push and tag

```bash
# Build and push the updated driver package
cd /tmp/mmalyska-pkgs
make nvgpu-driver \
  PLATFORM=linux/arm64 \
  REGISTRY=ghcr.io \
  USERNAME=mmalyska \
  PUSH=true

# Build and push the Talos extension (get the new PKGS tag from the pkgs repo output)
cd /tmp/mmalyska-extensions
make nvgpu \
  PLATFORM=linux/arm64 \
  REGISTRY=ghcr.io \
  USERNAME=mmalyska \
  PKGS=<new-pkgs-tag> \
  PKGS_PREFIX=ghcr.io/mmalyska \
  PUSH=true
```

Then update `talconfig.yaml` with the new extension image digest and apply to `nv1`:

```bash
task talos:generate
task talos:apply NODE=192.168.48.5
```

---

## Quick decision tree

```
New Talos version released
          │
          ▼
make nvgpu-driver PUSH=false
          │
    ┌─────┴──────┐
  BUILD OK    BUILD FAIL
    │               │
    ▼               ▼
Done ✓       Check OE4T patches-r36.5 for new commits
                    │
              ┌─────┴─────┐
           New commits  No fix upstream
              │               │
              ▼               ▼
          Bump ref       Categorize error
          + checksums         │
                    ┌─────────┴──────────┐
                fatal error          implicit decl /
                header not found     undeclared identifier
                    │                       │
                    ▼                       ▼
              Add stub to           Search nvgpu source for
              .patch file           #ifdef NV_* guard
              (L4T-only file)            │
                                Define or undefine macro
                                in nv_compat.h with comment
                                         │
                                    Rebuild → verify green
                                         │
                                Commit, push, update talconfig
```

---

## Files reference

| What | File | Repo |
|---|---|---|
| NV_* macro shims | `nvgpu-driver/files/nv_compat.h` | `mmalyska/siderolabs-pkgs` |
| L4T file stubs | `nvgpu-driver/files/nvgpu-kernel-compat.patch` | `mmalyska/siderolabs-pkgs` |
| Source ref + checksums | `Pkgfile` lines 201–204 | `mmalyska/siderolabs-pkgs` |
| Extension version string | `nvidia-gpu/nvgpu/vars.yaml` | `mmalyska/siderolabs-extensions` |
| talconfig node config | `provision/talos/talconfig.yaml` | `home-ops` |

---

## Known pre-existing warnings (non-fatal)

```
WARNING: modpost: nvgpu: section mismatch in reference: gk20a_driver+0x8 (section: .data)
         -> gk20a_remove_wrapper (section: .exit.text)
```

This is a pre-existing issue in the OE4T driver — `gk20a_remove_wrapper` is marked `__exit` but
referenced from the non-exit `gk20a_driver` struct. It is a warning only and does not prevent the
module from loading.

---

## Current NV_* macros (kernel 6.18 baseline)

These are the macros currently defined in `nv_compat.h` and the kernel version each one covers:

| Macro | Since kernel | API change |
|---|---|---|
| `NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS` | 6.3 | `vm_flags_set()`/`vm_flags_clear()` instead of `\|=`/`&=~` |
| `NV_CLASS_CREATE_HAS_NO_OWNER_ARG` | 6.4 | `class_create(name)` — `THIS_MODULE` arg removed |
| `NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG` | 6.2 | `const struct device *` in devnode callback |
| `NV_FD_FILE_PRESENT` | 6.9 | `fd_file(fd)` accessor |
| `NV_FD_EMPTY_PRESENT` | 6.12 | `fd_empty(fd)` accessor |
| `NV_HRTIMER_SETUP_PRESENT` | 6.14-rc1 | `hrtimer_setup()` merges `hrtimer_init` + `.function` |
| `NV_LINUX_IOSYS_MAP_H_PRESENT` | 5.18 | `linux/iosys-map.h` (renamed from `dma-buf-map.h`) |
| `NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID` | 6.11 | `platform_driver.remove` is `void(*)(...)` |
| `NV_DEVM_CLK_GET_OPTIONAL_PRESENT` | 5.1 | `devm_clk_get_optional()` |
| `NV_DMA_ALLOC_ATTRS_PRESENT` | 4.8 | `dma_alloc_attrs()` |
| `NV_OF_PROPERTY_READ_VARIABLE_U32_ARRAY_PRESENT` | 4.10 | `of_property_read_variable_u32_array()` |
| `NV_DRM_GEM_OBJECT_PUT_PRESENT` | 5.9 | `drm_gem_object_put()` non-locked variant |
| `NV_DRM_DRIVER_HAS_GEM_PRIME_RES_OBJ` | — | `drm_driver.gem_prime_res_obj` field exists |
| `NV_PCI_ENABLE_ATOMIC_OPS_TO_ROOT_PRESENT` | 4.16 | `pci_enable_atomic_ops_to_root()` |

**NOT defined** (intentional): `NV_MODULE_IMPORT_NS_CALLS_STRINGIFY` — kernel 6.18 uses
string literal form `MODULE_IMPORT_NS("DMA_BUF")`, not the `STRINGIFY` macro form.
