---
name: reference-talos-taint-noderestriction
description: "Talos cannot add, change or remove a taint on an already-registered WORKER node — NodeRestriction blocks it (official docs say use kubectl taint as admin); control planes use admin creds; procedure is in the talos-node-taints skill"
metadata:
  node_type: memory
  type: reference
  originSessionId: 912ddcce-2b51-46ef-a4eb-4ec3f8a7515d
  modified: 2026-08-13T11:40:51.597Z
---

Changing `machine.nodeTaints` in Talos config does **not** take effect on a node
that is already registered in the cluster. Verified on nv1 during the Jetson
iGPU work (2026-08-13). Researched 2026-10-07: this is the **officially documented** behaviour
(Talos docs "Node Labels and Node Taints"; siderolabs/talos#13443, #8193 closed as Kubernetes behaviour), there is
no Talos-side fix. Applies to **workers** only: in v1.14.2 `NodeApplyController` uses an admin-credential client on
control planes (source-read, not tested live). A rejected taint change also blocks label/annotation changes (one update).
The procedure now lives in the repo skill `.claude/skills/talos-node-taints/SKILL.md`.

**Why:** the apiserver runs with `--enable-admission-plugins=NodeRestriction`.
Talos's `NodeApplyController` acts with the kubelet's credentials, and
NodeRestriction only permits a kubelet to set taints **at registration time**.
Any later add or change is rejected. `NodeTaintSpec` will show the desired
taint while `Node.spec.taints` silently disagrees, with no loud error.

**A second, independent blocker** (`ApplyTaints` in
`internal/app/machined/pkg/controllers/k8s/node_apply.go`): Talos matches taints
by **key** and tracks ownership in the `talos.dev/owned-taints` annotation. A
taint whose key exists but is *not owned* and whose value/effect differ from the
spec is skipped permanently (`"skipping taint update, taint is not owned"`). The
removal pass only drops taints Talos owns, so an unowned stale taint never goes
away on its own.

**Fix — one-time, using admin credentials, not the kubelet's:**

```sh
kubectl taint nodes <node> <key>=<value>:<effect>   # add the new one
kubectl taint nodes <node> <oldkey>-                # remove any stale one
```

Afterwards Talos hits the "not owned, but value and effect already equal the
spec" branch, **adopts** the taint into `talos.dev/owned-taints`, and maintains
it from then on. So this is bootstrap friction, not ongoing drift — do not plan
recurring manual intervention.

**Planning implications:**

- Widen tolerations to cover both old and new taint *before* renaming, then
  narrow afterwards. `NoSchedule` does not evict running pods, but a pod that
  restarts mid-transition would be unschedulable.
- Verify with `kubectl get node <n> -o jsonpath='{.spec.taints}'` and the
  `talos.dev/owned-taints` annotation. Never assume the config was applied.
- A fresh node registering with the config in place needs none of this.

Same shape as [[feedback-deployment-strategy-patch]]: a live-object `kubectl`
action is required before the declarative source of truth can take over.
Related: [[feedback-talosctl-config]], [[feedback-cluster-access-rules]].
