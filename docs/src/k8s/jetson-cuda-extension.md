# Jetson Orin NX — Tegra CUDA Talos Extension Plan

## Prerequisite

> **[jetson-gpu plan](./archive/jetson-gpu.md) Phases 1–4 are complete** (archived 2026-04-11).
> `nvgpu.ko` + `nvmap.ko` load on `nv1` via `ghcr.io/mmalyska/talos-nv1-installer`.
> Confirmed: `/dev/nvmap` present, all `/dev/nvhost-*` Tegra device nodes present at boot.
>
> This plan adds the CUDA container runtime layer on top of that foundation.

---

## Goal

Build a Talos system extension (`nvgpu-toolkit`) that installs `nvidia-container-runtime` and
`libnvidia-container` (Tegra/CSV mode) onto `nv1`, enabling containers to receive injected
Tegra device nodes at startup without bundling any CUDA libraries themselves.

The end state: a pod with `runtimeClassName: nvidia` and resource request `nvidia.com/gpu: 1`
can run standard CUDA workloads (ollama, whisper, inference frameworks) using L4T-based
container images (`dustynv/*`) which carry their own `libcuda.so` Tegra stack.

---

## Why This Is Needed

The [jetson-gpu plan](./jetson-gpu.md) loads `nvgpu.ko` and exposes Tegra GPU device nodes to
Kubernetes. That is necessary but not sufficient for CUDA. CUDA requires a Tegra-specific
`libcuda.so` that speaks the nvgpu ioctl ABI (`/dev/nvhost-*` + unified memory model). This
library is architecturally incompatible with the standard discrete-GPU `libcuda.so`:

| | Discrete GPU | Jetson Tegra (Orin/t234) |
|---|---|---|
| Kernel driver | `nvidia.ko` | `nvgpu.ko` + `nvmap.ko` (separate) |
| Device nodes | `/dev/nvidia0`, `/dev/nvidiactl` | `/dev/nvgpu/igpu0/{ctrl,channel,as,...}`, `/dev/nvhost-*` (13 flat devices) |
| ioctl magic | `'F'` (base 200) | `'G'`, `'A'`, `'H'`, `'T'`, `'D'` |
| `libcuda.so` source | CUDA Toolkit / `libnvidia-compute` | JetPack `nvidia-l4t-cuda` |

Standard `nvidia/cuda:*` container images contain the discrete-GPU `libcuda.so` and will not
work on Jetson regardless of device node injection.

The correct approach for Tegra uses `nvidia-container-runtime` with `libnvidia-container`
compiled `--enable-tegra` (CSV/plugin mode), which injects Tegra device nodes into containers
at runtime. L4T-based container images (`dustynv/*`) carry their own correct `libcuda.so`
Tegra stack — no host lib extraction is needed.

---

## Architecture Overview

```
nv1 node (Talos Linux)
├── nvgpu extension (DEPLOYED — ghcr.io/mmalyska/talos-nv1-installer)
│   ├── nvgpu.ko loaded → /dev/nvgpu/ (dir), /dev/nvhost-* created
│   └── nvmap.ko loaded → /dev/nvmap created
│
└── nvgpu-toolkit extension (new — Phase 1/2 of this plan)
    ├── nvidia-container-runtime binary (/usr/bin/nvidia-container-runtime)
    ├── libnvidia-container.so (built --enable-tegra, CSV plugin mode)
    ├── l4t.csv — device node list (/dev/nvhost-*, /dev/nvmap)
    └── containerd config: registers nvidia-container-runtime handler

containerd
└── handler: nvidia  →  nvidia-container-runtime (OCI hook)
                            └── libnvidia-container (Tegra/CSV mode)
                                    ├── reads l4t.csv → injects /dev/nvhost-* device nodes
                                    └── L4T container image carries its own libcuda.so etc.

Container (e.g. dustynv/ollama:r36.x):
└── runtimeClassName: nvidia
    → nvidia-container-runtime injects /dev/nvhost-* + /dev/nvmap
    → L4T image's libcuda.so speaks the nvgpu ioctl ABI → CUDA works
```

No CUDA libraries need to be on the host. Workloads must use L4T-based container images.

