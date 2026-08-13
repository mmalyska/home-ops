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

|             | Phase 0 — reconcile nv1                       | Phase 1 — prove                      | Phase 2 — own                 |
| ----------- | --------------------------------------------- | ------------------------------------ | ----------------------------- |
| Scope       | taint rename, tolerations, apply stale config | upstream prebuilt installer          | ours, built for current Talos |
| Installer   | unchanged (factory)                           | upstream prebuilt                    | ours                          |
| nv1 Talos   | v1.13.5 (unchanged)                           | v1.13.0 (behind mc1–3)               | rejoins cluster version       |
| Build infra | none                                          | none                                 | fork + arm64 GitHub Actions   |
| Gate        | node Ready, taints correct, DS counts 3→4     | `/dev/dri/renderD128` + CUDA + tok/s | —                             |

Phase 0 does **not** touch the GPU and is independently valuable: it fixes a
pre-existing drift, gives nv1 working Ceph storage, and restores observability
parity. It ships and can be judged on its own. It is also a prerequisite for
Phase 1's CPU baseline measurement, which needs a schedulable, storage-capable
nv1.

## Phase 0 — reconcile nv1

Ordered so that no pod is ever left unable to schedule. `NoSchedule` does not
evict running pods, so the risk is low, but the sequence removes the window
entirely.

1. **Widen tolerations first (Git → ArgoCD).** Add tolerations covering _both_
   the old `nv` taint and the new `nvidia.com/gpu` taint to the two ceph-csi
   `Driver` CRs, `node-feature-discovery`, and `metrics-proxy`; update
   `smartmon-exporter` to tolerate both. Sync and confirm the Ceph nodeplugins
   reach nv1 (`desired` 3 → 4) while the old taint is still in place.
2. **Rename the taint (Talos).** Change `templates/worker.yaml` to
   `nvidia.com/gpu: present:NoSchedule`, then `task talos:generate` and
   `task talos:apply N=nv1`. This apply also carries the unrelated staleness
   fix (see below).
3. **Verify the expected double-taint.** Reading `.spec.taints` on nv1 should
   now show **both** `nv` and `nvidia.com/gpu`, and the
   `talos.dev/owned-taints` annotation should list `nvidia.com/gpu`.
4. **Remove the orphan.** `kubectl taint nodes nv1 nv-`, then re-read the taints
   and confirm `nv` does not come back.
5. **Narrow the tolerations.** Drop the transitional `nv` tolerations from Git,
   leaving only `nvidia.com/gpu`.
6. **Verify.** `rook-ceph.rbd`/`cephfs` nodeplugins, `node-feature-discovery`
   and `metrics-proxy` at `desired=4`; smartmon-1 still on nv1; nv1 `Ready`;
   `CSINode nv1` lists both ceph drivers.

### The staleness fix, quantified

nv1's stored machine config was last applied under Talos v1.12.7 (mc1 is at
v1.13.4), but a full diff of running vs generated config shows the gap is
narrow. Every semantic difference:

| Difference                                                                                                       | Impact                                                                 |
| ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `install.image` `…:v1.12.7` → `…:v1.13.5`                                                                        | config metadata only; no reinstall, no reboot                          |
| Node has migrated `HostnameConfig` + `LinkConfig` documents; repo still uses deprecated inline `machine.network` | identical address, route, MTU and hostname; Talos re-migrates on apply |
| `nodeTaints`                                                                                                     | **identical** in both — the drift is node-side only                    |

So the apply is low-risk. It is still done as its own step with the diff
re-checked immediately beforehand, and the node confirmed `Ready` afterwards,
rather than folded into the GPU work.

**Noted, not done:** `nodes/nv1.yaml` uses the deprecated inline
`machine.network.interfaces` form, so each apply flips the representation and
Talos re-migrates it. Converting the node files to `LinkConfig` /
`HostnameConfig` documents would remove that churn, but it touches the generate
pipeline for all nodes and is out of scope here.

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

**Syntax — resolved.** Talos parses each `nodeTaints` map value with
`labels.ParseTaint` (`pkg/machinery/labels/taints.go`):

```go
func ParseTaint(s string) (value, effect string) {
	value, effect, found = strings.Cut(s, ":")
	if !found { effect = value; value = "" }
	return value, effect
}
```

So the format is `key: value:effect`, and the new taint is written in
`templates/worker.yaml` as:

```yaml
nodeTaints:
  nvidia.com/gpu: present:NoSchedule # -> value=present, effect=NoSchedule
```

**Pre-existing drift.** What the repo declares and what the node carries
disagree:

| Source                                      | key  | value          | effect       |
| ------------------------------------------- | ---- | -------------- | ------------ |
| Repo `nv: :NoSchedule` through `ParseTaint` | `nv` | `""`           | `NoSchedule` |
| Talos `NodeTaintSpec` on nv1 (desired)      | `nv` | `""`           | `NoSchedule` |
| Actual `Node.spec.taints` on nv1            | `nv` | `"NoSchedule"` | `NoSchedule` |

**Why it never converges.** `NodeApplyController.ApplyTaints`
(`internal/app/machined/pkg/controllers/k8s/node_apply.go`) matches taints by
**key** and tracks ownership in the `talos.dev/owned-taints` node annotation:

- key absent → add it, mark owned
- key present **and owned** → update value and effect
- key present, **not owned**, value and effect already equal the spec → adopt it
- key present, **not owned**, anything differs → **skip permanently**
  (`"skipping taint update, taint is not owned"`)

and the removal pass only ever drops taints Talos **owns**.

nv1 has **no `talos.dev/owned-taints` annotation at all** — only
`owned-annotations` and `owned-labels` — so Talos owns zero taints there. The
`nv` taint is unowned with a differing value, which lands it in the "skip
permanently" branch. The value is a leftover, almost certainly from the
talhelper era (commit `f12a486a` replaced talhelper with talosctl + envsubst),
whose list-form schema would have taken a `value: NoSchedule` field literally.

Three consequences:

1. **A plain re-apply fixes nothing.** The running config already yields
   `value=""` and the node has ignored it. Applying the same config again
   changes no taint state.
2. **The rename leaves nv1 double-tainted.** `nvidia.com/gpu` is a new key, so
   Talos adds it and takes ownership — but `nv` remains unowned, so the removal
   pass keeps it. Without intervention nv1 ends up carrying **both** taints.
3. **`kubectl taint nodes nv1 nv-` is required, and will stick.** Once `nv` is
   absent from the spec, Talos has no path that re-adds it.

`smartmon-exporter`'s nv1 toleration (`operator: Equal, value: NoSchedule`)
matches the drifted taint, so it breaks at the **rename**, not at a plain
apply — which is why the toleration updates must land before the taint changes.

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

**Resolved — Rook does not own these CRs; ArgoCD does.** The `Driver` objects
carry no `ownerReferences` and no `managedFields`, but they do carry:

```
argocd.argoproj.io/tracking-id: rook-ceph-csi-drivers:csi.ceph.io/Driver:rook-ceph/rook-ceph.rbd.csi.ceph.com
```

They are rendered by the `ceph-csi-drivers` Helm chart via
`cluster/apps/core/rook-ceph/csi-drivers`, an existing ArgoCD app
(`appSubfolder: csi-drivers`, `syncWave: "2"`). So a manual `kubectl patch`
would be drift against Git, not against Rook — the correct change is in
`csi-drivers/values.yaml`:

```yaml
ceph-csi-drivers:
  drivers:
    rbd:
      nodePlugin:
        tolerations:
          - {
              key: nvidia.com/gpu,
              operator: Equal,
              value: present,
              effect: NoSchedule,
            }
    cephfs:
      nodePlugin:
        tolerations:
          - {
              key: nvidia.com/gpu,
              operator: Equal,
              value: present,
              effect: NoSchedule,
            }
```

Verified by rendering the chart locally: the values above produce
`spec.nodePlugin.tolerations` on the `Driver` CR exactly as intended.

Two operational notes:

- The app is `syncPolicy.enabled: false` (`selfHeal: true`), so it does **not**
  auto-sync — the change needs a deliberate ArgoCD sync.
- Editing the `Driver` CR triggers ceph-csi-operator to update the nodeplugin
  DaemonSets, which **rolling-restarts the CSI plugins on mc1–mc3**. Existing
  mounts survive a nodeplugin restart, but new attach/mount operations fail
  briefly, so this is done as its own Phase 0 step with the rollout watched to
  completion rather than bundled with other changes.

**Unrelated observation:** `csi-drivers/Chart.yaml` requests `ceph-csi-drivers`
`1.0.4` while `Chart.lock` and the vendored tgz are `1.0.1`. Not touched by this
work, but worth a follow-up.

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

| Risk                                                               | Mitigation                                                                                                                      |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------- |
| Custom UKI fails to boot                                           | USB reflash; physical access to nv1 is easy                                                                                     |
| Talos downgrade v1.13.5 → v1.13.0 refused                          | `--force`; fallback is USB install                                                                                              |
| CUDA error 801/999                                                 | Gate check 7 — abandon before Layer 2/3 work                                                                                    |
| Upstream stops publishing images                                   | Precisely what Phase 2 removes                                                                                                  |
| JetPack `.deb` download fails at pod start                         | Known; mirror in Phase 2                                                                                                        |
| Talos changes its `containerd.toml` template                       | Verified stable v1.13.0→v1.13.5; re-diff on every Talos upgrade                                                                 |
| `Driver` CR edit rolling-restarts CSI nodeplugins on mc1–mc3       | Expected. Existing mounts survive; new attach/mount briefly fails. Own Phase 0 step, rollout watched to completion              |
| Stale `nv` taint survives the rename, double-tainting nv1          | Expected, not hypothetical — Talos cannot remove an unowned taint. Phase 0 step 4 removes it with `kubectl taint nodes nv1 nv-` |
| Rename breaks smartmon's `value: NoSchedule` toleration            | Phase 0 widens tolerations (step 1) before renaming (step 2)                                                                    |
| Applying nv1's config (stale since v1.12.7) causes unrelated drift | Full diff taken; only `install.image` metadata and a network representation re-migration. Re-diff immediately before applying   |
| `JETSON_JETPACK` missing → silent CPU fallback                     | Gate check 8 compares against the CPU baseline                                                                                  |

## Rollback

Revert `nodes/nv1.yaml` to the factory installer image, `talosctl upgrade`, and
set the nvidia app `enabled: "false"`. nv1 returns to its current state: an
idle, tainted arm64 node. The taint rename and toleration changes are
independent of the GPU work and can be kept or reverted separately.
