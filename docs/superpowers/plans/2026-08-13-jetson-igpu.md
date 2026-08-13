# Jetson Orin iGPU Enablement (nv1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Jetson Orin NX iGPU on `nv1` usable as a schedulable `nvidia.com/gpu` resource and run ollama on it with CUDA — after first reconciling nv1's pre-existing config and taint drift.

**Architecture:** Three decoupled layers. Layer 1 is the Talos node (custom installer UKI carrying the OE4T DRM stack, delivered by `talosctl upgrade --image`, never by ArgoCD). Layer 2 is the GPU stack as a kustomize ArgoCD app. Layer 3 is ollama. Phase 0 precedes all of it and touches no GPU code.

**Tech Stack:** Talos Linux v1.13.x, Kubernetes v1.35.6, ArgoCD ApplicationSets, Helm + Kustomize, Rook-Ceph v1.20.3 with ceph-csi-operator, `task` automation, `talosctl`.

**Design spec:** `docs/superpowers/specs/2026-08-13-jetson-igpu-design.md`

## Global Constraints

- **Never mutate cluster state without explicit user confirmation.** Steps marked **⚠ CONFIRM** must stop and ask before running. This includes `talosctl apply-config`, `talosctl upgrade`, `kubectl taint`, and ArgoCD syncs.
- **Never push to `main`.** All changes via PR; branches use `feat/`, `fix/`, `chore/` prefixes.
- **Never commit secrets.** The gitleaks pre-commit hook enforces this.
- Talos version pinned for nv1 in Phase 1: `v1.13.0`, kernel `6.18.24`. Cluster global stays `v1.13.5`.
- Upstream installer image (exact, do not substitute): `ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim`
- New taint (exact): `nvidia.com/gpu=present:NoSchedule`. Talos syntax: `nvidia.com/gpu: present:NoSchedule`.
- nv1 allocatable memory is **15495304Ki ≈ 14.8Gi**, shared between CPU and GPU. No pod on nv1 may request or limit more than `13Gi`.
- `TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig` for all `talosctl` calls.
- Non-interactive shell: always use `-f`/`-rf` with `cp`/`mv`/`rm` (aliased to `-i` in this devcontainer).
- Run `npx prettier --write <file>` on any Markdown or YAML touched, before committing.
- **YAML snippets in this plan are shown at column 0.** Prettier normalizes fenced YAML, so the indentation below does **not** reflect nesting depth. Place each snippet at the depth the surrounding prose describes, then confirm with the render/verify step that follows it. Never paste a snippet literally without checking its indentation.

---

# PHASE 0 — Reconcile nv1

No GPU work. Independently shippable. Fixes pre-existing drift, gives nv1 Ceph storage, restores observability parity.

**Why the ordering matters:** `nvidia.com/gpu` is a new taint key, so Talos adds and owns it, but the removal pass only drops taints Talos _owns_ — and nv1 has no `talos.dev/owned-taints` annotation at all, so `nv` is unowned and will survive. Tolerations must therefore cover **both** taints before the rename, and the orphan `nv` must be removed by hand afterwards.

### Task 1: Widen tolerations to cover both taints

Every workload that must reach nv1 gets a toleration for the old `nv` taint **and** the new `nvidia.com/gpu` taint, so there is no window where a restarting pod cannot be placed.

**Files:**

- Modify: `cluster/apps/core/rook-ceph/csi-drivers/values.yaml`
- Modify: `cluster/apps/system/node-feature-discovery/values.yaml`
- Modify: `cluster/apps/system/prometheus-stack/templates/metrics-proxy.yaml`
- Modify: `cluster/apps/system/smartmon-exporter/values.yaml`

**Interfaces:**

- Consumes: nothing.
- Produces: the transitional toleration set. Task 6 narrows it to `nvidia.com/gpu` only.

- [ ] **Step 1: Create the branch**

```bash
cd /workspaces/home-ops
git checkout main && git pull
git checkout -b feat/nv1-reconcile
```

- [ ] **Step 2: Record the failing state**

```bash
kubectl get ds -A -o json | jq -r '.items[]
  | select(.metadata.name | test("nodeplugin|node-feature-discovery-worker|metrics-proxy"))
  | "\(.metadata.namespace)/\(.metadata.name) desired=\(.status.desiredNumberScheduled)"'
```

Expected now: all report `desired=3` (nv1 excluded). Save this output; Task 2 compares against it.

- [ ] **Step 3: Add tolerations to the ceph-csi Driver CRs**

In `cluster/apps/core/rook-ceph/csi-drivers/values.yaml`, add a `tolerations` key under `drivers.rbd.nodePlugin` (a sibling of the existing `resources:` key), and the identical block under `drivers.cephfs.nodePlugin`:

```yaml
nodePlugin:
  tolerations:
    - key: nv
      operator: Equal
      value: NoSchedule
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: NoSchedule
  resources:
    # ...existing resources block unchanged...
```

- [ ] **Step 4: Add a toleration to node-feature-discovery**

In `cluster/apps/system/node-feature-discovery/values.yaml`, add `tolerations` under `node-feature-discovery.worker`, as a sibling of the existing `resources:` and `config:` keys:

```yaml
worker:
  tolerations:
    - key: nv
      operator: Equal
      value: NoSchedule
      effect: NoSchedule
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: NoSchedule
  resources:
    # ...existing resources block unchanged...
```

- [ ] **Step 5: Add tolerations to metrics-proxy**

In `cluster/apps/system/prometheus-stack/templates/metrics-proxy.yaml`, extend the existing `tolerations:` list in the DaemonSet pod spec (currently only the master toleration):

```yaml
tolerations:
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
  - key: nv
    operator: Equal
    value: NoSchedule
    effect: NoSchedule
  - key: nvidia.com/gpu
    operator: Equal
    value: present
    effect: NoSchedule
```

- [ ] **Step 6: Add the new taint to smartmon's existing toleration list**

In `cluster/apps/system/smartmon-exporter/values.yaml`, under `extraInstances[0].tolerations`, **keep** the existing `nv` entry and append the new one:

```yaml
tolerations:
  - key: nv
    operator: Equal
    value: NoSchedule
    effect: NoSchedule
  - key: nvidia.com/gpu
    operator: Equal
    value: present
    effect: NoSchedule
```

- [ ] **Step 7: Verify the rendered output — ceph-csi**