---

## Phase 0 — Investigation: Prove lib injection before building

**Do this phase first. It validates the entire approach with zero build infrastructure.**

### Goal

Manually replicate what the extension will do, on a live `nv1` node, and confirm that
`cudaGetDeviceCount()` returns a positive value inside a container.

### Steps

1. **Extract L4T CUDA packages onto `nv1`**

   From the Jetson L4T apt repo for Orin (t234 platform, r36.x series):
   ```bash
   # On a machine with internet access — download the .deb files
   # NOTE: correct timestamp for r36.4.0 is 20240912212859 (NOT 20240910085053)
   curl -LO https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-core/nvidia-l4t-core_36.4.0-20240912212859_arm64.deb
   curl -LO https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-cuda/nvidia-l4t-cuda_36.4.0-20240912212859_arm64.deb

   # Extract file trees (no install scripts — just the files)
   dpkg -x nvidia-l4t-core_*.deb ./l4t-rootfs
   dpkg -x nvidia-l4t-cuda_*.deb ./l4t-rootfs

   # Check what landed
   find ./l4t-rootfs/usr/lib/aarch64-linux-gnu/tegra/ -name "libcuda*"
   ```

2. **Copy extracted libs to `nv1`**

   ```bash
   # Via talosctl cp or kubectl debug node pod
   kubectl debug node/nv1 -it --image=alpine -- chroot /host
   # Copy l4t-rootfs/usr/lib/aarch64-linux-gnu/tegra/ to the node's filesystem
   ```

   > **Note:** Talos has a read-only rootfs. The writable overlay path is `/var/`. Use
   > `/var/lib/tegra/` as a staging area. The CDI spec will reference this path.

3. **Write a static CDI spec by hand**

   CDI is a JSON/YAML file at `/run/cdi/nvidia.yaml` that tells containerd what to inject.
   Minimal Tegra CDI spec:

   ```yaml
   cdiVersion: "0.5.0"
   kind: nvidia.com/gpu
   devices:
     - name: "0"
       containerEdits:
         deviceNodes:
           # /dev/nvgpu is a DIRECTORY — mount it as a whole
           - path: /dev/nvgpu
           # Flat nvhost devices
           - path: /dev/nvhost-ctrl
           - path: /dev/nvhost-ctrl-gpu
           - path: /dev/nvhost-gpu
           - path: /dev/nvhost-as-gpu
           - path: /dev/nvhost-ctxsw-gpu
           - path: /dev/nvhost-dbg-gpu
           - path: /dev/nvhost-prof-gpu
           - path: /dev/nvhost-tsg-gpu
           # /dev/nvmap — requires nvmap.ko extension (NOT present with nvgpu-only)
           - path: /dev/nvmap
         mounts:
           - hostPath: /var/lib/tegra/usr/lib/aarch64-linux-gnu/tegra
             containerPath: /usr/lib/aarch64-linux-gnu/tegra
             options: ["ro", "bind"]
         env:
           - NVIDIA_VISIBLE_DEVICES=0
   containerEdits: {}
   ```

   Write this to `/run/cdi/nvidia.yaml` on `nv1`.

4. **Configure containerd CDI on `nv1`**

   Talos containerd config is managed via machine config patches. Add:
   ```yaml
   machine:
     files:
       - path: /etc/cri/conf.d/20-enable-cdi.toml
         op: create
         content: |
           [plugins."io.containerd.cri.v1.runtime"]
             enable_cdi = true
             cdi_spec_dirs = ["/run/cdi"]
   ```

5. **Create a RuntimeClass**

   ```yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: nvidia
   handler: runc   # standard runc; CDI injection is handled by containerd, not a custom runtime
   ```

   > **Note:** This differs from discrete GPU flow (which uses `handler: nvidia`). With CDI,
   > the standard `runc` runtime handles execution; containerd does the device/lib injection
   > before handing off to runc. Verify whether `handler: nvidia` (pointing to
   > `nvidia-container-runtime`) is required or whether pure CDI with runc suffices.

