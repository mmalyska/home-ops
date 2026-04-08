---
name: nvgpu patch safety audit required on every change
description: Every time nvgpu-kernel-compat.patch is modified, run a full symbol/caller audit before committing
type: feedback
---

After every change to `nvgpu-kernel-compat.patch` (or `nv_compat.h`), run the following safety audit before pushing:

**Why:** Stub changes that look harmless can introduce modpost undefined-symbol errors or crash-on-load NULL function pointer dereferences that only surface after a multi-hour ARM CI run. The audit catches these early.

**How to apply:** Any time a hunk is added, removed, or modified in the patch file, repeat all four checks below against a fresh copy of the OE4T source.

## Audit Checklist

### 1. Restore a clean source tree first
```bash
rm -rf /tmp/nvgpu-src
mkdir /tmp/nvgpu-src
tar -xzf /tmp/nvgpu.tar.gz -C /tmp/nvgpu-src --strip-components=1
```

### 2. Verify the patch applies cleanly
```bash
git -C /tmp/nvgpu-src apply --check /tmp/mmalyska-pkgs/nvgpu-driver/files/nvgpu-kernel-compat.patch
```
Must exit 0 with no output.

### 3. For every file replaced by a stub, verify its symbols are not referenced by compiled code

For each stubbed file:
a. List the non-static symbols the ORIGINAL file exports (these are now absent or replaced).
b. List the non-static symbols the STUB exports.
c. Grep all callers of absent symbols across the driver tree.
d. For each caller file, check its Makefile guard (`nvgpu-$(CONFIG_*)`) — if the guard config is not set on vanilla kernel, the caller is never compiled → safe.
e. If a caller IS compiled unconditionally, the stub MUST export the symbol.

**Configs that are NOT set on vanilla kernel** (not hardcoded in nvgpu Makefile lines 85-113):
- `CONFIG_NVGPU_IVM_BUILD` — guards `nvgpu_ivm.o` and `contig_pool.o`
- `CONFIG_NVGPU_GR_VIRTUALIZATION` — guards all `vgpu/` objects
- `CONFIG_NVGPU_COMPRESSION` — guards `cbc.o`, `contig_pool.o`, `comptags.o`
- `CONFIG_NVGPU_TEGRA_FUSE` — NOT defined; `soc.h` provides inline fallbacks for all soc functions except `nvgpu_get_pa_from_ipa` (whose only caller is the stubbed `contig_pool.c`)
- `CONFIG_TEGRA_GK20A` — must be `y` or `m` for the module to be useful at all

**Configs that ARE hardcoded** (always defined, lines 85-113 of nvgpu Makefile):
`CONFIG_NVGPU_GRAPHICS`, `CONFIG_NVGPU_POWER_PG`, `CONFIG_NVGPU_LS_PMU`, `CONFIG_NVGPU_KERNEL_MODE_SUBMIT`, and ~20 others — objects guarded by these are ALWAYS compiled.

### 4. For every platform struct stub, check for unconditional callback invocations

The driver calls some platform callbacks unconditionally (no NULL check). Any platform struct exported by a stub must have these populated:

For `ga10b_tegra_platform` (`struct gk20a_platform`):
- `.probe` — called unconditionally at `driver_common.c:470` → MUST be non-NULL
- `.is_railgated` — called unconditionally at `module.c:793, 854, 918, 1357` → MUST be non-NULL
- All other callbacks are NULL-guarded by the caller → safe to leave NULL

```c
static int ga10b_tegra_probe_stub(struct device *dev) { return 0; }
static bool ga10b_is_railgated_stub(struct device *dev) { return false; }

struct gk20a_platform ga10b_tegra_platform = {
    .probe        = ga10b_tegra_probe_stub,
    .is_railgated = ga10b_is_railgated_stub,
};
```

### 5. Verify hunk line counts are accurate

After editing stub content, recount lines in the `+` side of every modified hunk header `@@ -A,B +C,D @@`. Off-by-one in D causes `git apply` to fail. Always do the `--check` step (step 2) after any line count change.
