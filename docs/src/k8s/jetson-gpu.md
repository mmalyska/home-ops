# Jetson Orin NX GPU — Talos Extension Plan

## Goal

Enable NVIDIA GPU compute (CUDA) on `nv1` — a Jetson Orin NX 16GB worker node in the Talos
cluster — so that GPU-accelerated workloads (ollama, whisper, etc.) can be scheduled there.

---

## Architecture Background (why this is non-trivial)

Jetson Orin NX has an **integrated Tegra/Ampere SoC GPU**, not a discrete PCIe device.

| | Discrete GPU (desktop/server) | Jetson Orin NX |
|---|---|---|
| Bus | PCIe endpoint | Tegra platform bus |
| Driver | `nvidia-open-gpu-kernel-modules` | `nvgpu` |
| PCIe presence | Full GPU endpoint (`10de:xxxx`) | Only PCIe root port controllers (`10de:229c`, driver: `pcieport`) |
| Siderolabs extension | `siderolabs/nvidia-open-gpu-kernel-modules-lts` ❌ | None exists yet |

**The Siderolabs `nvidia-open-gpu-kernel-modules-lts` extension will never work on Jetson.**
The companion service `ext-nvidia-persistenced` waits indefinitely for
`/sys/bus/pci/drivers/nvidia` which is never populated because there is no PCIe GPU endpoint.

The correct driver is **[OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu)** (branch
`patches-r36.5`), a community-maintained Tegra GPU driver targeting non-L4T kernels.

---

## Current State of `nv1` in talconfig.yaml

```yaml
- hostname: nv1
  ipAddress: 192.168.48.5
  installDisk: /dev/nvme0n1
  controlPlane: false
  schematic:
    customization:
      extraKernelArgs:
        - -selinux
        - console=tty0
        - console=ttyS0,115200
        - talos.auditd.disabled=1
      systemExtensions:
        officialExtensions:
          - siderolabs/nvidia-container-toolkit-lts   # ← remove once custom ext is ready
          - siderolabs/nvidia-open-gpu-kernel-modules-lts  # ← remove, wrong for Jetson
  networkInterfaces:
    - interface: enP8p1s0
      addresses:
        - 192.168.48.5/22
      ...
  nodeTaints:
    nv: NoSchedule
```

Both NVIDIA extensions need to be **removed** and replaced with a custom `nvgpu` extension once
it is built.

---

## Action Plan

### Phase 1 — Compilation viability test (IN PROGRESS)

Kubernetes Job `cluster/.tools/nvgpu-build-test.yaml` runs on `nv1` and compiles
`OE4T/linux-nvgpu` (branch `patches-r36.5`) against vanilla kernel 6.18.18 source to find
all API incompatibilities.

**Kernel API patches found so far:**

| File | Issue | Kernel version that changed | Fix |
|------|-------|-----------------------------|-----|
| `os/linux/*.c` + others | `vma->vm_flags \|=` is read-only | 6.3 | Replace with `vm_flags_set(vma, ...)` across entire driver tree |
| `os/linux/debug_gr.c` + others | `vma->vm_flags &= ~` is read-only | 6.3 | Replace with `vm_flags_clear(vma, ...)` across entire driver tree |
| `os/linux/ioctl.c` | `class_create(THIS_MODULE, name)` → `class_create(name)` | 6.4 | Remove `THIS_MODULE` arg |
| `os/linux/ioctl.c` | `devnode` callback missing `const` on `struct device *` | 6.2 | Add `const` to all `nvgpu_*devnode*` function definitions |
| `os/linux/ioctl_clk_arb.c` (+ others) | `struct fd` has no member `.file` | 6.9 | Replace `fd.file` with `fd_file(fd)` accessor |
| `os/linux/dmabuf_priv.c` (+ others) | `linux/dma-buf-map.h` no longer exists | 5.18 | Rename include to `linux/iosys-map.h`; rename `struct dma_buf_map` → `struct iosys_map` and all `dma_buf_map_*` / `DMA_BUF_MAP_*` symbols |
| `os/linux/periodic_timer.c` (+ others) | `hrtimer_init` removed | 6.15 | Replace two-statement pattern `hrtimer_init(x, clock, mode); x.function = cb;` with single `hrtimer_setup(x, cb, clock, mode);` |
| `os/linux/nvgpu_ivm.c`, `common/cbc/contig_pool.c` (+ others) | `soc/tegra/virt/hv-ivc.h` is L4T-only (Tegra hypervisor IVC) | N/A | Find all `.c` files including `hv-ivc.h`, replace with empty stubs — IVM/IVC unused on bare-metal |
| `os/linux/module.c` | `platform_driver.remove` changed from `int(*)(struct platform_device*)` to `void(*)()` | 6.11 | Change `gk20a_remove_wrapper` return type `int` → `void`; replace `return 0;` with `return;` using `sed -z` |

