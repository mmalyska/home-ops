---
name: reference-talos-workload-isolation
description: "Talos 1.14 SecurityProfileConfig workloadIsolation (sandboxd) is on for all four nodes since 2026-10-07; the v1.14 contract bump turns it on by default, switching needs a node reboot"
metadata:
  type: reference
---

`SecurityProfileConfig` `workloadIsolation: true` runs CRI, the kubelet and all pods in a separate PID and mount
namespace (`sandboxd`, `talosctl logs sandboxd`) instead of `machined`'s. Researched 2026-10-07 (Talos 1.14 docs and
v1.14.2 source); details and the test plan are in the SecurityProfileConfig bullet of `.plans/TODO.md`.

**Why it matters:**
- As of 2026-10-07 the repo carries the document for every node in `patches/all/65-security-profile.yaml` and isolation is running on all four nodes (rollout order mc3, nv1, mc2, mc1). A missing document means off and upgrades change nothing.
- `talosctl gen config` emits it with `workloadIsolation: true` only for the v1.14 contract. We pin `TALOS_CONTRACT`
  v1.13 (`provision/talos/scripts/lib.sh`), so **bumping the contract would enable isolation on the next apply and reboot
  unless a patch sets it explicitly first**.
- The setting is read when the service starts: enabling or disabling needs a node reboot, not a live apply.
- v1.14.0 had a boot bug (CRI restart loop, siderolabs/talos#14374); fixed in v1.14.2, which the nodes run.

**How it was rolled out (2026-10-07):** all nodes run v1.14.2 (the v1.14.0 boot bug no longer applies). mc3 was the pilot (a normal rolling reboot), the owner enabled **nv1 early** (clean first reboot, GPU stack intact at 26.2 tokens/s as before, red test passed, soak waived), then mc2 and mc1 with the same procedure: apply, cordon, drain, the owner reboots, uncordon, `node_health`, `isolation-check <node> on`, RBD and NFS test pods, red test. Ceph returns to HEALTH_OK about a minute after each reboot. The end state is `true` on all four nodes, no nv1 `false` override. To switch it off again, set `false` in `patches/all/65-security-profile.yaml` and repeat the procedure per node. Workloads most likely to
notice: Ceph RBD/CephFS CSI (hostPID, bidirectional `/var/lib/kubelet` mounts), multus, cilium `mount-bpf-fs`,
node-exporter (hostPID), `nvidia-cdi-setup` and the in-tree NFS mounts.

Related: [[reference-talos-taint-noderestriction]] (another Talos 1.14 behaviour that bites at change time).

**Red test result (mc3, 2026-10-07):** a privileged `hostPID` probe pod sees `machined` (PID 1 `init`), `apid` and 209
readable PID-1 fds on a non-isolated node (mc1), and on the isolated node (mc3) PID 1 is `sandboxd` with `init` and `apid`
invisible and 13 fds. **etcd is inside the sandbox** when isolation is on (`NSpid` `<host> <sandbox> 1`), contrary to the
first assumption, so the sandbox hides machined and apid but not etcd, and a `sandboxd` crash would restart a control
plane's etcd. Probe manifest and expected values: plan Task 3 Step 7b.

**State (2026-10-07):** isolation is ON on all four nodes, `task talos:diff` is clean everywhere. `scripts/isolation-check.sh <node>
[on|off]` proves a node's state; plan Task 3 Step 7b is the red-test probe. `task talos:node_health N=<node>` is the health gate.
Expect a few container restarts on a node's first boot (cephfs CSI plugin, oauth2-proxy, anything that needs the API or
a dependency before it is up) and Ceph HEALTH_WARN for about a minute: both settle by themselves. Draining a control
plane leaves its mon and OSD Pending until it returns, and pods do not move back on their own.
