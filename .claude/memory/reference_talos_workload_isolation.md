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
2026-10-07: mc1-mc3 run v1.14.2 and nv1 was upgraded to v1.14.2 the same day (the v1.14.0 boot bug no longer applies),
so test on **mc3 first** (a normal rolling reboot) and nv1 last, after it has soaked on v1.14.2. Workloads most likely to
notice: Ceph RBD/CephFS CSI (hostPID, bidirectional `/var/lib/kubelet` mounts), multus, cilium `mount-bpf-fs`,
node-exporter (hostPID), `nvidia-cdi-setup` and the in-tree NFS mounts.

Related: [[reference-talos-taint-noderestriction]] (another Talos 1.14 behaviour that bites at change time).

**Red test result (mc3, 2026-10-07):** a privileged `hostPID` probe pod sees `machined` (PID 1 `init`), `apid` and 209
readable PID-1 fds on a non-isolated node (mc1), and on the isolated node (mc3) PID 1 is `sandboxd` with `init` and `apid`
invisible and 13 fds. **etcd is inside the sandbox** when isolation is on (`NSpid` `<host> <sandbox> 1`), contrary to the
first assumption, so the sandbox hides machined and apid but not etcd, and a `sandboxd` crash would restart a control
plane's etcd. Probe manifest and expected values: plan Task 3 Step 7b.
