# Jetson Orin NX — Tegra CUDA Talos Extension Plan

## Prerequisite

> **Do not start this plan until the [jetson-gpu plan](./jetson-gpu.md) is complete.**
> Specifically, Phase 1–4 of that plan must be done and `nvgpu.ko` must load successfully on `nv1`
> with Tegra device nodes (`/dev/nvgpu`, `/dev/nvhost-*`, `/dev/nvmap`) appearing at boot.
>
> This plan picks up from that point and adds the CUDA userspace layer.

---

## Goal

Build a Talos system extension (`nvgpu-toolkit`) that installs NVIDIA L4T CUDA userspace
libraries onto the `nv1` host and configures the NVIDIA container runtime so that containers
can make CUDA API calls without bundling any CUDA libraries themselves.

The end state: a pod with `runtimeClassName: nvidia` and resource request `nvidia.com/gpu: 1`
can run standard CUDA workloads (ollama, whisper, inference frameworks) using Jetson-native
container images.

---

## Why This Is Needed

The [jetson-gpu plan](./jetson-gpu.md) loads `nvgpu.ko` and exposes Tegra GPU device nodes to
Kubernetes. That is necessary but not sufficient for CUDA. CUDA requires a Tegra-specific
`libcuda.so` that speaks the nvgpu ioctl ABI (`/dev/nvhost-*` + unified memory model). This
library is architecturally incompatible with the standard discrete-GPU `libcuda.so`:

| | Discrete GPU | Jetson Tegra |
|---|---|---|
| Kernel driver | `nvidia.ko` | `nvgpu.ko` |
| Device nodes | `/dev/nvidia0`, `/dev/nvidiactl` | `/dev/nvgpu`, `/dev/nvhost-*`, `/dev/nvmap` |
| ioctl magic | `'F'` (base 200) | `'G'`, `'A'`, `'H'`, `'T'`, `'D'` |
| `libcuda.so` source | CUDA Toolkit / `libnvidia-compute` | JetPack `nvidia-l4t-cuda` |

Standard `nvidia/cuda:*` container images contain the discrete-GPU `libcuda.so` and will not
work on Jetson regardless of device node injection.

The approach here mirrors how the existing `nvidia-container-toolkit` Siderolabs extension
works for discrete GPUs: install CUDA libs onto the Talos host via an extension, then use
CDI (Container Device Interface) to bind-mount those libs into containers at runtime.

---

## Architecture Overview

```
nv1 node (Talos Linux)
├── nvgpu extension (from jetson-gpu plan)
│   └── nvgpu.ko loaded → /dev/nvgpu, /dev/nvhost-*, /dev/nvmap created
│
├── nvgpu-cuda-pkg (new — siderolabs/pkgs fork)
│   └── extracts nvidia-l4t-core + nvidia-l4t-cuda .deb packages
│       → /usr/lib/aarch64-linux-gnu/tegra/libcuda.so + dependencies
│
└── nvgpu-toolkit extension (new — siderolabs/extensions fork)
    ├── tegra-cdi-gen service
    │   └── runs nvidia-ctk cdi generate --mode=csv at boot
    │       → /run/cdi/nvidia.yaml (CDI spec consumed by containerd)
    ├── CSV files enumerating Tegra device nodes + lib paths
    ├── udev rules for /dev/nvgpu device node creation
    └── containerd config: registers nvidia-container-runtime handler

Container (e.g. ollama/jetson):
└── runtimeClassName: nvidia
    → containerd injects /dev/nvhost-* + /usr/lib/aarch64-linux-gnu/tegra/ bind-mounts
    → libcuda.so present → cudaGetDeviceCount() > 0 → CUDA works
```

No CUDA libraries need to be bundled inside workload container images.

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
   curl -LO https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-core/nvidia-l4t-core_36.4.0-20240910085053_arm64.deb
   curl -LO https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-cuda/nvidia-l4t-cuda_36.4.0-20240910085053_arm64.deb

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
           - path: /dev/nvgpu
           - path: /dev/nvhost-ctrl
           - path: /dev/nvhost-ctrl-gpu
           - path: /dev/nvhost-gpu
           - path: /dev/nvhost-as-gpu
           - path: /dev/nvhost-prof-gpu
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
   - Segfault / illegal instruction → wrong libcuda.so ABI (wrong L4T version)

### Open questions to answer in Phase 0

- **OQ-1**: Do `nvidia-l4t-core` maintainer scripts (bypassed by `dpkg -x`) perform any
  runtime setup that the libs depend on? (symlink creation, ldconfig, platform detection)