6. **Run a CUDA validation pod**

   ```yaml
   apiVersion: v1
   kind: Pod
   metadata:
     name: cuda-probe
   spec:
     runtimeClassName: nvidia
     restartPolicy: Never
     containers:
       - name: probe
         image: dustynv/cuda:12.2-r36.2.0   # JetPack-based image with CUDA toolkit
         command: ["nvidia-smi"]
         resources:
           limits:
             nvidia.com/gpu: "1"
   ```

   If `nvidia-smi` is unavailable on Tegra (it may be), use a Python CUDA probe instead:
   ```python
   import ctypes
   lib = ctypes.CDLL("libcuda.so")
   print(lib.cuInit(0))  # should return 0 (CUDA_SUCCESS)
   ```

7. **Evaluate result**

   - `cuInit(0)` returns `CUDA_SUCCESS (0)` → lib injection works, proceed to Phase 1
   - Returns `CUDA_ERROR_NO_DEVICE (100)` → device nodes not injected correctly
   - `libcuda.so: cannot open` → lib paths not injected correctly
   - `NvRmMemInitNvmap failed: No such file or directory` + `cuInit(0) = 999` → `/dev/nvmap` missing, need `nvmap.ko`
   - Segfault / illegal instruction → wrong libcuda.so ABI (wrong L4T version)

### Phase 0 Findings (completed 2026-04-09)

#### OQ-1 — RESOLVED: dpkg -x is sufficient, symlinks are preserved

`dpkg -x` produces a clean file tree with all symlinks intact:
- `libcuda.so.1.1` (41 MB real file) at `/usr/lib/aarch64-linux-gnu/tegra/`
- `libcuda.so.1 → libcuda.so.1.1` (symlink)
- `libcuda.so → libcuda.so.1.1` (symlink)
- Top-level compat symlink: `/usr/lib/aarch64-linux-gnu/libcuda.so`

Maintainer scripts are not needed for library extraction.

#### OQ-4 — RESOLVED: Device node layout on nv1

`/dev/nvgpu` is a **directory**, not a character device. Full structure:

```
/dev/nvgpu/
└── igpu0/
    ├── as
    ├── channel
    ├── ctrl
    ├── ctxsw
    ├── dbg
    ├── nvsched
    ├── nvsched_ctrl_fifo
    ├── power
    ├── prof
    ├── prof-ctx
    ├── prof-dev
    ├── sched
    └── tsg
```

Flat nvhost devices at `/dev/`:
- `nvhost-ctrl`, `nvhost-ctrl-gpu`, `nvhost-gpu`, `nvhost-as-gpu`
- `nvhost-ctxsw-gpu`, `nvhost-dbg-gpu`, `nvhost-nvsched-gpu`
- `nvhost-nvsched_ctrl_fifo-gpu`, `nvhost-power-gpu`
- `nvhost-prof-ctx-gpu`, `nvhost-prof-dev-gpu`, `nvhost-prof-gpu`
- `nvhost-sched-gpu`, `nvhost-tsg-gpu`

**`/dev/nvmap` does NOT exist** — it is not created by the OE4T `nvgpu.ko` module.

#### OQ-5 — RESOLVED: Symlinks preserved by dpkg -x

Confirmed — see OQ-1 above.

#### OQ-6 — RESOLVED: Correct L4T package URLs for t234/r36.4

Packages live in the `t234` repo (NOT `common`). Available r36.4.x versions (use index from
`https://repo.download.nvidia.com/jetson/t234/dists/r36.4/main/binary-arm64/Packages.gz`):

| Version | Timestamp | JetPack |
|---------|-----------|---------|
| `36.4.0-20240912212859` | Sep 2024 | JetPack 6.0 |
| `36.4.3-20250107174145` | Jan 2025 | JetPack 6.1 |
| `36.4.4-20250616085344` | Jun 2025 | JetPack 6.1+ |
| `36.4.7-20250918154033` | Sep 2025 | JetPack 6.x |

URL pattern: `https://repo.download.nvidia.com/jetson/t234/pool/main/n/{pkg}/{pkg}_{version}_arm64.deb`

#### BLOCKER — nvmap.ko required for cuInit (SUPERSEDED — see below)

When device nodes and libcuda are both correctly injected, `cuInit(0)` returns **999 (CUDA_ERROR_UNKNOWN)**
with the following error from libcuda internals:

```
NvRmMemInitNvmap failed with No such file or directory
Memory Manager Not supported
****NvRmMemMgrInit failed**** error type: 196626
```

`nvmap.ko` was added (2026-04-10). With `/dev/nvmap` present, `cuInit(0)` returns **801
(CUDA_ERROR_SYSTEM_NOT_READY)**. See blocker below.

#### BLOCKER — CDI approach is architecturally incorrect for Jetson

**Root cause identified (2026-04-10):** The `libcuda.so.1.1` from `nvidia-l4t-cuda` is a
**discrete GPU shim** — it references `/dev/nvidiactl`, `/dev/nvidia0`, etc. and returns
`CUDA_ERROR_SYSTEM_NOT_READY (801)` on Tegra because those paths do not exist.

The Tegra iGPU CUDA stack uses a fundamentally different injection mechanism:

| Aspect | Discrete GPU (CDI) | Jetson Tegra (correct) |
|--------|-------------------|----------------------|
| Device nodes | `/dev/nvidiactl`, `/dev/nvidia0` | `/dev/nvhost-*`, `/dev/nvmap` |
| Library injection | CDI spec | `nvidia-container-runtime` CSV plugins |
| Config path | `/var/cdi/` | `/etc/nvidia-container-runtime/host-files-for-container.d/*.csv` |
| Container runtime | runc + CDI | `nvidia-container-runtime` handler |
| Base image | Generic CUDA images | L4T images (`l4t-base`, `l4t-cuda`) |

**Correct architecture:**

1. `containerd` must use `handler: nvidia` (nvidia-container-runtime, not runc)
2. `nvidia-container-runtime` reads CSV files listing Tegra device nodes and libs to inject
3. L4T userspace libs are already present in L4T base container images — no host extraction needed
4. The Tegra extension must bundle `libnvidia-container` with Tegra/CSV support

This invalidates the Phase 1 `nvgpu-cuda-pkg` design (lib extraction + CDI). Phase 1 must
instead build `nvidia-container-toolkit` for Talos with Tegra CSV plugin support.

References:
- https://nvidia.github.io/container-wiki/toolkit/jetson.html
- https://github.com/NVIDIA/libnvidia-container/blob/jetson/design/mount_plugins.md

### Open questions to answer in Phase 0

- **OQ-1**: ~~Do `nvidia-l4t-core` maintainer scripts perform runtime setup?~~ RESOLVED — moot,
  libs are not extracted to host; they live in L4T container images.
- **OQ-2**: ~~Does `libcuda.so` reject non-L4T kernels?~~ RESOLVED — wrong lib; L4T images
  carry correct userspace.
- **OQ-3**: Is `handler: runc` sufficient for CDI injection, or does containerd require
  `handler: nvidia` (i.e. `nvidia-container-runtime` binary)? **→ RESOLVED: requires
  `handler: nvidia` with nvidia-container-runtime configured for Tegra CSV mode.**
- **OQ-4**: What exact device nodes does nvgpu.ko create on boot? **→ RESOLVED: all `/dev/nvhost-*`
  present; `/dev/nvgpu/igpu0/` only has `power` at boot — `ctrl` etc. are not statically created.**

---

## Phase 1 — nvgpu-toolkit extension (REDESIGNED)

> **Tracking:** beads issue `home-ops-fwh`
>
> **Previous design (SUPERSEDED):** Extract L4T userspace libs (`nvidia-l4t-core`,
> `nvidia-l4t-cuda`) to host and inject via CDI. **This approach is wrong** — `libcuda.so`
> from `nvidia-l4t-cuda` is a discrete GPU shim and does not work on Tegra iGPU. See
> Phase 0 findings.

**Depends on:** Phase 0 complete (device nodes confirmed, architecture validated)

**Why the redesign:** Jetson Tegra uses `nvidia-container-runtime` with `libnvidia-container`
in CSV/plugin mode — not CDI. L4T container images carry their own userspace libs; the host
only needs to provide the runtime hook and CSV device lists.

### Architecture

