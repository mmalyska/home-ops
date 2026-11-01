---
name: talos-node-taints
description: Use when adding, renaming, changing or removing a node taint (KubeNodeConfig `taints`) on a Talos node that is already in the cluster — covers why Talos cannot do it for workers (NodeRestriction), the kubectl procedure, ordering with tolerations, and how to verify. Trigger phrases - "node taint", "nodeTaints", "KubeNodeConfig taints", "is not allowed to modify taints", "NodeApplyController", "rename taint", "taint nv1", "nvidia.com/gpu taint".
user-invocable: false
origin: auto-extracted
---

# Changing Talos node taints on a registered node

**Extracted:** 2026-10-07 (research for the Jetson iGPU taint rename on nv1; Talos v1.14.2)

## The rule

A **worker** node cannot add, change or remove its own taints after it has joined the cluster. This is Kubernetes'
NodeRestriction admission plugin (always on in Talos, cannot be disabled), not a Talos bug. The Talos docs say so
explicitly ("Node Labels and Node Taints" guide: "After a node has joined the cluster, taints must be managed using a
cluster-admin identity: `kubectl taint ...`"), and siderolabs/talos#13443 and #8193 were answered the same way.
There is no Talos flag, `talosctl` command or RBAC binding that bypasses it. Do not look for one.

Where the config applies the taint: only at registration (a fresh node, or a node whose Node object was deleted
and re-registers). On a registered worker, a changed `KubeNodeConfig` `taints` reaches the `NodeTaintSpec` resource but never the Node.

Control planes are different in the source (v1.14.2, `NodeApplyController.getK8sClient`): a control-plane node uses an
admin-credential client, not the kubelet's, so NodeRestriction does not apply there. Read from the source, not tested live
here; the repo only has a taint on workers (`provision/talos/patches/worker/30-node-taints.yaml`, `nvidia.com/gpu=present:NoSchedule`, nv1 is the only worker).

## What it looks like when it is stuck

- `talosctl dmesg -n <node> | grep NodeApplyController` repeats `nodes "<n>" is forbidden: node "<n>" is not allowed to modify taints`.
- `talosctl get nodetaintspecs -n <node>` shows the desired taint, while `kubectl get node <n> -o jsonpath='{.spec.taints}'` shows the old one.
- **Label and annotation changes stall too:** taints, labels and annotations are applied in one update, so a rejected taint
  change blocks the rest until the live taint matches the spec.
- Removing a taint from the config is blocked the same way (the removal pass drops taints Talos owns, through the same forbidden update).

## Procedure (every step that touches the cluster needs the user's confirmation)

1. **Widen tolerations first** when renaming or replacing: the workloads must tolerate both the old and new taint before
   either changes. `NoSchedule` does not evict running pods, but a pod that restarts mid-change must still schedule.
   (For `NoExecute` taints plan the eviction.)
2. **Change the repo config** (`patches/worker/30-node-taints.yaml`), `task talos:generate`, `task talos:diff`; the diff should show only the taint.
3. **Change the live taint with admin credentials, before applying**, so the controller never errors:
   ```sh
   kubectl taint nodes <node> <newkey>=<value>:<effect>     # add / change (--overwrite to change an existing key)
   kubectl taint nodes <node> <oldkey>-                     # remove a stale key
   ```
4. **Apply the Talos config** (`task talos:apply`, live, no reboot). Talos finds the taint already equal to the spec and
   adopts it (adds the key to the `talos.dev/owned-taints` annotation); an equal-valued unowned taint is adopted, a different
   unowned taint with the same key is skipped for good (`skipping taint update, taint is not owned`), which is why step 3 must match the spec exactly (value and effect).
5. **Verify** (never assume):
   ```sh
   kubectl get node <node> -o jsonpath='{.spec.taints}{"\n"}{.metadata.annotations.talos\.dev/owned-taints}{"\n"}'
   talosctl --talosconfig provision/talos/clusterconfig/talosconfig -n <node> dmesg | grep NodeApplyController | tail   # no new "forbidden" lines
   task talos:diff -- <node>      # clean
   ```
6. **Narrow the tolerations** to the new taint.

Removing a taint: `kubectl taint nodes <node> <key>-` first, then remove it from the config and apply.

## Notes

- Equal-valued adoption means this is one-time friction per change, not ongoing drift. Do not plan recurring manual steps.
- A node that registers fresh with the config in place needs none of this (the kubelet sets the taints at registration).
- Same shape as other live-object-first cases: see the memory notes on the taint NodeRestriction and the Deployment strategy patch.