- **OQ-2**: Does `libcuda.so` from L4T r36.x call any platform-detection API at `cuInit()`
  that rejects non-L4T kernels? (e.g. reads `/proc/device-tree/compatible` for Tegra SOC ID)
- **OQ-3**: Is `handler: runc` sufficient for CDI injection, or does containerd require
  `handler: nvidia` (i.e. `nvidia-container-runtime` binary)?
- **OQ-4**: What exact device nodes does nvgpu.ko create on boot? Are all of `/dev/nvhost-*`
  present, or only a subset depending on what the hardware reports?

---

## Phase 1 — nvgpu-cuda-pkg (siderolabs/pkgs fork)

**Depends on:** Phase 0 successful (lib paths confirmed working)

Create a new package in `mmalyska/siderolabs-pkgs` fork on branch `feat/jetson-nvgpu`
(alongside the existing `nvgpu-driver` package).

### Directory structure

```
nvgpu-cuda-pkg/
├── pkg.yaml
└── files/
    └── tegra-ld.conf    # ldconfig config for tegra lib path
```

### pkg.yaml sketch

```yaml
name: nvgpu-cuda-pkg
variant: scratch
dependencies:
  - image: ghcr.io/siderolabs/fhs

steps:
  - sources:
      - url: https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-core/nvidia-l4t-core_{{ .L4T_VERSION }}_arm64.deb
        destination: nvidia-l4t-core.deb
        sha256: "{{ .L4T_CORE_SHA256 }}"
      - url: https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-cuda/nvidia-l4t-cuda_{{ .L4T_VERSION }}_arm64.deb
        destination: nvidia-l4t-cuda.deb
        sha256: "{{ .L4T_CUDA_SHA256 }}"
      - url: https://repo.download.nvidia.com/jetson/t234/pool/main/n/nvidia-l4t-multimedia/nvidia-l4t-multimedia_{{ .L4T_VERSION }}_arm64.deb
        destination: nvidia-l4t-multimedia.deb
        sha256: "{{ .L4T_MULTIMEDIA_SHA256 }}"
    prepare:
      - dpkg -x nvidia-l4t-core.deb /rootfs
      - dpkg -x nvidia-l4t-cuda.deb /rootfs
      - dpkg -x nvidia-l4t-multimedia.deb /rootfs
    install:
      - mkdir -p /rootfs/etc/ld.so.conf.d
      - cp /pkg/files/tegra-ld.conf /rootfs/etc/ld.so.conf.d/nvidia-tegra.conf
      - ldconfig -r /rootfs

finalize:
  - from: /rootfs
    to: /rootfs
```

### Pkgfile additions

```makefile
# renovate: datasource=custom.l4t depName=nvidia-l4t-cuda
L4T_VERSION ?= 36.4.0-20240910085053
L4T_CORE_SHA256 ?= <sha256>
L4T_CUDA_SHA256 ?= <sha256>
L4T_MULTIMEDIA_SHA256 ?= <sha256>
```

### Open questions

- **OQ-5**: Does `dpkg -x` produce a clean file tree, or do the packages have post-install
  scripts that create essential symlinks (e.g. `libcuda.so → libcuda.so.1.1`)? Verify symlinks
  are present after extraction.
- **OQ-6**: What is the exact package version URL for the `t234` pool for r36.4? Confirm the
  right platform string (some packages are in `/jetson/common/`, some in `/jetson/t234/`).
- **OQ-7**: Is `nvidia-l4t-multimedia` fully self-contained after `dpkg -x`, or does it pull
  in transitive runtime deps (e.g. `nvidia-l4t-camera`, `nvidia-l4t-gbm`) that must also be
  extracted? Verify that NVMPI symbols resolve inside a container with only these three packages.
- **OQ-8**: Renovate datasource strategy for L4T packages — L4T uses a non-standard versioning
  scheme (`36.4.0-20240910085053`). A custom datasource or regex manager will be needed.

---

## Phase 2 — nvgpu-toolkit extension (siderolabs/extensions fork)

**Depends on:** Phase 1 published and Phase 0 CDI approach confirmed

Create `nvidia-gpu/nvgpu-toolkit/` in `mmalyska/siderolabs-extensions` fork on branch
`feat/jetson-nvgpu`.

### Directory structure