```
containerd
└── handler: nvidia  →  nvidia-container-runtime (OCI hook)
                            └── libnvidia-container (Tegra/CSV mode)
                                    ├── reads CSV files → inject /dev/nvhost-* device nodes
                                    └── L4T image carries own libcuda, libnvrm_gpu, etc.
```

No host lib extraction needed. Workload containers must be L4T-based
(`nvcr.io/nvidia/l4t-base`, `dustynv/*`, etc.).

### What the extension must provide

| Component | Location on host | Notes |
|-----------|-----------------|-------|
| `nvidia-container-runtime` | `/usr/bin/nvidia-container-runtime` | OCI hook binary |
| `libnvidia-container.so` | `/usr/lib/` | Built `--enable-tegra` |
| `nvidia-container-cli` | `/usr/bin/` | Used by runtime |
| `l4t.csv` | `/etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv` | Device node list |
| containerd config | `/etc/cri/conf.d/20-customization.part` | `handler: nvidia` runtime class |

### l4t.csv — device node list (from Phase 0 findings)

```csv
# nvhost devices — confirmed present on nv1 (OE4T nvgpu + nvmap extensions)
/dev/nvhost-ctrl-gpu, dev, 0666
/dev/nvhost-gpu, dev, 0666
/dev/nvhost-as-gpu, dev, 0666
/dev/nvhost-ctxsw-gpu, dev, 0666
/dev/nvhost-dbg-gpu, dev, 0666
/dev/nvhost-nvsched-gpu, dev, 0666
/dev/nvhost-nvsched_ctrl_fifo-gpu, dev, 0666
/dev/nvhost-power-gpu, dev, 0666
/dev/nvhost-prof-ctx-gpu, dev, 0666
/dev/nvhost-prof-dev-gpu, dev, 0666
/dev/nvhost-prof-gpu, dev, 0666
/dev/nvhost-sched-gpu, dev, 0666
/dev/nvhost-tsg-gpu, dev, 0666
/dev/nvmap, dev, 0666
```

> **Note:** `/dev/nvhost-ctrl` (base, non-GPU) is NOT present on OE4T nvgpu driver.
> `/dev/nvgpu/igpu0/ctrl` is NOT statically created at boot — only `power` exists.
> The nvhost interface is the correct one for Tegra CUDA.

### containerd config addition

```toml
# Add to 20-customization.part alongside existing settings
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia]
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.cri.v1.runtime".containerd.runtimes.nvidia.options]
    BinaryName = "/usr/bin/nvidia-container-runtime"
```

### Source strategy: OE4T mirrors vs nv-tegra.nvidia.com

`OE4T/linux-nvgpu` and `OE4T/linux-nv-oot` are **pure mirrors** of `nv-tegra.nvidia.com` —
identical source, no OE4T-added patches. They exist for GitHub accessibility
(`nv-tegra.nvidia.com` has known connectivity issues). Continue using OE4T.