```bash
cd /workspaces/home-ops/cluster/apps/core/rook-ceph/csi-drivers
helm dependency update . >/dev/null 2>&1
helm template csi-drivers . -f values.yaml \
  | yq 'select(.kind=="Driver") | {"name": .metadata.name, "tol": .spec.nodePlugin.tolerations}'
```

Expected: exactly two Drivers — `rook-ceph.rbd.csi.ceph.com` and `rook-ceph.cephfs.csi.ceph.com` — each listing both tolerations. No `nfs` or `nvmeof` Driver.

- [ ] **Step 8: Verify the rendered output — NFD, metrics-proxy, smartmon**

```bash
cd /workspaces/home-ops
for d in cluster/apps/system/node-feature-discovery cluster/apps/system/smartmon-exporter; do
  echo "### $d"
  (cd "$d" && helm dependency update . >/dev/null 2>&1 && helm template x . -f values.yaml \
    | yq 'select(.kind=="DaemonSet") | {"n": .metadata.name, "tol": .spec.template.spec.tolerations}')
done
echo "### metrics-proxy"
yq 'select(.kind=="DaemonSet") | .spec.template.spec.tolerations' \
  cluster/apps/system/prometheus-stack/templates/metrics-proxy.yaml
```

Expected: the NFD **worker** DaemonSet, the smartmon `-1` instance, and metrics-proxy each carry both `nv` and `nvidia.com/gpu` tolerations.

(`worker.tolerations` is confirmed present in node-feature-discovery chart 0.19.0, defaulting to `[]`.)

- [ ] **Step 9: Lint and commit**

```bash
cd /workspaces/home-ops
npx --yes prettier --write \
  cluster/apps/core/rook-ceph/csi-drivers/values.yaml \
  cluster/apps/system/node-feature-discovery/values.yaml \
  cluster/apps/system/prometheus-stack/templates/metrics-proxy.yaml \
  cluster/apps/system/smartmon-exporter/values.yaml
task lint:yaml
git add -A
git commit -m "feat(nv1): tolerate both old and new nv1 taints

Transitional step: workloads that must reach nv1 tolerate the current
nv taint and the incoming nvidia.com/gpu taint, so the rename cannot
leave a pod unschedulable. Narrowed back to one taint after the rename."
```

---

### Task 2: Sync and confirm the CSI plugins reach nv1

**⚠ CONFIRM** — this task mutates cluster state and rolling-restarts the CSI nodeplugins on mc1–mc3.

**Files:** none (cluster operations only).

**Interfaces:**

- Consumes: the toleration changes from Task 1, merged to `main`.
- Produces: ceph-csi nodeplugins registered on nv1; `CSINode nv1` lists both drivers. Task 13 depends on this for ollama's PVC.

- [ ] **Step 1: Push and open the PR**

```bash
cd /workspaces/home-ops
git push -u origin feat/nv1-reconcile
gh pr create --title "feat(nv1): reconcile taints, tolerations and stale config" \
  --body "Phase 0 of the Jetson iGPU work. See docs/superpowers/specs/2026-08-13-jetson-igpu-design.md.

Widens tolerations so workloads that must reach nv1 tolerate both the current nv taint and the incoming nvidia.com/gpu taint."
```

Wait for CI, then merge.

- [ ] **Step 2: ⚠ CONFIRM — sync the affected ArgoCD apps**

Ask the user before running. `rook-ceph-csi-drivers` has `syncPolicy.enabled: false`, so it will **not** auto-sync.

```bash
argocd app sync rook-ceph-csi-drivers
argocd app sync node-feature-discovery
argocd app sync prometheus-stack
argocd app sync smartmon-exporter
```

- [ ] **Step 3: Watch the CSI rollout to completion**

Editing the `Driver` CR makes ceph-csi-operator update the nodeplugin DaemonSets. Existing mounts survive; new attach/mount operations fail briefly.

```bash
kubectl -n rook-ceph rollout status ds/rook-ceph.rbd.csi.ceph.com-nodeplugin --timeout=5m
kubectl -n rook-ceph rollout status ds/rook-ceph.cephfs.csi.ceph.com-nodeplugin --timeout=5m
```

Expected: both roll out successfully.

- [ ] **Step 4: Verify nv1 is now covered**

```bash
kubectl get ds -A -o json | jq -r '.items[]
  | select(.metadata.name | test("nodeplugin|node-feature-discovery-worker|metrics-proxy"))
  | "\(.metadata.namespace)/\(.metadata.name) desired=\(.status.desiredNumberScheduled) ready=\(.status.numberReady)"'
kubectl get csinode nv1 -o jsonpath='{range .spec.drivers[*]}{.name}{"\n"}{end}'
```

Expected: every listed DaemonSet reports `desired=4` with `ready=4`, and `CSINode nv1` now lists `rook-ceph.rbd.csi.ceph.com` and `rook-ceph.cephfs.csi.ceph.com`.

This is the concrete proof the old `desired=3` was the taint, not a nodeSelector.

---

### Task 3: Rename the taint in the Talos template

**Files:**

- Modify: `provision/talos/templates/worker.yaml:59-60`

**Interfaces:**

- Consumes: nothing.
- Produces: generated config containing `nvidia.com/gpu: present:NoSchedule`. Task 4 applies it.

- [ ] **Step 1: Record the current node taint**

```bash
kubectl get node nv1 -o jsonpath='{.spec.taints}' | jq .
kubectl get node nv1 -o jsonpath='{.metadata.annotations.talos\.dev/owned-taints}'; echo
```

Expected now: one taint `{key: nv, value: NoSchedule, effect: NoSchedule}`, and **no** `owned-taints` annotation (empty output). This is why Talos will not remove it later.

- [ ] **Step 2: Rename the taint**

In `provision/talos/templates/worker.yaml`, replace:

```yaml
nodeTaints:
  nv: :NoSchedule
```

with:

```yaml
nodeTaints:
  # value:effect — parsed by Talos labels.ParseTaint (strings.Cut on ":")
  nvidia.com/gpu: present:NoSchedule
```

- [ ] **Step 3: Regenerate the node configs**

```bash
cd /workspaces/home-ops
task talos:generate
```

- [ ] **Step 4: Verify the generated taint parses to the intended value**

```bash
yq '.machine.nodeTaints' provision/talos/clusterconfig/home-nv1.yaml
```

Expected: `nvidia.com/gpu: present:NoSchedule`. By `ParseTaint`, `strings.Cut("present:NoSchedule", ":")` yields `value="present"`, `effect="NoSchedule"`.

- [ ] **Step 5: Diff the generated config against what is running on nv1**