```
nvidia-gpu/nvgpu-toolkit/
├── pkg.yaml
├── manifest.yaml.tmpl
├── vars.yaml
├── tegra-cdi-gen.yaml         # Talos guest service: CDI spec generation
└── files/
    ├── cuda.csv               # nvidia-ctk CSV: CUDA lib paths
    ├── l4t.csv                # nvidia-ctk CSV: Tegra device nodes
    └── 15-nvgpu-device.rules  # udev: trigger on nvgpu module load
```

### tegra-cdi-gen service

Replaces `nvidia-persistenced` + `nvidia-cdi-gen` from the discrete GPU extension.
Tegra does not use persistenced.

```yaml
name: tegra-cdi-gen
container:
  entrypoint: /usr/local/bin/nvidia-ctk
  args:
    - cdi
    - generate
    - --mode=csv
    - --csv-file-sources=/etc/nvidia-container-runtime/host-files-for-container.d/cuda.csv,/etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv
    - --library-search-path=/usr/lib/aarch64-linux-gnu/tegra
    - --output=/run/cdi/nvidia.yaml
  mounts:
    - source: /dev
      destination: /dev
      options: [rshared, rbind, ro]
    - source: /usr/lib/aarch64-linux-gnu/tegra
      destination: /usr/lib/aarch64-linux-gnu/tegra
      options: [bind, ro]
    - source: /run/cdi
      destination: /run/cdi
      options: [bind, rw]
  depends:
    - path: /dev/nvgpu      # waits for nvgpu.ko to load device nodes
  restart: untilSuccess
```

### udev rules

```udev
# 15-nvgpu-device.rules
# Create /dev/nvgpu and nvhost devices when nvgpu module loads
ACTION=="add", SUBSYSTEM=="module", KERNEL=="nvgpu", \
  RUN+="/sbin/modprobe -b nvgpu"
```

### CSV files (Phase 0 investigation will finalize these)

`l4t.csv` enumerates Tegra device nodes:
```
/dev/nvgpu, dev, 0666
/dev/nvhost-ctrl, dev, 0666
/dev/nvhost-ctrl-gpu, dev, 0666
/dev/nvhost-gpu, dev, 0666
/dev/nvhost-as-gpu, dev, 0666
/dev/nvhost-prof-gpu, dev, 0666
/dev/nvhost-vic, dev, 0666
/dev/nvhost-nvdec, dev, 0666
/dev/nvhost-nvenc, dev, 0666
/dev/nvmap, dev, 0666
```

`cuda.csv` enumerates CUDA lib paths:
```
/usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1.1, lib, 0644
/usr/lib/aarch64-linux-gnu/tegra/libcudart.so, lib, 0644
```

(Exact entries depend on Phase 0 findings.)

### manifest.yaml.tmpl

```yaml
version: v1alpha1
metadata:
  name: nvgpu-toolkit
  version: "{{ .VERSION }}"
  author: Michał Małyska
  description: |
    [extra] Tegra CUDA userspace extension for NVIDIA Jetson Orin NX.
    Installs L4T CUDA libraries and configures CDI for container GPU access.
    Requires nvgpu extension (nvgpu.ko kernel module).
  compatibility:
    talos:
      version: ">= v1.4.0"
```

### Open questions

- **OQ-9**: Does `nvidia-ctk cdi generate --mode=csv` produce a valid CDI spec from Tegra CSV
  files on a non-L4T host? Or does it require a running L4T environment to probe? May need to
  write the CDI spec statically instead.
- **OQ-10**: Does the CDI spec need a `containerEdits.ldcacheUpdateHints` entry for
  `/usr/lib/aarch64-linux-gnu/tegra/` so the dynamic linker inside the container finds
  `libcuda.so`?
- **OQ-11**: Is there a timing issue between nvgpu.ko loading, device nodes appearing, and the
  CDI generation service starting? Talos guest service `depends.path` watches for file
  existence — confirm `/dev/nvgpu` is the right sentinel.

---

## Phase 3 — talconfig.yaml update for nv1

**Depends on:** Phase 2 extension published and tested

```yaml
# nv1 in provision/talos/talconfig.yaml
schematic:
  customization:
    extraKernelArgs:
      - -selinux
      - console=tty0
      - console=ttyS0,115200
      - talos.auditd.disabled=1
    systemExtensions:
      officialExtensions: []       # remove nvidia-open-gpu-kernel-modules-lts
                                   # remove nvidia-container-toolkit-lts
      additionalExtensions:
        - image: ghcr.io/mmalyska/nvgpu@sha256:<digest>
        - image: ghcr.io/mmalyska/nvgpu-toolkit@sha256:<digest>
patches:
  - |-
    machine:
      kernel:
        modules:
          - name: nvgpu
      sysctls:
        net.core.bpf_jit_harden: "1"
      files:
        - path: /etc/cri/conf.d/20-enable-cdi.toml
          op: create
          content: |
            [plugins."io.containerd.cri.v1.runtime"]
              enable_cdi = true
              cdi_spec_dirs = ["/run/cdi"]
```