The `nvidia-container-toolkit` source lives at
[github.com/NVIDIA/nvidia-container-toolkit](https://github.com/NVIDIA/nvidia-container-toolkit)
with a dedicated `jetson` branch of `libnvidia-container` at
[github.com/NVIDIA/libnvidia-container](https://github.com/NVIDIA/libnvidia-container/tree/jetson).

### L4T version target: r36

| L4T | Kernel | CUDA | Orin NX | Status |
|-----|--------|------|---------|--------|
| r32 | 4.9 | 10.2–11.4 | ❌ | Xavier era |
| r34 | 5.10 | 11.4 | ⚠️ dev preview | Unsupported |
| r35 | 5.10 | 11.4 | ✅ first prod | EOL approaching |
| r36 | 5.15 | 12.2–12.6 | ✅ current | Supported to 2027 |

Target **r36** (JetPack 6.x): our nvgpu/nvmap already come from the `patches-r36.5` branch,
`dustynv/*` images actively target r36.x, and CUDA 12.x is required for modern model formats.

### libnvidia-container version target: v1.14.x (jetson branch)

JetPack 6 / L4T r36 bundles `nvidia-container-toolkit` **v1.14.x**. CSV mode (Tegra device
injection) was introduced in v1.10.0 and is stable in v1.14.x. The `jetson` branch of
`libnvidia-container` exists because the main branch requires `libnvidia-ml` which is absent
on Tegra; the `jetson` branch uses CSV pathname translation instead.

### Open questions

- **OQ-9**: Does `libnvidia-container` (`jetson` branch, v1.14.x) build successfully for
  `aarch64` in the Talos pkgs build environment? It has Go + C components.
- **OQ-10**: Does `nvidia-container-runtime` Tegra path require sysfs paths
  (`/sys/devices/platform/17000000.gpu/`) to be accessible inside the container?
- **OQ-11**: ~~Which `nvidia-container-toolkit` version is compatible with JetPack 6 / L4T r36?~~
  **RESOLVED — v1.14.x** (`libnvidia-container` jetson branch). Bundled with JetPack 6 / L4T r36.
- **OQ-12**: Renovate strategy for `nvidia-container-toolkit` version pinning.

---

## Phase 2 — nvgpu-toolkit extension wiring (siderolabs/extensions fork)

**Depends on:** Phase 1 packages built and published

Create `nvidia-gpu/nvgpu-toolkit/` in `mmalyska/siderolabs-extensions` fork on branch
`feat/jetson-nvgpu`.

### Directory structure

```
nvidia-gpu/nvgpu-toolkit/
├── pkg.yaml              # depends on nvgpu-driver + nvidia-container-toolkit pkgs
├── manifest.yaml.tmpl
├── vars.yaml
└── files/
    ├── l4t.csv           # device node list (from Phase 1)
    └── 20-nvidia-runtime.part  # containerd nvidia handler config
```

### manifest.yaml.tmpl

```yaml
version: v1alpha1
metadata:
  name: nvgpu-toolkit
  version: "{{ .VERSION }}"
  author: Michał Małyska
  description: |
    [extra] NVIDIA container runtime extension for Jetson Orin NX (Tegra/CSV mode).
    Installs nvidia-container-runtime and libnvidia-container (--enable-tegra) to enable
    GPU device node injection into containers. Requires nvgpu extension (nvgpu.ko + nvmap.ko).
    Target: L4T r36 / JetPack 6 / libnvidia-container v1.14.x jetson branch.
  compatibility:
    talos:
      version: ">= v1.4.0"
```

Open questions for this phase: see OQ-9, OQ-10, OQ-12 in Phase 1 above.

---

## Phase 3 — talconfig.yaml update for nv1

**Depends on:** Phase 2 extension published and tested

The nv1 node already uses `talosImageURL: ghcr.io/mmalyska/talos-nv1-installer`. Once the
`nvgpu-toolkit` extension is published, add it alongside the existing nvgpu extension and
add the nvidia runtime handler to the containerd config.

The `machineFiles` containerd config (`20-customization.part`) needs the nvidia runtime
handler appended (the extension's `20-nvidia-runtime.part` handles this automatically via
the extension mechanism):

```yaml
# nv1 in provision/talos/talconfig.yaml — after nvgpu-toolkit extension is deployed
# The talosImageURL installer image will include both nvgpu and nvgpu-toolkit extensions.
# No schematic changes needed — the installer image is rebuilt with the new extension baked in.
```

Then regenerate and apply:

```sh
task talos:generate
task talos:apply N=192.168.48.5
```

---

## Phase 4 — Kubernetes resources

**Depends on:** Phase 3 applied and node boots with nvgpu-toolkit extension active

### RuntimeClass

The RuntimeClass wires the Kubernetes pod spec to the `nvidia-container-runtime` handler in
containerd. Pods with `runtimeClassName: nvidia` are routed through `nvidia-container-runtime`,
which injects Tegra device nodes via CSV files before handing off to runc.

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia    # maps to containerd runtime handler configured by nvgpu-toolkit extension
scheduling:
  nodeSelector:
    kubernetes.io/hostname: nv1
```

Place in `cluster/apps/system/` or alongside the nvgpu-toolkit app manifests.

### Device plugin

The standard `nvidia/k8s-device-plugin` uses NVML (`/dev/nvidiactl`) and will find zero GPUs
on Tegra. Options:

1. **`nvidia/k8s-device-plugin` with `deviceListStrategy: cdi`** — if the nvgpu-toolkit
   extension also generates a CDI spec enumerating the Tegra GPU, this may work without NVML.
2. **Minimal custom device plugin** — watches `/dev/nvhost-ctrl-gpu` and advertises one
   `nvidia.com/gpu` resource when the device exists. Lower effort for a proof-of-concept.

### Workload image requirements

Workloads must use Jetson-native container images. Standard Docker Hub images contain the
discrete-GPU `libcuda.so` shim and will return `CUDA_ERROR_SYSTEM_NOT_READY (801)`:

| Workload | Standard image (broken on Jetson) | Jetson image |
|----------|-----------------------------------|--------------|
| Ollama | `ollama/ollama` | `dustynv/ollama:r36.x` |
| Whisper | `onerahmet/openai-whisper-asr-webservice` | `dustynv/whisper:r36.x` |
| Generic CUDA | `nvidia/cuda:12.x-base-ubuntu` | `dustynv/cuda:12.x-r36.x` |

Update `cluster/apps/home-automation/ollama/` and `cluster/apps/home-automation/whisper/`
image references accordingly.

---

## Phase 5 — Validation

1. `kubectl exec` into a running ollama/whisper pod and confirm CUDA device is visible:
   ```bash
   python3 -c "import torch; print(torch.cuda.is_available(), torch.cuda.device_count())"
   ```
2. Run a CUDA compute benchmark to confirm throughput (not just initialization):
   ```bash
   # Inside dustynv/cuda image
   /usr/local/cuda/samples/bin/aarch64/linux/release/bandwidthTest
   ```
3. Confirm `nvidia.com/gpu: 1` resource is schedulable:
   ```bash
   kubectl describe node nv1 | grep nvidia
   ```

---

## Open Questions Summary

| ID | Question | Status | Resolved in |
|----|----------|--------|-------------|
| OQ-1 | Do `nvidia-l4t-core` maintainer scripts perform runtime setup the libs depend on? | ✅ Moot — L4T images carry their own userspace libs; no host extraction needed | Phase 0 |
| OQ-2 | Does `libcuda.so` call platform-detection at `cuInit()` that rejects non-L4T kernels? | ✅ Yes — `libcuda.so` from `nvidia-l4t-cuda` is a dGPU shim, returns 801 on Tegra. L4T container images carry the correct Tegra libcuda.so | Phase 0 |
| OQ-3 | Is `handler: runc` sufficient for CDI injection, or is `handler: nvidia` required? | ✅ `handler: nvidia` required — nvidia-container-runtime in Tegra CSV mode is the correct mechanism | Phase 0 |
| OQ-4 | What exact device nodes does `nvgpu.ko` create on this hardware? | ✅ `/dev/nvgpu/igpu0/` (dir, only `power` at boot) + 13 flat `/dev/nvhost-*` devices + `/dev/nvmap` (via nvmap.ko) | Phase 0 |
| OQ-5 | Does `dpkg -x` preserve all symlinks? | ✅ Yes — confirmed, but moot (L4T images carry libs) | Phase 0 |
| OQ-6 | Exact package version URL for `t234` pool for L4T r36.4? | ✅ See Phase 0 Findings — timestamp table | Phase 0 |
| OQ-7 | Are `nvidia-l4t-core` + `nvidia-l4t-cuda` sufficient for host extraction? | ✅ Moot — no host lib extraction in redesigned approach | Phase 0 |
| OQ-8 | Renovate datasource strategy for L4T package versioning? | ✅ Moot — no L4T packages pinned on host | Phase 0 |
| OQ-9 | Does `libnvidia-container` build for `aarch64` in Talos pkgs build env? | Open | Phase 1 |
| OQ-10 | Does `nvidia-container-runtime` Tegra path require sysfs paths inside container? | Open | Phase 1 |
| OQ-11 | Which `nvidia-container-toolkit` version is compatible with JetPack 6 / L4T r36.4? | ✅ **v1.14.x**, `libnvidia-container` jetson branch — bundled with JetPack 6 / L4T r36 | Phase 1 |
| OQ-12 | Renovate strategy for `nvidia-container-toolkit` version pinning? | Open | Phase 2 |
| OQ-13 | Can `nvmap.ko` be built as a Talos extension? | ✅ Yes — deployed in `ghcr.io/mmalyska/talos-nv1-installer`, `/dev/nvmap` confirmed present | Phase 0 |

---

## L4T Package Reference

> **Note (post-Phase 0 redesign):** L4T packages are **not extracted to the host** in the
> redesigned approach. They live inside L4T-based container images (`dustynv/*`,
> `nvcr.io/nvidia/l4t-*`). This section is kept as reference for selecting appropriate
> workload images.

NVIDIA L4T packages ship from `repo.download.nvidia.com/jetson/t234/` for the Orin platform
(t234 SoC). URL pattern: `{repo}/pool/main/n/{pkg}/{pkg}_{version}_arm64.deb`

Available r36.4.x versions (use index at
`https://repo.download.nvidia.com/jetson/t234/dists/r36.4/main/binary-arm64/Packages.gz`):

| Version | Timestamp | JetPack |
|---------|-----------|---------|
| `36.4.0` | `20240912212859` | JetPack 6.0 |
| `36.4.3` | `20250107174145` | JetPack 6.1 |
| `36.4.4` | `20250616085344` | JetPack 6.1+ |
| `36.4.7` | `20250918154033` | JetPack 6.x |

### Key packages (for workload image selection)

| Package | What it provides | In dustynv images? |
|---------|-----------------|-------------------|
| `nvidia-l4t-core` | `libnvrm_gpu.so`, `libnvrm_mem.so`, Tegra platform libs | Yes |
| `nvidia-l4t-cuda` | `libcuda.so.1.1` (Tegra ioctl ABI), `libcudart.so` | Yes |
| `nvidia-l4t-multimedia` | NVMPI, hardware video encode/decode | Yes (media images) |
| `nvidia-l4t-tensorrt` | TensorRT runtime (`libnvinfer.so`) | Yes (ML images) |
| `nvidia-l4t-cudnn` | cuDNN for Tegra | Yes (ML images) |
| `nvidia-l4t-3d-core` | OpenGL/Vulkan ICD — headless server: skip | No |

---

## Reference

### Kernel driver sources
- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — `patches-r36.5` branch (**pure mirror** of `nv-tegra.nvidia.com/linux-nvgpu.git`)
- [OE4T/linux-nv-oot](https://github.com/OE4T/linux-nv-oot) — `patches-r36.5` branch (pure mirror; nvmap lives in `drivers/video/tegra/nvmap/`)
- [nv-tegra.nvidia.com](https://nv-tegra.nvidia.com/) — official NVIDIA git server (same content, less reliable)

### Container runtime
- [NVIDIA/libnvidia-container — jetson branch](https://github.com/NVIDIA/libnvidia-container/tree/jetson) — Tegra CSV plugin mode; target v1.14.x
- [libnvidia-container mount plugin design](https://github.com/NVIDIA/libnvidia-container/blob/jetson/design/mount_plugins.md)
- [NVIDIA/nvidia-container-toolkit](https://github.com/NVIDIA/nvidia-container-toolkit) — runtime wrapper; v1.14.x for L4T r36
- [NVIDIA Container Runtime on Jetson](https://nvidia.github.io/container-wiki/toolkit/jetson.html)
- [siderolabs/extensions — nvidia-container-toolkit](https://github.com/siderolabs/extensions/tree/main/nvidia-gpu/nvidia-container-toolkit) — reference for discrete GPU extension pattern

### Workload containers
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers) — L4T r36 images for ollama, whisper, PyTorch
- [NVIDIA L4T apt repo](https://repo.download.nvidia.com/jetson/) — `t234/` for Orin (r36.x packages)
- [CUDA for Tegra appnote](https://docs.nvidia.com/cuda/cuda-for-tegra-appnote/)

### Plans
- Jetson-gpu plan (archived — Phases 1–4 complete): [jetson-gpu.md](./archive/jetson-gpu.md)
- nvgpu upgrade/maintenance guide: [nvgpu-upgrade-guide.md](./nvgpu-upgrade-guide.md)