nv1's stored config was last applied under Talos v1.12.7, so confirm the blast radius before applying.

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
SP=/tmp/claude-1000/-workspaces-home-ops/scratch && mkdir -p $SP
talosctl -n 192.168.48.5 get machineconfig v1alpha1 -o jsonpath='{.spec}' \
  | grep -vE '^\s*#' | grep -vE '^\s*$' > $SP/running.yaml
grep -vE '^\s*#' provision/talos/clusterconfig/home-nv1.yaml | grep -vE '^\s*$' > $SP/desired.yaml
diff -u $SP/running.yaml $SP/desired.yaml
```

Expected differences, and **only** these:

1. `install.image` tag `v1.12.7` → `v1.13.5` (config metadata; no reinstall)
2. `nodeTaints` `nv: :NoSchedule` → `nvidia.com/gpu: present:NoSchedule`
3. Network representation: running node has separate `HostnameConfig` + `LinkConfig` documents; generated config uses the deprecated inline `machine.network.interfaces`. Same address `192.168.48.5/22`, same gateway `192.168.50.1`, same MTU `1500`, same hostname `nv1`.

If anything else appears, **stop** and investigate before applying.

- [ ] **Step 6: Commit**

```bash
cd /workspaces/home-ops
npx --yes prettier --write provision/talos/templates/worker.yaml
git add provision/talos/templates/worker.yaml
git commit -m "feat(talos): rename nv1 taint to nvidia.com/gpu=present

The old 'nv' taint carried an accidental value of 'NoSchedule'. The new
key is self-documenting and matches the convention the NVIDIA GPU
Operator uses. Every pre-existing toleration is a bare operator: Exists,
so the rename is free for them; the explicit ones were widened first."
```

---

### Task 4: Apply the config to nv1

**⚠ CONFIRM** — mutates node state.

**Files:** none (cluster operations only).

**Interfaces:**

- Consumes: generated config from Task 3.
- Produces: nv1 carrying **both** taints. Task 5 removes the orphan.

- [ ] **Step 1: Re-run the diff from Task 3 Step 5**

Confirm nothing has changed since. Do not skip — the config may have been regenerated in between.

- [ ] **Step 2: ⚠ CONFIRM — apply**

Ask the user before running. Taint and label changes do not require a reboot; `-m auto` lets Talos decide.

```bash
cd /workspaces/home-ops
task talos:apply N=nv1
```

- [ ] **Step 3: Verify the node stays healthy**

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 health --wait-timeout=10m --server=false
kubectl get node nv1 -o wide
```

Expected: node `Ready`, still `v1.35.6`, still Talos `v1.13.5`, IP still `192.168.48.5`.

- [ ] **Step 4: Verify the expected double-taint**

```bash
kubectl get node nv1 -o jsonpath='{.spec.taints}' | jq .
kubectl get node nv1 -o jsonpath='{.metadata.annotations.talos\.dev/owned-taints}'; echo
```

Expected — and this is **not** a failure:

- `.spec.taints` contains **both** `nv=NoSchedule:NoSchedule` and `nvidia.com/gpu=present:NoSchedule`
- `owned-taints` now lists `["nvidia.com/gpu"]`

Talos added and took ownership of the new key. It cannot remove `nv`, because the removal pass only drops taints it owns.

- [ ] **Step 5: Verify nothing was evicted**

```bash
kubectl get pods -A --field-selector spec.nodeName=nv1
```

Expected: the same pods as before (cilium, cilium-envoy, alloy, node-exporter, smartmon-1) plus the newly added ceph nodeplugins, NFD worker and metrics-proxy. All `Running`.

---

### Task 5: Remove the orphaned `nv` taint

**⚠ CONFIRM** — mutates node state.

**Files:** none.

**Interfaces:**

- Consumes: the double-taint state from Task 4.
- Produces: nv1 carrying only `nvidia.com/gpu=present:NoSchedule`. Task 6 can then narrow tolerations.

- [ ] **Step 1: ⚠ CONFIRM — remove the orphan**

Ask the user before running.

```bash
kubectl taint nodes nv1 nv-
```

- [ ] **Step 2: Verify it is gone and stays gone**

```bash
kubectl get node nv1 -o jsonpath='{.spec.taints}' | jq .
sleep 60
kubectl get node nv1 -o jsonpath='{.spec.taints}' | jq .
```

Expected both times: exactly one taint, `nvidia.com/gpu=present:NoSchedule`. Talos has no code path that re-adds a key absent from the spec, so it must not return. If `nv` reappears, stop — an assumption in the design is wrong.

---

### Task 6: Narrow the tolerations to the new taint only

**Files:**

- Modify: `cluster/apps/core/rook-ceph/csi-drivers/values.yaml`
- Modify: `cluster/apps/system/node-feature-discovery/values.yaml`
- Modify: `cluster/apps/system/prometheus-stack/templates/metrics-proxy.yaml`
- Modify: `cluster/apps/system/smartmon-exporter/values.yaml`

**Interfaces:**

- Consumes: single-taint node state from Task 5.
- Produces: the final steady-state toleration set that Phase 1 builds on.

- [ ] **Step 1: Remove every transitional `nv` toleration**

In all four files, delete the entry:

```yaml
- key: nv
  operator: Equal
  value: NoSchedule
  effect: NoSchedule
```

leaving only the `nvidia.com/gpu` entry. In `metrics-proxy.yaml`, keep the `node-role.kubernetes.io/master` toleration.

- [ ] **Step 2: Verify the renders**

Re-run the two verification commands from Task 1 Steps 7 and 8. Expected: each DaemonSet/Driver now lists exactly one `nvidia.com/gpu` toleration (metrics-proxy keeps its master toleration as a second entry).

- [ ] **Step 3: Lint, commit, push, PR**

```bash
cd /workspaces/home-ops
npx --yes prettier --write \
  cluster/apps/core/rook-ceph/csi-drivers/values.yaml \
  cluster/apps/system/node-feature-discovery/values.yaml \
  cluster/apps/system/prometheus-stack/templates/metrics-proxy.yaml \
  cluster/apps/system/smartmon-exporter/values.yaml
task lint:yaml
git add -A
git commit -m "chore(nv1): drop transitional nv toleration

The nv taint is gone from the node; only nvidia.com/gpu=present remains."
git push
```

- [ ] **Step 4: ⚠ CONFIRM — sync and verify**

