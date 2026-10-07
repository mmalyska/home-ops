---
name: reference-talos-workload-isolation
description: "Talos 1.14 SecurityProfileConfig workloadIsolation (sandboxd) is off here; the v1.14 contract bump turns it on by default, switching needs a node reboot"
metadata:
  type: reference
---

`SecurityProfileConfig` `workloadIsolation: true` runs CRI, the kubelet and all pods in a separate PID and mount
namespace (`sandboxd`, `talosctl logs sandboxd`) instead of `machined`'s. Researched 2026-10-07 (Talos 1.14 docs and
v1.14.2 source); details and the test plan are in the SecurityProfileConfig bullet of `.plans/TODO.md`.

**Why it matters:**
- The nodes have no such document, so isolation is off. A missing document means off and upgrades change nothing.
- `talosctl gen config` emits it with `workloadIsolation: true` only for the v1.14 contract. We pin `TALOS_CONTRACT`
  v1.13 (`provision/talos/scripts/lib.sh`), so **bumping the contract would enable isolation on the next apply and reboot
  unless a patch sets it explicitly first**.
- The setting is read when the service starts: enabling or disabling needs a node reboot, not a live apply.
- v1.14.0 had a boot bug (CRI restart loop, siderolabs/talos#14374); fixed in v1.14.2, which the nodes run.

**How to apply:** before the contract bump, decide and write the document in a patch (true or false). Live check
2026-10-07: nv1 runs Talos **v1.14.0** (still has the boot bug), mc1-mc3 run v1.14.2, so test on **mc3 first** (a normal
rolling reboot, etcd is a host service) and nv1 last, only after upgrading it to v1.14.2 or later. Workloads most likely to
notice: Ceph RBD/CephFS CSI (hostPID, bidirectional `/var/lib/kubelet` mounts), multus, cilium `mount-bpf-fs`,
node-exporter (hostPID), `nvidia-cdi-setup` and the in-tree NFS mounts.

Related: [[reference-talos-taint-noderestriction]] (another Talos 1.14 behaviour that bites at change time).