Continue running the Job until **BUILD EXIT CODE: 0** is achieved.

> **Cleanup:** Once BUILD EXIT CODE: 0 is reached, delete the build cache from nv1:
> ```sh
> talosctl -n 192.168.48.5 shell  # then: rm -rf /var/nvgpu-build-cache
> ```
> Also delete the Job: `kubectl delete -f cluster/.tools/nvgpu-build-test.yaml`

### Phase 2 — Collect all patches as a proper diff

Once the build passes:

1. Collect all `sed` patches applied by the Job into a proper unified diff
   (`git diff` from inside the container, or reconstruct from the sed commands)
2. Host the patch file at `provision/talos/patches/nvgpu-kernel-compat.patch` or similar
3. The patch set becomes the input for the Talos extension build

### Phase 3 — Build a Talos system extension

Talos extensions package kernel modules as OCI images following the
[siderolabs/extensions](https://github.com/siderolabs/extensions) pattern.

The extension needs:
- A `pkg.yaml` that builds the `.ko` from source (or packages pre-built `.ko`)
- Extension manifest: `manifest.yaml` declaring `nvgpu.ko` and any dependencies
- The compiled `nvgpu.ko` placed at `/lib/modules/<talos-kver>/extras/nvgpu/nvgpu.ko`

**Build strategy options (choose one):**

| Option | Description | Effort |
|--------|-------------|--------|
| A | Fork siderolabs/extensions, add `nvgpu/` alongside `nvidia-gpu/` | Medium |
| B | Build standalone OCI image using `bldr` / Talos toolchain | Medium |
| C | Simple Docker image that just copies the `.ko` and runs `insmod` via a DaemonSet | Low (hacky) |

Option A is the correct long-term approach. Option C is the fastest for a proof-of-concept.

For Option A, the extension directory structure:
```
nvidia-gpu/nvgpu/
├── pkg.yaml          # build spec — compile OE4T/linux-nvgpu against talos kernel pkg
└── manifest.yaml     # extension manifest
```

The `pkg.yaml` needs to use the Talos kernel build image matching the running version:
```yaml
# pkg.yaml (sketch)
name: nvgpu
variant: scratch
dependencies:
  - image: ghcr.io/siderolabs/kernel:v1.12.6   # must match running Talos version
steps:
  - sources:
      - url: https://github.com/OE4T/linux-nvgpu/archive/refs/heads/patches-r36.5.tar.gz
        destination: nvgpu.tar.gz
    prepare:
      - tar -xf nvgpu.tar.gz
    build:
      - make -C linux-nvgpu-patches-r36.5/drivers/gpu/nvgpu \
          ARCH=arm64 \
          KERNEL_SRC=/usr/src/linux-headers-<ver> \
          M=$(pwd)/linux-nvgpu-patches-r36.5/drivers/gpu/nvgpu \
          modules
    install:
      - mkdir -p /rootfs/lib/modules/<ver>/extras/nvgpu
      - cp nvgpu.ko /rootfs/lib/modules/<ver>/extras/nvgpu/
```

### Phase 4 — Update talconfig.yaml

Once the extension OCI image is published:

```yaml
# nv1 node in talconfig.yaml
schematic:
  customization:
    extraKernelArgs:
      - -selinux
      - console=tty0
      - console=ttyS0,115200
      - talos.auditd.disabled=1
    systemExtensions:
      officialExtensions: []      # remove nvidia-open-gpu-kernel-modules-lts
      additionalExtensions:
        - image: ghcr.io/<your-org>/nvgpu-extension:v<tag>
patches:
  - |-
    machine:
      kernel:
        modules:
          - name: nvgpu          # explicit module load (not autoloaded by udev on Talos)
      sysctls:
        net.core.bpf_jit_harden: "1"   # required by nvidia-container-toolkit
```

Then regenerate and apply:
```sh
task talos:generate
task talos:apply NODE=192.168.48.5
```

### Phase 5 — NVIDIA container toolkit

Once `nvgpu.ko` loads, the container toolkit needs to be set up for container GPU access.

**Tegra device node differences (gap vs standard NVIDIA flow):**

Standard discrete GPU exposes `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`.
Jetson Tegra exposes a different set of device nodes:

| Device | Purpose |
|--------|---------|
| `/dev/nvgpu` | GPU control |
| `/dev/nvhost-ctrl` | Host1x sync point control |
| `/dev/nvhost-gpu` | GPU channel submission |
| `/dev/nvhost-vic` | Video image compositor |
| `/dev/nvhost-nvdec` | Hardware video decoder |
| `/dev/nvhost-nvenc` | Hardware video encoder |
| `/dev/nvmap` | NVIDIA memory allocator |

**Container toolkit:**
`siderolabs/nvidia-container-toolkit-lts` handles the userspace side (CDI device injection).
However it is configured for discrete GPUs. For Jetson:
- The toolkit must be configured to use CDI spec for Tegra devices
- `/etc/cdi/nvidia.yaml` must enumerate the Tegra device nodes above, not `/dev/nvidia*`
- The Tegra CDI spec generation requires `nvidia-ctk cdi generate --mode=nvml` is not applicable;
  instead the Tegra paths must be specified manually or via `--mode=csv` with a mounted libs list.

**Device plugin (gap):**
Standard `k8s-device-plugin` (`nvidia/k8s-device-plugin`) uses NVML (`libnvidia-ml.so`) to
enumerate GPUs and advertises `nvidia.com/gpu` resources. On Jetson:
- NVML enumerates via `/dev/nvidiactl` + PCIe GPU endpoint — **neither exists on Tegra**
- The plugin's default `deviceListStrategy: envvar` injects `NVIDIA_VISIBLE_DEVICES` which the
  container runtime maps to `/dev/nvidia*` device nodes — **not the Tegra paths**
- Result: `nvidia/k8s-device-plugin` will find **zero GPUs** on Jetson regardless of config

A Tegra-aware alternative is needed. Options:
1. **`nvidia/k8s-device-plugin` with CDI + `deviceListStrategy: cdi`** — if CDI spec correctly
   enumerates Tegra device nodes, the plugin can work without NVML. Requires nvgpu.ko loaded
   and CDI spec pre-generated for Tegra paths.
2. **Custom device plugin** enumerating `/dev/nvgpu` as the GPU device and passing Tegra nodes
   directly. Lower effort for a proof-of-concept.
3. **`tegra-device-plugin`** from JetPack BSP — not available for non-L4T kernels.

The recommended path is option 1 (CDI) since it keeps compatibility with the standard
`nvidia.com/gpu` resource name that workloads (ollama, whisper) already request.

This phase is TBD pending Phase 3 completion.

### Phase 6 — RuntimeClass

Standard Talos NVIDIA flow creates a `RuntimeClass`:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
```

This is still required on Jetson to select the NVIDIA container runtime for GPU workloads.
Pods wanting GPU access must set `runtimeClassName: nvidia`.

---

## Gaps vs Standard Talos NVIDIA Flow

The [official Talos NVIDIA GPU guide](https://docs.siderolabs.com/talos/v1.12/configure-your-talos-cluster/hardware-and-drivers/nvidia-gpu)
covers discrete PCIe GPUs. Jetson requires additional steps:

| Gap | Standard flow | Jetson requirement |
|-----|--------------|-------------------|
| Kernel module | `nvidia.ko` loaded via extension | `nvgpu.ko` from OE4T (custom extension) |
| Module autoload | udev triggers load on `/dev/nvidia*` creation | Must declare `machine.kernel.modules: [{name: nvgpu}]` in talconfig.yaml |
| `bpf_jit_harden` sysctl | Set by toolkit installer | Must be explicitly set in `machine.sysctls` |
| Device nodes | `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm` | `/dev/nvgpu`, `/dev/nvhost-*`, `/dev/nvmap` |
| Device plugin | `nvidia/k8s-device-plugin` finds `/dev/nvidia*` | Tegra device nodes differ — plugin may need CDI config or replacement |
| Container toolkit CDI | Auto-generated from NVML (`nvidia-ctk cdi generate`) | Must enumerate Tegra device paths manually |
| RuntimeClass | `nvidia` RuntimeClass required | Same — `nvidia` RuntimeClass still needed |

---

## Reference Links

- [OE4T/linux-nvgpu](https://github.com/OE4T/linux-nvgpu) — `patches-r36.5` branch
- [OE4T/nvidia-kernel-oot](https://github.com/OE4T/nvidia-kernel-oot) — umbrella OOT driver repo (nvgpu is a submodule)
- [siderolabs/extensions](https://github.com/siderolabs/extensions) — extension build pattern
- [siderolabs/pkgs](https://github.com/siderolabs/pkgs) — kernel build images used by extensions
- [Talos extension spec](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/)
- Build test Job: `cluster/.tools/nvgpu-build-test.yaml`

---

## Kernel API Change Reference

Quick reference for the patches applied (useful when building the proper extension):

```bash
# 1. vm_flags read-only (kernel 6.3) — entire driver tree
grep -rl 'vm_flags |=' . | \
  xargs -I{} sed -z -i 's/vma->vm_flags |= \([^;]*\);/vm_flags_set(vma, \1);/g' {}
grep -rl 'vm_flags &= ~' . | \
  xargs -I{} sed -z -i 's/vma->vm_flags &= ~\([^;]*\);/vm_flags_clear(vma, \1);/g' {}

# 2. class_create lost THIS_MODULE arg (kernel 6.4) — os/linux/ioctl.c
sed -i 's/class_create(THIS_MODULE, /class_create(/g' os/linux/ioctl.c

# 3. devnode callback gained const (kernel 6.2) — os/linux/*.c
grep -rl 'devnode' os/linux/ | \
  xargs sed -i 's/\(nvgpu[a-z_0-9]*devnode[a-z_0-9_v]*\)(struct device/\1(const struct device/g'

# 4. struct fd lost .file member (kernel 6.9) — os/linux/*.c
grep -rl 'fd\.file' os/linux/ | xargs sed -i 's/fd\.file/fd_file(fd)/g'

# 5. dma-buf-map.h renamed to iosys-map.h (kernel 5.18) — entire driver tree
grep -rl 'dma-buf-map\.h' . | xargs sed -i 's|linux/dma-buf-map\.h|linux/iosys-map.h|g'
grep -rl 'dma_buf_map' . | xargs sed -i \
  -e 's/struct dma_buf_map/struct iosys_map/g' \
  -e 's/dma_buf_map_set_/iosys_map_set_/g' \
  -e 's/dma_buf_map_clear/iosys_map_clear/g' \
  -e 's/dma_buf_map_is_null/iosys_map_is_null/g' \
  -e 's/dma_buf_map_is_vaddr/iosys_map_is_vaddr/g' \
  -e 's/DMA_BUF_MAP_INIT_/IOSYS_MAP_INIT_/g' \
  -e 's/DMA_BUF_MAP_/IOSYS_MAP_/g'

# 6. hrtimer_init -> hrtimer_setup (kernel 6.15) — entire driver tree
# Merges two-line pattern: hrtimer_init(x, clock, mode);\n  x.function = cb;
# into: hrtimer_setup(x, cb, clock, mode);
grep -rl 'hrtimer_init' . | \
  xargs -I{} sed -z -i \
    's/hrtimer_init(\([^,]*\), \([^,]*\), \([^)]*\));\n[^\n]*\.function = \([^;]*\);/hrtimer_setup(\1, \4, \2, \3);/g' {}
```

```bash
# 7. platform_driver.remove int->void (kernel 6.11) — os/linux/module.c
# Changes gk20a_remove_wrapper return type and fixes return 0 -> return
sed -z -i \
  's/static int \(gk20a_remove_wrapper([^)]*)\)\([^}]*\)return 0;/static void \1\2return;/g' \
  os/linux/module.c
```

More patches may surface — see Job logs for the full list as they appear.