Ask the user, then sync the same four apps as Task 2 Step 2 and re-run Task 2 Step 4. Expected: all four DaemonSets still `desired=4 ready=4`. A drop back to 3 means a toleration was removed incorrectly.

---

### Task 7: Phase 0 acceptance

**Files:** none.

- [ ] **Step 1: Run the full acceptance sweep**

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
echo "--- node ---";       kubectl get node nv1 -o wide
echo "--- taints ---";     kubectl get node nv1 -o jsonpath='{.spec.taints}' | jq .
echo "--- csinode ---";    kubectl get csinode nv1 -o jsonpath='{range .spec.drivers[*]}{.name}{"\n"}{end}'
echo "--- daemonsets ---"; kubectl get ds -A -o json | jq -r '.items[]
  | select(.metadata.name | test("nodeplugin|node-feature-discovery-worker|metrics-proxy"))
  | "\(.metadata.name) \(.status.numberReady)/\(.status.desiredNumberScheduled)"'
echo "--- pods on nv1 ---"; kubectl get pods -A --field-selector spec.nodeName=nv1 --no-headers | awk '{print $2, $4}'
echo "--- ceph ---";       kubectl -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health}'; echo
```

Pass conditions, all required:

- nv1 `Ready`, Talos `v1.13.5`, k8s `v1.35.6`
- exactly one taint: `nvidia.com/gpu=present:NoSchedule`
- `CSINode nv1` lists both ceph drivers
- all four DaemonSets `4/4`
- smartmon-1 still `Running` on nv1
- Ceph `HEALTH_OK`

- [ ] **Step 2: Merge the PR**

Phase 0 is complete and independently shippable. **Stop here** and confirm with the user before starting Phase 1.

---

# PHASE 1 — Prove the GPU

Gated. If any check fails, stop and report; do not proceed to later tasks.

### Task 8: Measure the CPU baseline

Without this, "23 tok/s" has nothing to compare against. The Orin's 8 A78AE cores are not a bad CPU.

**Files:**

- Create: `docs/superpowers/plans/artifacts/2026-08-13-nv1-cpu-baseline.md`

**Interfaces:**

- Consumes: schedulable nv1 from Phase 0.
- Produces: recorded tok/s figures. Task 13's gate compares against them.

- [ ] **Step 1: ⚠ CONFIRM — run a throwaway CPU ollama pod on nv1**

Ask the user first. This pod is deleted in Step 4.

```bash
kubectl -n default run ollama-cpu-baseline \
  --image=ollama/ollama:0.20.5 --restart=Never \
  --overrides='{
    "spec": {
      "nodeSelector": {"kubernetes.io/hostname": "nv1"},
      "tolerations": [{"key":"nvidia.com/gpu","operator":"Equal","value":"present","effect":"NoSchedule"}],
      "containers": [{
        "name":"ollama","image":"ollama/ollama:0.20.5",
        "resources":{"requests":{"memory":"2Gi"},"limits":{"memory":"13Gi"}}
      }]
    }
  }'
kubectl -n default wait --for=condition=Ready pod/ollama-cpu-baseline --timeout=5m
```

- [ ] **Step 2: Benchmark two models**

```bash
for m in qwen2.5:0.5b qwen3.5:9b; do
  echo "=== $m ==="
  kubectl -n default exec ollama-cpu-baseline -- ollama pull "$m"
  kubectl -n default exec ollama-cpu-baseline -- \
    ollama run "$m" --verbose "Write a haiku about storage." 2>&1 | tail -8
done
```

Record the `eval rate` line (tokens/s) for each.

- [ ] **Step 3: Write the baseline artifact**

Create `docs/superpowers/plans/artifacts/2026-08-13-nv1-cpu-baseline.md` containing, for each model: model name, `eval rate` tok/s, `prompt eval rate` tok/s, and the date. State plainly that these are CPU-only figures on nv1.

- [ ] **Step 4: ⚠ CONFIRM — tear down**

```bash
kubectl -n default delete pod ollama-cpu-baseline
```

- [ ] **Step 5: Commit**

```bash
cd /workspaces/home-ops
git checkout -b feat/jetson-gpu
git add docs/superpowers/plans/artifacts/2026-08-13-nv1-cpu-baseline.md
git commit -m "docs(jetson): record nv1 CPU inference baseline"
```

---

### Task 9: Pin nv1's Talos version and add the GPU node config

**Files:**

- Modify: `provision/talos/nodes/nv1.yaml`
- Modify: `provision/talos/nodes.yaml`
- Modify: `.taskfiles/talos/Taskfile.yaml:209-220`

**Interfaces:**

- Consumes: nothing from Task 8.
- Produces: a generated `home-nv1.yaml` whose `machine.install.image` is the custom installer. Task 10 feeds that image to `talosctl upgrade`.

- [ ] **Step 1: Record why the Taskfile guard must change**

`talos:upgrade` derives `TALOS_IMAGE` from the node's generated config, so the custom installer is picked up for free. But its idempotency guard compares against the **global** `TALOS_VERSION`:

```yaml
status:
  - talosctl version --nodes {{.NODE}} --short | grep -q 'Tag.*{{ .TALOS_VERSION }}'
```

With the global at `v1.13.5` and nv1 pinned at `v1.13.0`, this never matches, so `task talos:upgrade:all` would reinstall nv1 on **every run**.

- [ ] **Step 2: Add a per-node version override to `nodes.yaml`**

```yaml
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
  - name: mc2
    ip: 192.168.48.3
    type: controlplane
  - name: mc3
    ip: 192.168.48.4
    type: controlplane
  - name: nv1
    ip: 192.168.48.5
    type: worker
    # Pinned: the GPU extension is ABI-bound to kernel 6.18.24.
    # Remove this line only together with a rebuilt installer image.
    talosVersion: v1.13.0