Then regenerate and apply:
```sh
task talos:generate
task talos:apply NODE=192.168.48.5
```

---

## Phase 4 — Kubernetes resources

**Depends on:** Phase 3 applied and node boots with nvgpu.ko + CDI spec generated

### RuntimeClass

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: runc    # or nvidia — determined by Phase 0 OQ-3
scheduling:
  nodeSelector:
    feature.node.kubernetes.io/gpu: "true"
```

Place in `cluster/apps/system/` or a shared infra app.

### Device plugin

The standard `nvidia/k8s-device-plugin` uses NVML and will find zero GPUs on Tegra.
A CDI-aware device plugin is required to advertise `nvidia.com/gpu` resources.

Options (to be selected after Phase 0):
1. `nvidia/k8s-device-plugin` with `deviceListStrategy: cdi` — if the CDI spec correctly
   enumerates the Tegra GPU as a device, this may work without NVML.
2. A minimal custom device plugin that watches `/dev/nvgpu` and advertises one
   `nvidia.com/gpu` resource when the device exists.

### Workload image requirements

Workloads must use Jetson-native container images, not standard Docker Hub images:

| Workload | Standard image (broken) | Jetson image |
|----------|-------------------------|--------------|
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

| ID | Question | Resolved in |
|----|----------|-------------|
| OQ-1 | Do `nvidia-l4t-core` maintainer scripts perform runtime setup the libs depend on? | Phase 0 |
| OQ-2 | Does `libcuda.so` call platform-detection at `cuInit()` that rejects non-L4T kernels? | Phase 0 |
| OQ-3 | Is `handler: runc` sufficient for CDI injection, or is `handler: nvidia` required? | Phase 0 |
| OQ-4 | What exact device nodes does `nvgpu.ko` create on this hardware? | Phase 0 |
| OQ-5 | Does `dpkg -x` preserve all symlinks, or do post-install scripts create essential ones? | Phase 1 |
| OQ-6 | Exact package version URL for `t234` pool for L4T r36.4? | Phase 1 |
| OQ-7 | Are `nvidia-l4t-core` + `nvidia-l4t-cuda` sufficient, or are transitive deps needed? | Phase 1 |
| OQ-8 | Renovate datasource strategy for L4T package versioning scheme? | Phase 1 |
| OQ-9 | Does `nvidia-ctk cdi generate --mode=csv` work on non-L4T host, or must CDI spec be static? | Phase 2 |
| OQ-10 | Does the CDI spec need `ldcacheUpdateHints` for Tegra lib path? | Phase 2 |
| OQ-11 | Is `/dev/nvgpu` the correct sentinel for the `tegra-cdi-gen` service dependency? | Phase 2 |
| OQ-12 | Which device plugin approach works with Tegra CDI — `k8s-device-plugin` with CDI mode, or custom? | Phase 4 |

---

## L4T Package Reference

NVIDIA L4T (Linux for Tegra) packages ship from
`repo.download.nvidia.com/jetson/t234/` for the Orin platform (t234 SoC).
All packages follow the versioning scheme `<major>.<minor>.<patch>-<yyyymmddhhmmss>` (e.g. `36.4.0-20240910085053`).

### Core packages (always required)

| Package | Size (approx.) | What it provides |
|---------|---------------|-----------------|
| `nvidia-l4t-core` | ~10 MB | Foundational Tegra runtime: `libnvrm_gpu.so`, `libnvrm_mem.so`, `libnvos.so`, `libnvddk_*.so`, platform detection libs, chip config files, firmware blobs for the Tegra memory controller. Required by every other L4T package. |
| `nvidia-l4t-cuda` | ~23 MB | Jetson-specific CUDA userspace: `libcuda.so.1.1` (Tegra ioctl ABI), `libcudart.so`, `libcublas*.so`, `libcurand.so`, basic CUDA runtime and math libraries. This is the package that makes `cuInit()` work on Tegra. |

### Multimedia / video hardware (needed by Jellyfin, Frigate, hardware transcoding)

| Package | Size (approx.) | What it provides |
|---------|---------------|-----------------|
| `nvidia-l4t-multimedia` | ~16 MB | NVMPI (NVIDIA Multimedia Processing Interface): `libnvmpi.so`, `libnvbufsurface.so`, `libnvbufsurftransform.so`. Enables `h264_nvmpi` / `hevc_nvmpi` / `av1_nvmpi` FFmpeg codecs and V4L2 video engines (`/dev/nvhost-nvdec`, `/dev/nvhost-nvenc`, `/dev/nvhost-vic`). Required for hardware-accelerated video decode/encode. |
| `nvidia-l4t-multimedia-utils` | ~2 MB | Helper utilities: `nvgstcapture`, `nvgstplayer`, test apps. Not needed in production extensions — development/debug only. |
| `nvidia-l4t-camera` | ~5 MB | ISP / camera pipeline: `libargus.so`, `libnvcamerasrc.so`. Only needed if a container uses Jetson camera input (ISP pipeline). Not required for GPU compute or video transcoding. |

### Graphics / display (not needed in headless server use)

| Package | Size (approx.) | What it provides |
|---------|---------------|-----------------|
| `nvidia-l4t-3d-core` | ~40 MB | OpenGL / OpenGL ES / Vulkan ICD: `libGL.so`, `libEGL.so`, `libGLESv2.so`, `libvulkan.so` + Tegra GPU Vulkan driver. Needed only for 3D rendering workloads. Headless server: skip. |
| `nvidia-l4t-wayland` | ~1 MB | Wayland EGL platform. Display compositor only. Skip entirely for server use. |
| `nvidia-l4t-gbm` | ~1 MB | Generic Buffer Management for display. Required by `nvidia-l4t-3d-core` but not CUDA. Skip. |
| `nvidia-l4t-x11` | ~1 MB | X11 Tegra glue. Skip. |

### Inference accelerators

| Package | Size (approx.) | What it provides |
|---------|---------------|-----------------|
| `nvidia-l4t-tensorrt` | ~200 MB | TensorRT runtime + libraries: `libnvinfer.so`, `libnvinfer_plugin.so`, `libnvparsers.so`. Used by Frigate (`stable-tensorrt-jp6` image already bundles this internally — not needed on host unless sharing via CDI). |
| `nvidia-l4t-cudnn` | ~80 MB | cuDNN for Tegra: `libcudnn.so`. Needed for DNN-based inference (YOLO, Whisper, etc.) on GPU. Frigate bundles this too. |
| `nvidia-l4t-dla-compiler` | ~30 MB | DLA (Deep Learning Accelerator) offline compiler. Only needed to compile DLA-targeted models. Runtime inference uses cuDNN. |

### This extension's package selection

The `nvgpu-toolkit` extension includes:

| Package | Included | Reason |
|---------|---------|--------|
| `nvidia-l4t-core` | Yes | Required foundation |
| `nvidia-l4t-cuda` | Yes | CUDA compute (`cuInit`, `libcuda.so`) |
| `nvidia-l4t-multimedia` | Yes | Hardware video encode/decode for Jellyfin/Frigate |
| `nvidia-l4t-tensorrt` | No | Bundled inside Frigate image; too large for host extension |
| `nvidia-l4t-cudnn` | No | Bundled inside Frigate/Whisper images |
| `nvidia-l4t-3d-core` | No | Headless server — no display needed |
| `nvidia-l4t-camera` | No | No camera pipeline on nv1 |

If TensorRT or cuDNN are needed on the host in the future, add them to the pkg.yaml
sources block and extract with `dpkg -x`. They follow the same pattern as the three
packages already included.

---

## Reference

- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — `patches-r36.5` branch
- [siderolabs/extensions — nvidia-container-toolkit](https://github.com/siderolabs/extensions/tree/main/nvidia-gpu/nvidia-container-toolkit)
- [NVIDIA Container Runtime on Jetson](https://nvidia.github.io/container-wiki/toolkit/jetson.html)
- [dusty-nv/jetson-containers](https://github.com/dusty-nv/jetson-containers)
- [anduril/jetpack-nixos](https://github.com/anduril/jetpack-nixos) — reference for L4T package extraction
- [NVIDIA L4T apt repo](https://repo.download.nvidia.com/jetson/) — `t234/` for Orin
- [CUDA for Tegra appnote](https://docs.nvidia.com/cuda/cuda-for-tegra-appnote/)
- [CDI spec v0.5.0](https://github.com/cncf-tags/container-device-interface/blob/main/SPEC.md)
- Jetson-gpu plan: [jetson-gpu.md](./jetson-gpu.md)
