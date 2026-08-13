# Jetson Orin iGPU Enablement (nv1) — Design

## Context

`nv1` (192.168.48.5) is an **NVIDIA Jetson Orin NX 16GB Super devkit** — a T234
SoC with a GA10B (Ampere, compute 8.7) integrated GPU. It joined the cluster
126 days ago as an arm64 worker and has been effectively idle since: it carries
a `NoSchedule` taint and runs only cilium, cilium-envoy, alloy, node-exporter
and one smartmon-exporter instance.

Its GPU is unusable. Verified on the live node (2026-08-13):

| Check                        | Result                                       |
| ---------------------------- | -------------------------------------------- |
| `tegra_drm`, `host1x` loaded | yes (mainline Talos modules)                 |
| `nvgpu.ko` (the CUDA driver) | **absent**                                   |
| `/dev/dri`                   | **does not exist**                           |
| Talos schematic `185266dd…`  | kernel args only — no overlay, no extensions |

This is exactly the failure mode described by
[schwankner/talos-jetson-orin](https://github.com/schwankner/talos-jetson-orin):
mainline Talos ships a `tegra-drm.ko` that is ABI-incompatible with the
OE4T-patched `host1x.ko`, so the DRM render node never appears and CUDA
initialisation fails. That project builds the complete OE4T DRM stack (8 kernel
modules including `nvgpu.ko`) as a Talos system extension, ships a custom
installer image, and adds a CDI-based device plugin so pods get GPU access
without running privileged.

The project is real but narrow: one maintainer, 7 stars, last pushed
2026-08-04. Its `BUGS.md` documents 21 issues resolved during the port, which is
both evidence of diligence and a signal of how much bespoke machinery holds it
together.

### The binding constraint

Kernel modules are ABI-bound to an exact Talos kernel build. Published
installer tags on ghcr (enumerated 2026-08-13) stop at:

```
ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim
```

The cluster runs **Talos v1.13.5 / kernel 6.18.36**. No image exists for it. A
`v1.13.8-nvgpu5.11.1-drm-noshim` git tag exists upstream with no release and no
published image behind it. There is therefore no way to adopt this today that
keeps nv1 on the same Talos version as mc1–mc3.

## Goals

- Expose the GA10B iGPU as a schedulable `nvidia.com/gpu` resource on nv1.
- Run ollama on nv1 with the CUDA (JetPack 6) backend.
- Keep nv1 reserved for GPU workloads; no general workload drift onto it.
- Keep everything declarative — Talos config in `provision/talos`, cluster
  state in ArgoCD. No hand-applied node state.

## Non-goals

- **NVDEC/NVENC hardware video codecs.** The upstream port enables CUDA compute
  only. Frigate-style transcoding is out of scope.
- **Making nv1 a Ceph OSD host.** `rook-discover` stays off it.
- **Phase 2 build pipeline detail.** Specified here only by its interface (it
  swaps one image reference); designed properly if and when the gate passes.
- **Mirroring JetPack `.deb`s into a local registry.** Deferred to Phase 2.

## Decisions

| Decision          | Choice                                            | Rationale                                                                              |
| ----------------- | ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Adoption strategy | Phased: prove with prebuilt, then build           | Avoids sinking ~2h ARM64 builds into a stack that may not work on this unit            |
| Phase 1 installer | Upstream `v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim` | Only published artifact; nv1 pinned to Talos v1.13.0                                   |
| Delivery          | `talosctl upgrade --image`                        | nv1 is already a healthy member; preserves NVMe install, config and cluster membership |
| Ollama topology   | Repoint existing `cluster/apps/ai/ollama`         | One app; Intel i915 path dropped                                                       |
| Model storage     | `ceph-block`, unchanged                           | Enabled by granting Ceph CSI a toleration                                              |
| nv1 isolation     | Keep a taint, rename it                           | A taint is the only mechanism that repels pods that have not opted in                  |

## Architecture

Three layers, deliberately decoupled so each fails and rolls back independently.

```
Layer 1 — Talos node          provision/talos/nodes/nv1.yaml
  custom installer UKI -> nvgpu.ko + OE4T DRM stack -> /dev/dri/renderD128
  kernel.modules load order, containerd enable_cdi, node labels
  delivered by: talosctl upgrade --image      (NOT ArgoCD)

Layer 2 — GPU stack           cluster/apps/system/nvidia/
  cdi-setup DS     -> JetPack libs + /var/run/cdi/nvidia-jetson.yaml
  device-plugin DS -> advertises nvidia.com/gpu
  power-mode DS    -> MAXN clocks
  delivered by: ArgoCD

Layer 3 — workload            cluster/apps/ai/ollama/
  nodeSelector accelerator=jetson-orin, nvidia.com/gpu: 1
  delivered by: ArgoCD
```

### Phasing

|             | Phase 1 — prove                      | Phase 2 — own                 |
| ----------- | ------------------------------------ | ----------------------------- |
| Installer   | upstream prebuilt                    | ours, built for current Talos |
| nv1 Talos   | v1.13.0 (behind mc1–3)               | rejoins cluster version       |
| Build infra | none                                 | fork + arm64 GitHub Actions   |
| Gate        | `/dev/dri/renderD128` + CUDA + tok/s | —                             |

## Layer 1 — Talos node

All changes land in `provision/talos/nodes/nv1.yaml`, which today holds only
networking.

```yaml
machine:
  network: { ...unchanged... }

  install:
    image: ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim

  kernel:
    modules: # explicit — no device-tree probe triggers these
      - name: host1x
      - name: host1x_fence
      - name: host1x_nvhost
      - name: tegra_drm # creates /dev/dri/renderD128
      - name: nvmap
      - name: mc_utils
      - name: nvgpu # the CUDA driver
      - name: governor_pod_scaling

  nodeLabels:
    accelerator: jetson-orin
    nvidia.com/gpu.type: igpu

  files:
    - path: /etc/cri/containerd.toml
      op: overwrite
      permissions: 0o644
      content: |
        # verbatim current content + the CDI block below
        [plugins."io.containerd.cri.v1.runtime"]
          enable_cdi = true
          cdi_spec_dirs = ["/var/run/cdi"]
```

`install.disk` (`/dev/nvme0n1`) and `wipe: false` already match
`templates/worker.yaml`; no override needed.

**Verified during design:**

- `talosctl machineconfig patch` **merges** `machine.files` rather than
  replacing it — the template's `/etc/cri/conf.d/20-customization.part` entry
  survives. Confirmed by running the patch locally.
- nv1's live `/etc/cri/containerd.toml` under Talos v1.13.5 is **byte-identical**
  to upstream's hardcoded v1.13.0 copy apart from the CDI block. The overwrite
  loses nothing Talos-managed, and the template's stability across
  v1.13.0 → v1.13.5 de-risks Phase 2.

### Taskfile: per-node Talos version

`talos:upgrade` already derives the image from the generated per-node config:

```yaml
TALOS_IMAGE:
  sh: yq ea '[.machine.install.image].[0]' < "{{.FILE}}"
```

so overriding `machine.install.image` is picked up for free. Its idempotency
guard, however, breaks:

```yaml
status:
  - talosctl version --nodes {{.NODE}} --short | grep -q 'Tag.*{{ .TALOS_VERSION }}'
```

With the global `TALOS_VERSION=v1.13.5` and nv1 pinned to v1.13.0 this never
matches, so **`task talos:upgrade:all` would reinstall nv1 on every run**. Fix:
an optional per-node override in `nodes.yaml`, defaulting to the global value.

```yaml
nodes:
  - name: nv1
    ip: 192.168.48.5
    type: worker
    talosVersion: v1.13.0 # pinned: GPU extension is ABI-bound to kernel 6.18.24
```

The guard resolves per-node. This is the seam Phase 2 removes: delete the
`talosVersion` line and nv1 rejoins the global version.

## Layer 2 — GPU stack in GitOps

`cluster/apps/system/nvidia/`, kustomize-based since upstream ships raw
manifests:

```
nvidia/
├── app-config.yaml        namespace nvidia-system, PSA enforce=privileged
├── kustomization.yaml     vendored upstream manifests + patches
└── resources/             cdi-setup · device-plugin · power-mode
```

One Application, not three. Ordering (cdi-setup → device-plugin → power-mode)
comes from resource-level `argocd.argoproj.io/sync-wave` annotations. The
device plugin must not advertise `nvidia.com/gpu` before the CDI spec exists,
but that does not justify three Applications. `managedNamespaceMetadata` sets
`pod-security.kubernetes.io/enforce: privileged`, following the existing
`cluster/apps/system/intel/app-config.yaml` precedent.

### Required adaptations to upstream manifests

1. **`nodeSelector: accelerator=jetson-orin` on all three DaemonSets.** Upstream
   carries `tolerations: [{operator: Exists}]` and _no_ nodeSelector, assuming a
   single-node Jetson cluster. Unmodified, that schedules arm64/Tegra-specific
   privileged pods onto mc1–mc3, where they crash-loop against amd64 hardware
   with no `/dev/nvmap`. The label is set by Layer 1, so there is no bootstrap
   ordering problem. The blanket toleration then correctly covers the nv1 taint.
2. **Digest-pin images** per repo Renovate conventions: `busybox:1.36`,
   `ubuntu:22.04`, `ghcr.io/schwankner/jetson-device-plugin:v1.0.0`.

### Accepted risk

The `nvidia-cdi-setup` DaemonSet runs `ubuntu:22.04` with `hostPID`, mounting
`/dev`, `/sys`, `/usr/lib/firmware` and `/var`, and on every pod start does
`apt-get install curl dpkg` then downloads unpinned JetPack r36.5 `.deb`s from
`repo.download.nvidia.com`. This is a live network dependency in the node's
GPU-readiness path and a third-party trust surface. Accepted for Phase 1;
mirroring is a Phase 2 follow-up.

## Layer 3 — ollama

`cluster/apps/ai/ollama` is repointed from Intel i915 to the Jetson. nv1's
allocatable memory is **15495304Ki ≈ 14.8Gi**, shared between CPU and GPU —
there is no separate VRAM. This drives several changes:

| Current                  | Problem                                    | New                        |
| ------------------------ | ------------------------------------------ | -------------------------- |
| `memory: 16Gi` limit     | exceeds node allocatable → never schedules | `13Gi`                     |
| `gemma4:26b`             | ~16GB+, cannot fit                         | dropped                    |
| `deepcoder:14b`          | ~9GB, little headroom                      | dropped                    |
| `OLLAMA_VULKAN: "1"`     | Intel/Vulkan path                          | removed                    |
| `gpu.intel.com/i915: 1`  | wrong resource                             | `nvidia.com/gpu: 1`        |
| `persistentVolume: 40Gi` | sized for dropped models                   | `20Gi`, still `ceph-block` |

```yaml
ollama:
  image: { tag: "0.20.5" } # >=0.20.5 for the JetPack 6 CUDA backend
  ollama:
    models:
      pull: [qwen3.5:9b, nomic-embed-text]
  extraEnv:
    - { name: JETSON_JETPACK, value: "6" } # REQUIRED — see below
    - { name: OLLAMA_FLASH_ATTENTION, value: "1" }
    - { name: OLLAMA_NUM_PARALLEL, value: "1" }
    - { name: OLLAMA_KV_CACHE_TYPE, value: "q4_0" }
  nodeSelector: { accelerator: jetson-orin }
  tolerations:
    - {
        key: nvidia.com/gpu,
        operator: Equal,
        value: present,
        effect: NoSchedule,
      }
  resources:
    limits: { nvidia.com/gpu: 1, memory: 13Gi }
    requests: { nvidia.com/gpu: 1, memory: 8Gi, cpu: 100m }
```

`JETSON_JETPACK=6` is what activates `cuda_jetpack6/libggml-cuda.so` for GA10B
(upstream Bug 19). Without it the container starts and serves requests on CPU
while appearing healthy — a silent failure worth watching for during
verification.

No `privileged: true` is needed; CDI injects the devices, the library mount and
`LD_LIBRARY_PATH` automatically.

## Scheduling and isolation

A taint is the only Kubernetes mechanism that repels pods which have not opted
in. Node labels and `nodeSelector` only work if every _other_ workload opts
out, which cannot be enforced on apps added later, and the `nvidia.com/gpu`
extended resource gates GPU pods without repelling non-GPU ones. The taint
therefore stays; granting tolerations is the intended pattern, matching what
NVIDIA's own GPU Operator does.

### Taint rename

The current taint resolves on the node to `key=nv, value=NoSchedule,
effect=NoSchedule` — the value appears accidental. It is renamed in
`templates/worker.yaml` to:

```
nvidia.com/gpu=present:NoSchedule
```

**The Talos `nodeTaints` syntax must be verified empirically.** The existing
`nv: :NoSchedule` did not produce the value a reading of the syntax would
predict, so the new taint is applied and then re-read with
`kubectl get node nv1 -o jsonpath='{.spec.taints}'` rather than assumed correct.

### Toleration changes

| Where                                                  | Change                                                             |
| ------------------------------------------------------ | ------------------------------------------------------------------ |
| `Driver` CR `rook-ceph.rbd.csi.ceph.com`               | add `spec.nodePlugin.tolerations`                                  |
| `Driver` CR `rook-ceph.cephfs.csi.ceph.com`            | add `spec.nodePlugin.tolerations`                                  |
| `system/node-feature-discovery/values.yaml`            | add worker toleration                                              |
| `system/prometheus-stack/templates/metrics-proxy.yaml` | add toleration                                                     |
| `system/smartmon-exporter/values.yaml`                 | **update** existing `value: NoSchedule` to match the renamed taint |

Deliberately **not** tolerated: `rook-discover` (nv1 must not host OSDs) and
`intel-gpu-plugin` (no Intel GPU present).

### Ceph on nv1

Rook v1.20.3 runs with `csi.installCsiOperator: true`, so CSI scheduling is
governed by ceph-csi-operator `Driver` CRs, not the legacy
`CSI_PLUGIN_TOLERATIONS` ConfigMap key. Both CRs currently have
`spec.nodePlugin.tolerations: []`, and the nodeplugin DaemonSets have no
nodeSelector and no affinity — `desired=3` purely because the taint repels
them. nv1's `CSINode` object lists zero drivers, so a pod with a `ceph-block`
PVC there would bind the PVC but hang in `ContainerCreating`
(_"driver name … not found in the list of registered CSI drivers"_):
`CreateVolume` is served by the ctrlplugin on mc1, but `NodePublishVolume`
requires a nodeplugin on the scheduling node.

`quay.io/cephcsi/cephcsi:v3.17.0` is multi-arch (linux/amd64, linux/arm64), so
arm64 is not a concern.

**Open item:** whether Rook reconciles the `Driver` CRs back after patching.
They carry no `ownerReferences`, so the patch may persist; if it does not, the
CRs are managed through the rook-ceph ArgoCD app instead. The implementation
plan must verify this rather than assume.

## Verification — the go/no-go gate

**Establish the CPU baseline first.** Before any change, run ollama on nv1 on
CPU (temporarily tolerating the taint) and record tok/s for one small and one
~7B model. Without it, "23 tok/s" has nothing to compare against, and the
Orin's 8 A78AE cores are not a bad CPU. If the GPU cannot clearly beat the
node's own CPU, the exercise has failed regardless of whether CUDA initialises.

Each check is a hard stop:

| #   | Check                                                      | Pass condition                               |
| --- | ---------------------------------------------------------- | -------------------------------------------- |
| 1   | `talosctl version -n 192.168.48.5`                         | Talos v1.13.0, node `Ready`                  |
| 2   | `read /proc/modules \| grep nvgpu`                         | `nvgpu` loaded                               |
| 3   | `ls /dev/dri`                                              | `renderD128` present — _the bug today_       |
| 4   | `read /etc/cri/containerd.toml`                            | CDI block present                            |
| 5   | cdi-setup DS logs                                          | `/var/run/cdi/nvidia-jetson.yaml` written    |
| 6   | `kubectl get node nv1 -o jsonpath='{.status.allocatable}'` | `nvidia.com/gpu: 1`                          |
| 7   | CUDA smoke pod                                             | device count >= 1, **no error 801 / 999**    |
| 8   | ollama tok/s                                               | **>= 2x** the CPU baseline on the same model |

Checks 1–3 are decidable within minutes of the reboot and kill the effort
cheaply. Check 7 is where upstream's hardest bugs lived (their Bugs 6, 14, 19)
and is the most likely failure point.

The 2x threshold on check 8 is a judgement call, chosen so the outcome is
unambiguous: anything less than a doubling would not justify pinning nv1 to an
off-cluster Talos version and maintaining a bespoke kernel build. A measured
result between 1x and 2x is a **no-go for Phase 2** — the Phase 1 state may
still be kept, since it is independently revertible.

## Phase 2 (sketch)

Only if the gate passes. Fork upstream; build on `ubuntu-24.04-arm` GitHub
Actions runners; the module signing key comes from Actions secrets and is
**never committed** (upstream's "commit the key" instruction is their
reproducibility convenience, not a technical requirement, and this repo is
public). Publish
`ghcr.io/mmalyska/talos-jetson-installer:<talos>-<kernel>-<nvgpu>`, then delete
`talosVersion: v1.13.0` from `nodes.yaml` and swap the image reference.

Renovate must **not** auto-bump nv1's Talos version: a bump without a matching
rebuilt extension leaves the node without a GPU, or unbootable.

## Risks

| Risk                                           | Mitigation                                                      |
| ---------------------------------------------- | --------------------------------------------------------------- |
| Custom UKI fails to boot                       | USB reflash; physical access to nv1 is easy                     |
| Talos downgrade v1.13.5 → v1.13.0 refused      | `--force`; fallback is USB install                              |
| CUDA error 801/999                             | Gate check 7 — abandon before Layer 2/3 work                    |
| Upstream stops publishing images               | Precisely what Phase 2 removes                                  |
| JetPack `.deb` download fails at pod start     | Known; mirror in Phase 2                                        |
| Talos changes its `containerd.toml` template   | Verified stable v1.13.0→v1.13.5; re-diff on every Talos upgrade |
| Rook reverts the `Driver` CR patch             | Manage the CRs via the rook-ceph ArgoCD app                     |
| `JETSON_JETPACK` missing → silent CPU fallback | Gate check 8 compares against the CPU baseline                  |

## Rollback

Revert `nodes/nv1.yaml` to the factory installer image, `talosctl upgrade`, and
set the nvidia app `enabled: "false"`. nv1 returns to its current state: an
idle, tainted arm64 node. The taint rename and toleration changes are
independent of the GPU work and can be kept or reverted separately.