```

**Renovate safety — verified, no config change needed.** A Talos bump on nv1 without a matching rebuilt extension would leave the node GPU-less or unbootable. Renovate's `kubernetes`, `helm-values` and `argocd` managers are all scoped `fileMatch: ["cluster/.+\\.ya?ml$"]` (`.github/renovate/managers.json5`), and `provision/talos/**` is outside that scope with no `# renovate:` comment in `nodes.yaml` or `nodes/nv1.yaml`. So neither the pin nor the custom installer reference is visible to Renovate. Confirm this still holds:

```bash
cd /workspaces/home-ops
grep -rn "renovate:" provision/talos/ || echo "OK: no renovate annotations under provision/talos"
yq '.kubernetes.fileMatch, .["helm-values"].fileMatch, .argocd.fileMatch' .github/renovate/managers.json5
```

Expected: no annotations under `provision/talos`, and every `fileMatch` limited to `cluster/`.

- [ ] **Step 3: Resolve the version per node in the Taskfile**

In `.taskfiles/talos/Taskfile.yaml`, inside the `upgrade:` task's `vars:` block, add `NODE_TALOS_VERSION` alongside the existing `NODE`, `FILE`, `TALOS_IMAGE` and `FORCE` vars:

```yaml
NODE_TALOS_VERSION:
  sh: yq '.nodes[] | select(.name == "{{ .N }}") | .talosVersion // "{{ .TALOS_VERSION }}"' < {{.TALOS_DIR}}/nodes.yaml
```

Then change the `status:` guard to use it:

```yaml
status:
  - $([ "{{ .FORCE }}" = "false" ] && talosctl version --nodes {{ .NODE }} --short | grep -q 'Tag.*{{ .NODE_TALOS_VERSION }}' || return 1)
```

- [ ] **Step 4: Verify the override resolves correctly**

```bash
cd /workspaces/home-ops/provision/talos
for n in mc1 nv1; do
  printf "%s -> " $n
  yq ".nodes[] | select(.name == \"$n\") | .talosVersion // \"v1.13.5\"" < nodes.yaml
done
```

Expected: `mc1 -> v1.13.5`, `nv1 -> v1.13.0`.

- [ ] **Step 5: Add the GPU config to `nodes/nv1.yaml`**

Append to the existing `machine:` block (keeping `network:` exactly as it is):

```yaml
machine:
  network:
    hostname: nv1
    interfaces:
      - interface: enP8p1s0
        addresses:
          - 192.168.48.5/22
        mtu: 1500
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.50.1

  install:
    image: ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim

  kernel:
    modules:
      # OE4T host1x stack — prerequisite for all GPU modules
      - name: host1x
      - name: host1x_fence
      - name: host1x_nvhost
      # OE4T DRM stack — creates /dev/dri/renderD128, required for CUDA
      - name: tegra_drm
      # GPU memory + bandwidth
      - name: nvmap
      - name: mc_utils
      # Main CUDA driver (GA10B / Ampere)
      - name: nvgpu
      # GPU frequency scaling governor
      - name: governor_pod_scaling

  nodeLabels:
    accelerator: jetson-orin
    nvidia.com/gpu.type: igpu

  files:
    # Talos builds containerd with CDI disabled, and op:overwrite requires the
    # file to pre-exist — so CDI is enabled inline here rather than as a new
    # conf.d drop-in. Content below is nv1's current containerd.toml verbatim
    # plus the CDI block. Re-diff against the live file on every Talos upgrade.
    - path: /etc/cri/containerd.toml
      op: overwrite
      permissions: 0o644
      content: |
        version = 3

        disabled_plugins = [
            "io.containerd.differ.v1.erofs",
            "io.containerd.internal.v1.tracing",
            "io.containerd.snapshotter.v1.blockfile",
            "io.containerd.snapshotter.v1.erofs",
            "io.containerd.ttrpc.v1.otelttrpc",
            "io.containerd.tracing.processor.v1.otlp",
        ]

        imports = [
            "/etc/cri/conf.d/cri.toml",
        ]

        [debug]
        level = "info"
        format = "json"

        [plugins."io.containerd.cri.v1.runtime"]
          enable_cdi = true
          cdi_spec_dirs = ["/var/run/cdi"]
```

- [ ] **Step 6: Confirm the containerd content still matches the live file**

The embedded copy must match what Talos ships, or the overwrite silently drops Talos-managed settings.

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
SP=/tmp/claude-1000/-workspaces-home-ops/scratch && mkdir -p $SP
talosctl -n 192.168.48.5 read /etc/cri/containerd.toml > $SP/live.toml
yq '.machine.files[] | select(.path == "/etc/cri/containerd.toml") | .content' \
  provision/talos/nodes/nv1.yaml > $SP/planned.toml
diff <(grep -vE '^\s*$' $SP/live.toml) <(grep -vE '^\s*$' $SP/planned.toml)
```

Expected: the **only** added lines are the three CDI lines. Any other difference means Talos changed its template — reconcile before continuing.

- [ ] **Step 7: Regenerate and verify the merge did not clobber the containerd drop-in**

```bash
cd /workspaces/home-ops
task talos:generate
yq '.machine.files[].path' provision/talos/clusterconfig/home-nv1.yaml
yq '.machine.install.image' provision/talos/clusterconfig/home-nv1.yaml
yq '.machine.kernel.modules[].name' provision/talos/clusterconfig/home-nv1.yaml
```

Expected:

- **both** `/etc/cri/conf.d/20-customization.part` (from the worker template) and `/etc/cri/containerd.toml` (from the node patch) — `talosctl machineconfig patch` merges `machine.files`
- image is the custom installer
- all eight modules, in the order listed

- [ ] **Step 8: Commit**

```bash
cd /workspaces/home-ops
npx --yes prettier --write provision/talos/nodes/nv1.yaml provision/talos/nodes.yaml
task lint:yaml
git add provision/talos/nodes/nv1.yaml provision/talos/nodes.yaml .taskfiles/talos/Taskfile.yaml
git commit -m "feat(nv1): pin Talos v1.13.0 and add Jetson GPU node config

Points nv1 at the upstream OE4T custom installer, declares the GPU
kernel module load order, labels the node, and enables CDI in
containerd. Adds an optional per-node talosVersion so upgrade:all does
not reinstall nv1 on every run while it is pinned behind the cluster."
```

---

### Task 10: Install the custom UKI — gate checks 1–4

**⚠ CONFIRM** — this replaces nv1's boot image and is the highest-risk step in the plan. A bad UKI needs a USB rescue (physical access confirmed available).

**Files:** none.

**Interfaces:**

- Consumes: generated config from Task 9.
- Produces: `/dev/dri/renderD128` and a CDI-enabled containerd. Task 11's DaemonSets depend on both.

- [ ] **Step 1: Record the pre-state**

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 ls /dev/dri 2>&1        # expect: no such file or directory
talosctl -n 192.168.48.5 read /proc/modules | grep -E "nvgpu|tegra|host1x"
```

Expected now: `/dev/dri` missing; `tegra_drm` and `host1x` present but **no** `nvgpu`. This is the bug being fixed.

- [ ] **Step 2: ⚠ CONFIRM — apply the config, then upgrade**

Ask the user. Note this is a Talos **downgrade** (v1.13.5 → v1.13.0); add `--force` only if `talosctl upgrade` refuses.

```bash
cd /workspaces/home-ops
task talos:apply N=nv1
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 upgrade \
  --image ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim \
  --wait=false
```

- [ ] **Step 3: Gate check 1 — node returns**

```bash
talosctl -n 192.168.48.5 health --wait-timeout=15m --server=false
kubectl get node nv1 -o wide
```

Pass: node `Ready`, `Talos (v1.13.0)`, kernel `6.18.24-talos`.

**Fail → stop.** Recovery: USB reflash, or revert `nodes/nv1.yaml` to the factory installer and re-upgrade.

- [ ] **Step 4: Gate check 2 — nvgpu loaded**

```bash
talosctl -n 192.168.48.5 read /proc/modules | grep -E "nvgpu|tegra_drm|host1x|nvmap"
```

Pass: `nvgpu` present, alongside `host1x`, `tegra_drm`, `nvmap`.

- [ ] **Step 5: Gate check 3 — the render node exists**

```bash
talosctl -n 192.168.48.5 ls /dev/dri
```

Pass: `renderD128` listed. **This is the single most important check in the plan** — it is the exact thing that does not work today.

- [ ] **Step 6: Gate check 4 — CDI enabled in containerd**

```bash
talosctl -n 192.168.48.5 read /etc/cri/containerd.toml | tail -5
talosctl -n 192.168.48.5 read /etc/cri/conf.d/20-customization.part | head -3
```

Pass: the `enable_cdi = true` / `cdi_spec_dirs` block is present, **and** the customization drop-in still exists.

- [ ] **Step 7: Confirm the version pin behaves**

```bash
cd /workspaces/home-ops
task talos:upgrade N=nv1 --dry-run 2>&1 | tail -5
```

Pass: the task reports nv1 already at its pinned version and skips. If it wants to upgrade, the Task 9 Step 3 guard is wrong.

---

### Task 11: Deploy the GPU stack — gate checks 5–6

**Files:**

- Create: `cluster/apps/system/nvidia/app-config.yaml`
- Create: `cluster/apps/system/nvidia/kustomization.yaml`
- Create: `cluster/apps/system/nvidia/resources/cdi-setup.yaml`
- Create: `cluster/apps/system/nvidia/resources/device-plugin.yaml`
- Create: `cluster/apps/system/nvidia/resources/power-mode.yaml`

**Interfaces:**

- Consumes: `/dev/dri/renderD128`, CDI-enabled containerd, and the `accelerator=jetson-orin` label from Task 10.
- Produces: `nvidia.com/gpu: 1` in nv1's allocatable. Task 13's ollama requests it.

- [ ] **Step 1: Vendor the upstream manifests**

```bash
cd /tmp/claude-1000/-workspaces-home-ops/scratch
rm -rf tjo && git clone --depth 1 https://github.com/schwankner/talos-jetson-orin.git tjo
mkdir -p /workspaces/home-ops/cluster/apps/system/nvidia/resources
cp -f tjo/manifests/gpu/cdi-setup.yaml tjo/manifests/gpu/device-plugin.yaml \
      tjo/manifests/gpu/power-mode.yaml \
      /workspaces/home-ops/cluster/apps/system/nvidia/resources/
```

- [ ] **Step 2: Add the mandatory nodeSelector to all three DaemonSets**

Upstream carries `tolerations: [{operator: Exists}]` and **no nodeSelector**, assuming a single-node Jetson cluster. Unmodified, these Tegra-specific privileged pods schedule onto mc1–mc3 and crash-loop against amd64 hardware with no `/dev/nvmap`.

In each of the three files, add to the DaemonSet pod spec, as a sibling of `tolerations:`:

```yaml
nodeSelector:
  accelerator: jetson-orin
```

The blanket `operator: Exists` toleration already covers the `nvidia.com/gpu` taint, so tolerations need no change.

- [ ] **Step 3: Add sync-wave annotations for ordering**

The device plugin must not advertise `nvidia.com/gpu` before the CDI spec exists. Add to each DaemonSet's `metadata.annotations`:

- `resources/cdi-setup.yaml` → `argocd.argoproj.io/sync-wave: "1"`
- `resources/device-plugin.yaml` → `argocd.argoproj.io/sync-wave: "2"`
- `resources/power-mode.yaml` → `argocd.argoproj.io/sync-wave: "3"`

- [ ] **Step 4: Digest-pin the three images**

These files live under `cluster/`, which Renovate's `kubernetes` manager watches (`fileMatch: ["cluster/.+\\.ya?ml$"]`), so the images must follow the repo's `tag@sha256:` convention rather than floating tags.

Resolve each digest for **linux/arm64** — these run only on nv1:

```bash
for ref in busybox:1.36 ubuntu:22.04 ghcr.io/schwankner/jetson-device-plugin:v1.0.0; do
  printf "%s -> " "$ref"
  docker buildx imagetools inspect "$ref" --format '{{json .Manifest}}' 2>/dev/null \
    | jq -r '.digest' || echo "(resolve manually)"
done
```

Then rewrite each `image:` line in the form `repo:tag@sha256:<digest>`, e.g.:

```yaml
image: busybox:1.36@sha256:<digest>
```

Apply to: `busybox:1.36` in `power-mode.yaml` and `cdi-setup.yaml`, `ubuntu:22.04` in `cdi-setup.yaml`, and `ghcr.io/schwankner/jetson-device-plugin:v1.0.0` in `device-plugin.yaml`.

- [ ] **Step 5: Write the kustomization**

Create `cluster/apps/system/nvidia/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/SchemaStore/schemastore/master/src/schemas/json/kustomization.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: nvidia-system
resources:
  - resources/cdi-setup.yaml
  - resources/device-plugin.yaml
  - resources/power-mode.yaml
```

The three upstream files each declare the `nvidia-system` Namespace; delete the duplicate `Namespace` objects from `device-plugin.yaml` and `power-mode.yaml`, keeping the one in `cdi-setup.yaml`.

- [ ] **Step 6: Write the app-config**

Create `cluster/apps/system/nvidia/app-config.yaml`, following the `cluster/apps/system/intel/app-config.yaml` precedent:

```yaml
- enabled: "true"
  namespace: nvidia-system
  syncWave: "2"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  managedNamespaceMetadata:
    labels:
      pod-security.kubernetes.io/enforce: privileged
```

- [ ] **Step 7: Verify the render before applying anything**

```bash
cd /workspaces/home-ops/cluster/apps/system/nvidia
kubectl kustomize . > /tmp/claude-1000/-workspaces-home-ops/scratch/nvidia-rendered.yaml
yq 'select(.kind=="DaemonSet") | {"n": .metadata.name, "ns": .metadata.namespace,
    "sel": .spec.template.spec.nodeSelector,
    "wave": .metadata.annotations["argocd.argoproj.io/sync-wave"]}' \
  /tmp/claude-1000/-workspaces-home-ops/scratch/nvidia-rendered.yaml
yq 'select(.kind=="Namespace") | .metadata.name' \
  /tmp/claude-1000/-workspaces-home-ops/scratch/nvidia-rendered.yaml
```

Expected: three DaemonSets, each in `nvidia-system`, each with `nodeSelector: {accelerator: jetson-orin}`, waves 1/2/3; exactly **one** Namespace.

- [ ] **Step 8: Commit, push, PR, and ⚠ CONFIRM sync**

```bash
cd /workspaces/home-ops
npx --yes prettier --write cluster/apps/system/nvidia/**/*.yaml cluster/apps/system/nvidia/*.yaml
task lint:yaml
git add cluster/apps/system/nvidia
git commit -m "feat(nvidia): add Jetson GPU stack (cdi-setup, device-plugin, power-mode)

Vendored from schwankner/talos-jetson-orin. Adds the nodeSelector
upstream omits — without it these Tegra-specific privileged pods land
on the amd64 control planes and crash-loop."
git push
```

Then ask the user before syncing the new `nvidia` app.

- [ ] **Step 9: Gate check 5 — the CDI spec is written**

```bash
kubectl -n nvidia-system get pods -o wide
kubectl -n nvidia-system logs ds/nvidia-cdi-setup --all-containers --tail=50
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 ls /var/run/cdi
```

Pass: all three DaemonSets have exactly **one** pod each, on nv1, `Running`; `/var/run/cdi/nvidia-jetson.yaml` exists.

Note: cdi-setup downloads JetPack `.deb`s from `repo.download.nvidia.com` on every pod start. A failure here may be network, not the port.

- [ ] **Step 10: Gate check 6 — the GPU is advertised**

```bash
kubectl get node nv1 -o jsonpath='{.status.allocatable}' | jq '."nvidia.com/gpu"'
```

Pass: `"1"`. **Fail → stop**; the device plugin is not registering.

- [ ] **Step 11: Confirm nothing landed on the control planes**

```bash
kubectl -n nvidia-system get pods -o wide --no-headers | awk '{print $7}' | sort -u
```

Pass: `nv1` only.

---

### Task 12: CUDA smoke test — gate check 7

This is where upstream's hardest bugs lived (their Bugs 6, 14, 19). Most likely failure point in the plan.

**Files:** none.

**Interfaces:**

- Consumes: `nvidia.com/gpu: 1` from Task 11.
- Produces: proof CUDA initialises. Task 13 is pointless without it.

- [ ] **Step 1: ⚠ CONFIRM — run a CUDA probe pod**

```bash
kubectl -n default run cuda-smoke --restart=Never --image=ollama/ollama:0.20.5 \
  --overrides='{
    "spec": {
      "nodeSelector": {"accelerator": "jetson-orin"},
      "tolerations": [{"key":"nvidia.com/gpu","operator":"Equal","value":"present","effect":"NoSchedule"}],
      "containers": [{
        "name":"cuda","image":"ollama/ollama:0.20.5","command":["sleep","600"],
        "env":[{"name":"JETSON_JETPACK","value":"6"}],
        "resources":{"limits":{"nvidia.com/gpu":"1","memory":"4Gi"}}
      }]
    }
  }'
kubectl -n default wait --for=condition=Ready pod/cuda-smoke --timeout=5m
```

- [ ] **Step 2: Gate check 7 — devices and libraries are injected**

```bash
kubectl -n default exec cuda-smoke -- ls -l /dev/dri /dev/nvmap /dev/nvhost-ctrl
kubectl -n default exec cuda-smoke -- sh -c 'echo $LD_LIBRARY_PATH'
kubectl -n default exec cuda-smoke -- sh -c 'ls /usr/lib/aarch64-linux-gnu/tegra 2>/dev/null | head'
```

Pass: `/dev/dri/renderD128`, `/dev/nvmap` and `/dev/nvhost-ctrl` all present inside the container; `LD_LIBRARY_PATH` includes a tegra path. CDI injected these — the pod is **not** privileged.

- [ ] **Step 3: Gate check 7b — CUDA actually initialises**

```bash
kubectl -n default exec cuda-smoke -- sh -c 'ollama serve & sleep 10; ollama pull qwen2.5:0.5b >/dev/null 2>&1; ollama run qwen2.5:0.5b --verbose "hi" 2>&1 | tail -12'
kubectl -n default logs cuda-smoke | grep -iE "cuda|gpu|error 801|error 999|library" | tail -20
```

Pass: logs show a CUDA/JetPack6 backend in use, **no CUDA error 801 and no error 999**, and inference completes.

**Fail → stop and report.** Do not proceed to Task 13. Error 801/999 means the port does not work on this unit; the whole effort ends here and Task 15 reverts.

- [ ] **Step 4: ⚠ CONFIRM — tear down**

```bash
kubectl -n default delete pod cuda-smoke
```

---

### Task 13: Repoint ollama to the Jetson — gate check 8

**Files:**

- Modify: `cluster/apps/ai/ollama/values.yaml`
- Modify: `cluster/apps/ai/ollama/app-config.yaml`

**Interfaces:**

- Consumes: working CUDA from Task 12; ceph-block on nv1 from Phase 0 Task 2.
- Produces: the final workload.

- [ ] **Step 1: Rewrite `values.yaml`**

nv1's allocatable is 14.8Gi shared between CPU and GPU, so the current `16Gi` limit would make the pod unschedulable, and `gemma4:26b` (~16GB+) and `deepcoder:14b` (~9GB, no headroom) cannot run. `OLLAMA_VULKAN` is the Intel path and must go. `JETSON_JETPACK=6` is what activates `cuda_jetpack6/libggml-cuda.so`; **without it the container serves on CPU while looking healthy.**

```yaml
ollama:
  image:
    tag: "0.20.5" # >=0.20.5 for the JetPack 6 CUDA backend (upstream Bug 19)
  ollama:
    models:
      pull:
        - qwen3.5:9b
        - nomic-embed-text
  extraEnv:
    - name: JETSON_JETPACK
      value: "6"
    - name: OLLAMA_KV_CACHE_TYPE
      value: "q4_0"
    - name: OLLAMA_NUM_PARALLEL
      value: "1"
    - name: OLLAMA_NUM_GPU
      value: "-1"
    - name: OLLAMA_FLASH_ATTENTION
      value: "1"
    - name: OLLAMA_CONTEXT_LENGTH
      value: "16384"
  nodeSelector:
    accelerator: jetson-orin
  tolerations:
    - key: nvidia.com/gpu
      operator: Equal
      value: present
      effect: NoSchedule
  service:
    type: ClusterIP
  ingress:
    enabled: false
  persistentVolume:
    enabled: true
    size: "20Gi"
  resources:
    limits:
      nvidia.com/gpu: 1
      memory: 13Gi
    requests:
      nvidia.com/gpu: 1
      cpu: 100m
      memory: 8Gi
```

- [ ] **Step 2: Enable the app**

In `cluster/apps/ai/ollama/app-config.yaml`, change `enabled: "false"` to `enabled: "true"`. Leave every other field unchanged.

- [ ] **Step 3: Verify the render**

```bash
cd /workspaces/home-ops/cluster/apps/ai/ollama
helm dependency update . >/dev/null 2>&1
helm template ollama . -f values.yaml \
  | yq 'select(.kind=="StatefulSet" or .kind=="Deployment")
        | {"sel": .spec.template.spec.nodeSelector,
           "tol": .spec.template.spec.tolerations,
           "res": .spec.template.spec.containers[0].resources,
           "env": [.spec.template.spec.containers[0].env[] | select(.name=="JETSON_JETPACK" or .name=="OLLAMA_VULKAN")]}'
```

Expected: nodeSelector `accelerator: jetson-orin`; the `nvidia.com/gpu` toleration; `nvidia.com/gpu: 1` in both limits and requests; memory limit `13Gi`; `JETSON_JETPACK=6` present and `OLLAMA_VULKAN` **absent**.

- [ ] **Step 4: Commit, push, PR, and ⚠ CONFIRM sync**

```bash
cd /workspaces/home-ops
npx --yes prettier --write cluster/apps/ai/ollama/values.yaml cluster/apps/ai/ollama/app-config.yaml
task lint:yaml
git add cluster/apps/ai/ollama
git commit -m "feat(ollama): run on the Jetson iGPU instead of Intel i915

Drops gemma4:26b and deepcoder:14b, which cannot fit in nv1's 14.8Gi of
memory shared between CPU and GPU, and lowers the limit from 16Gi (above
node allocatable, so unschedulable) to 13Gi. Adds JETSON_JETPACK=6,
without which ollama silently serves on CPU."
git push
```

Then ask before syncing.

- [ ] **Step 5: Verify the pod runs and its PVC binds**

```bash
kubectl -n ollama get pods -o wide
kubectl -n ollama get pvc
kubectl -n ollama logs -l app.kubernetes.io/name=ollama --tail=50 | grep -iE "cuda|gpu|jetpack"
```

Pass: pod `Running` on nv1; PVC `Bound` on `ceph-block` (this is what Phase 0 Task 2 enabled); logs show the CUDA JetPack 6 backend.

- [ ] **Step 6: Gate check 8 — beat the CPU baseline by 2x**

```bash
kubectl -n ollama exec deploy/ollama -- ollama run qwen3.5:9b --verbose "Write a haiku about storage." 2>&1 | tail -8
```

Compare the `eval rate` against `docs/superpowers/plans/artifacts/2026-08-13-nv1-cpu-baseline.md`.

- **>= 2x baseline** → pass. Phase 1 succeeds; Phase 2 is worth designing.
- **1x–2x** → **no-go for Phase 2.** Record the numbers and ask the user whether to keep or revert the Phase 1 state; it is independently revertible.
- **< 1x** → the GPU path is not engaging. Check `JETSON_JETPACK` reached the container before concluding anything.

- [ ] **Step 7: Record the result**

Append the GPU figures to the baseline artifact alongside the CPU numbers, with the measured ratio, and commit.

---

### Task 14: Documentation

**Files:**

- Modify: `docs/superpowers/specs/2026-08-13-jetson-igpu-design.md`
- Modify: `provision/talos/README.md`

- [ ] **Step 1: Record outcomes in the spec**

Add a short "Outcome" section: which gate checks passed, measured tok/s, and the go/no-go decision on Phase 2.

- [ ] **Step 2: Document the per-node version pin**

In `provision/talos/README.md`, under "Adding a new node", document the optional `talosVersion` key in `nodes.yaml`: what it does, that it excludes the node from the global version, and that removing it requires a matching rebuilt installer image.

- [ ] **Step 3: Commit and push**

```bash
cd /workspaces/home-ops
npx --yes prettier --write docs/superpowers/specs/2026-08-13-jetson-igpu-design.md provision/talos/README.md
git add -A && git commit -m "docs(jetson): record Phase 1 outcome and per-node talosVersion"
git push
```

---

### Task 15: Rollback procedure (reference only — run only if a gate fails)

Do not execute as part of a successful run.

- [ ] **Step 1: Revert the node to the factory installer**

Set `machine.install.image` in `provision/talos/nodes/nv1.yaml` back to:

```yaml
image: factory.talos.dev/metal-installer/185266ddb5b9bb403289377302af1fd44575fe7f2864db5a7a96858837ccbcba:${TALOS_VERSION}
```

Remove the `kernel.modules` block, the `nvidia.com/gpu.type` and `accelerator` labels, and the `/etc/cri/containerd.toml` file entry. Remove `talosVersion: v1.13.0` from `nodes.yaml`.

- [ ] **Step 2: ⚠ CONFIRM — regenerate and upgrade back**

```bash
cd /workspaces/home-ops
task talos:generate
task talos:upgrade N=nv1 FORCE=true
```

- [ ] **Step 3: Disable the GPU stack and ollama**

Set `enabled: "false"` in `cluster/apps/system/nvidia/app-config.yaml` and `cluster/apps/ai/ollama/app-config.yaml`, commit, and sync.

- [ ] **Step 4: Verify**

nv1 back on Talos v1.13.5, `Ready`, one taint (`nvidia.com/gpu=present:NoSchedule`), no `nvidia-system` pods.

Note: Phase 0 is **not** reverted. The taint rename, toleration changes and Ceph access are independent of the GPU work and should be kept.
