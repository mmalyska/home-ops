# Talos Workload Isolation (`SecurityProfileConfig`) — Design

## Context

Talos 1.14 can run the whole container plane (CRI containerd, the kubelet and every pod) in its own PID and mount
namespace, anchored by a new `sandboxd` service, instead of sharing the namespaces of `machined` (PID 1). It is switched
on by the `workloadIsolation` field of the new `SecurityProfileConfig` document. This spec enables it on the cluster,
node by node, with a pilot first.

The research and live checks behind it are in the `SecurityProfileConfig` bullet of `.plans/TODO.md` and in the memory
note `reference_talos_workload_isolation`. Read `2026-10-05-talos-config-layout-design.md` for the layered patch files
(`provision/talos/patches/`, one document per file, header lines, `scripts/check-patches.sh`).

### Decision, and what it is worth

Enabling it is decided. The value is modest and is recorded here so the decision is not reopened by accident: a
compromised or buggy pod can no longer see, signal or reach file descriptors of `machined`, `apid` or the other Talos
services, and `sandboxd` runs in its own least-privilege SELinux domain. It does not stop a privileged pod from using
devices or kernel interfaces (Ceph, multus, the smartctl exporters and the nvidia pods run privileged, several with
`hostPID`), and SELinux is not set on the control planes (`enabled, permissive` on nv1), so that layer does not enforce
there. It is also where Talos is going: new 1.14 clusters have it on by default.

### Current state (verified 2026-10-07)

- No node has a `SecurityProfileConfig` (live machine configs of mc1-mc3 and nv1). Isolation is off everywhere.
- `TALOS_CONTRACT` is pinned to `v1.13` (`provision/talos/scripts/lib.sh`). With it `talosctl gen config` emits no
  `SecurityProfileConfig`; with the v1.14 contract the base carries one with `workloadIsolation: true`. So the contract
  bump alone would enable isolation on the next apply and reboot.
- mc1-mc3 run Talos v1.14.2 and `sandboxd` already runs there, idle. **nv1 runs v1.14.0**, where `sandboxd` is not
  running and the CRI start-up bug applies (siderolabs/talos#14374: CRI restart-loops for 1-3 minutes on every boot,
  node degraded meanwhile; fixed in v1.14.2).
- The upstream Jetson installer `ghcr.io/schwankner/custom-installer` has no tag newer than `v1.14.0-6.18.48-...` (checked
  2026-10-07). A v1.14.2 installer now exists in the owner's own registry:
  `ghcr.io/mmalyska/custom-installer:v1.14.2-6.18.54-nvgpu5.13.0-drm-noshim` (public, arm64, built 2026-10-07, kernel
  6.18.54 like the control planes; nvgpu 5.13.0 where nv1 runs 5.11.1 today). nv1 itself still runs v1.14.0 until it is
  upgraded; that upgrade is a separate task, done and soaked before isolation is enabled on nv1 (two risky changes are
  never put into one reboot of a node without a console).
- The setting is read only when `sandboxd` starts: enabling or disabling needs a node reboot, not a live apply.
- Red test on mc3 after the pilot (2026-10-07), a privileged `hostPID` pod in `kube-system` run on mc1 (isolation off,
  control) and mc3 (isolation on): mc1 shows PID 1 `init` (machined), `apid` and `etcd` visible, 615 processes, 209
  readable file descriptors of PID 1; mc3 shows PID 1 `sandboxd`, `init` and `apid` **not** visible, 86 processes, 13
  readable descriptors (sandboxd's own), and only the container plane plus etcd. So the sandbox hides `machined` and
  `apid` from even the most privileged pod, and does not hide etcd.
- Merge behaviour (checked with `talosctl machineconfig patch`, v1.14.2): on the v1.13 base a patch adds the document;
  a later `workloadIsolation: false` overrides an earlier `true`; on the v1.14 base (which has `true`) a patch with
  `false` or `true` is honoured. Every combination validates in metal mode.
- Workloads that touch the sandbox boundary: `hostPID` pods are multus (all nodes), node-exporter (all), the Ceph RBD CSI
  node plugin (all) and `nvidia-cdi-setup` (nv1). Bidirectional mount propagation is used by cilium `mount-bpf-fs`,
  multus `install-multus-binary` and both Ceph CSI plugins (`/var/lib/kubelet/plugins`, `/var/lib/kubelet/pods`). In-tree
  NFS is in use (music-assistant on mc3, the NFS provisioner on mc2, and 5 NFS PVs for bookorbit on mc3, jellyfin and
  nextcloud on mc2). 76 RBD and 2 CephFS CSI volumes. Cilium has `cgroup.autoMount` off, so it does not `nsenter` PID 1.
  Nothing in `cluster/` uses iSCSI, the one documented break.

## Decisions

1. **Scope: all four nodes, with gates.** mc3 is the pilot, then mc2 and mc1. nv1 is pinned to `false` now and enabled
   in a conditional final phase.
2. **nv1 is pinned off explicitly**, not left to default, so the repo is correct when `TALOS_CONTRACT` moves to v1.14.
   It is enabled only after nv1 has been upgraded to v1.14.2 or later with the installer above and has soaked (the
   upgrade is separate work, tracked in the TODO).
3. **Rollout through the repo: pilot patch, then consolidate.** A node patch for mc3 first, then one patch in
   `patches/all/` plus an nv1 override. The repo matches the live nodes at every step, except the two control planes
   still waiting for their turn in phase 2.
4. **Soak after the pilot: about 48 hours** (two nights of backups and the scheduled jobs), then an explicit go from
   the user.
5. **Nothing is applied, drained or rebooted without the user's confirmation** (CLAUDE.md hard rule). Reboots are run by
   the user: `talosctl reboot` is blocked for Claude by the permission settings.

## Design

### 1. Config shape

One patch file per layer, named `65-security-profile.yaml` (after `61-kubeprism.yaml`; the number 65 is unused in
`all/`, `node/mc3/` and `node/nv1/`):

```yaml
# What:   Workload isolation: CRI, the kubelet and all pods run in the sandboxd namespace, apart from machined
# Why:    Separates the container plane from machined (PID 1) and its file descriptors; see docs/superpowers/specs/2026-10-07-talos-workload-isolation-design.md
# Nodes:  all nodes        (mc3 / nv1 in the node layer)
# Apply:  reboot (sandboxd reads the setting only when it starts)
apiVersion: v1alpha1
kind: SecurityProfileConfig
workloadIsolation: true
```

Layout by phase:

| Phase           | `patches/all/65` | `patches/node/mc3/65` | `patches/node/nv1/65` |
| --------------- | ---------------- | --------------------- | --------------------- |
| before          | none             | none                  | none                  |
| 1, pilot        | none             | `true`                | none                  |
| 2, consolidated | `true`           | removed               | `false`               |
| 3, nv1 enabled  | `true`           | none                  | removed               |

The Why of the nv1 file points at the v1.14.0 boot bug and the missing installer. No `.tpl`, no variables.

At the `TALOS_CONTRACT` v1.14 bump nothing flips: the base then carries `true`, the all-layer patch repeats it, and the
nv1 patch still wins with `false` (verified, see above).

### 2. Phases and gates

**Phase 0, baseline (read-only, before PR 1).** On mc3 record: pods and their restart counts, Ceph health and OSD state,
the NFS and RBD pods running there (bookorbit and music-assistant use NFS on mc3), `talosctl services`, and from
Prometheus the node-exporter filesystem series and the `node-disk-health` queries for mc3 (instant queries, see the
`prometheus-historical-queries` skill). Keep the output in the session notes of the plan, not in the repo.

**Phase 1, pilot on mc3.** PR 1 adds `patches/node/mc3/65-security-profile.yaml` (`true`), the render test, the
regenerated config map and the README section. After merge, with the user's go:

1. `task talos:generate`, `task talos:diff -- mc3` shows only the new document.
2. `task talos:apply N=mc3` (live, no reboot). Confirm the document in the live config.
3. Cordon and drain mc3, the user reboots it, uncordon. Ceph must be exactly HEALTH_OK before and after.
4. Run the verification list (section 3). Then soak about 48 hours. **Gate: the user decides to continue.**

**Phase 2, consolidate and roll.** PR 2 moves the setting to `patches/all/65-security-profile.yaml` (`true`), adds
`patches/node/nv1/65-security-profile.yaml` (`false`) and deletes the mc3 file; mc3's rendered config is unchanged (diff
clean). Then mc2, then mc1, each as in phase 1 steps 2-4, with Ceph HEALTH_OK between nodes. mc1 last, because it is the
first endpoint in the talosconfig. `task talos:apply N=nv1` applies the `false` document (no reboot needed, it changes
nothing) so that `task talos:diff` is clean.

**Phase 3, nv1 (conditional, not time-boxed).** Entry criteria, all required: nv1 has been upgraded to v1.14.2 or later with the
installer named above (it exists), following the README procedure including the UKI workaround; the GPU stack is verified
after the upgrade; nv1 has soaked on the new version. Then PR 3 deletes the nv1 `false` file; apply; cordon, drain, reboot, uncordon; verification
list plus `nvidia.com/gpu` allocatable, the CDI spec in `/var/run/cdi`, the `fw-fresh` firmware, `llama-server` on the GPU.
Until then the TODO keeps one entry for it.

### 3. Verification and rollback

After each node reboot:

- The node is Ready; `talosctl services` shows `cri`, `kubelet` and `sandboxd` healthy; `talosctl logs sandboxd` and
  `talosctl dmesg` show no errors; all pods match the baseline; `talosctl etcd status` is healthy (control planes).
- Cilium agent and multus are Ready on the node. Ceph is HEALTH_OK with its OSDs up.
- The unknowns, checked explicitly: restart a pod with an RBD volume on the node and confirm it attaches; the NFS mounts
  work (bookorbit and music-assistant on mc3, jellyfin and nextcloud on mc2); node-exporter targets are up and the
  filesystem series and `node-disk-health` queries still return what the baseline had.
- No new alerts; the next scheduled backups (CNPG, volsync) succeed.

Rollback, any phase, any node: set the node's `workloadIsolation` to `false` (or remove the patch before the all-layer
one exists), `task talos:apply`, reboot. `apid` and the other Talos services run outside the sandbox, so the
management path survives a broken container plane and no console is needed on the control planes. etcd is **not**
among them: with isolation on it is launched inside the sandbox too (observed on mc3, 2026-10-07: its `NSpid` is
`<host pid> <sandbox pid> 1`, and a probe pod in the sandbox sees it), so a `sandboxd` crash on a control plane would
also restart that node's etcd. Quorum holds with one member down, which is one more reason nodes go one at a time. If a node cannot
reach a healthy state after a reboot, stop the rollout and report; do not continue to the next node.

### 4. Repo changes, tests, docs

- Patch files as in section 1; `scripts/check-patches.sh` must pass (header `Nodes:` equals the layer).
- `tests/test_render.sh`: per phase, the documents present per node (phase 1: `SecurityProfileConfig` only on mc3 and
  `true`; phase 2: exactly one per node, `true` on mc1-mc3, `false` on nv1), and a guard that the same holds when the
  base is generated with the v1.14 contract (so the bump cannot flip a node).
- `docs/src/talos/config-map.md` regenerated (`task talos:config-map`); README "Workload isolation" section (what it is,
  why nv1 is false, the reboot, the contract-bump note, rollback); the `talos-config-editing` skill gets a line about the
  document; the memory note `reference_talos_workload_isolation` is updated per phase; `.plans/TODO.md`: the research
  bullet becomes a pointer to this spec and plan, and the "decide at the contract bump" item is closed.

## Risks

| Risk                                                       | Effect                                                 | Mitigation                                                                                                            |
| ---------------------------------------------------------- | ------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| Ceph CSI mounts do not reach the kubelet in the sandbox    | RBD or CephFS volumes fail to attach after the reboot  | They move into the sandbox together with the kubelet; pilot on mc3, explicit attach test; rollback                    |
| In-tree NFS mount fails inside the sandbox                 | NFS-backed pods stuck on that node                     | Docs name only iSCSI as broken; mc3 pilot has two NFS workloads; check each node                                      |
| node-exporter sees the sandbox's PID 1 and mount table     | Filesystem and process metrics change, alerts misfire  | Baseline before, compare after; the pilot shows it before the other nodes                                             |
| Cilium `mount-bpf-fs` and bidirectional propagation        | Datapath not reloaded after the namespace is recreated | Cilium agent Ready check; pilot; the sandbox restart path is the same as a reboot                                     |
| A control plane does not come back healthy                 | One of three control planes down                       | etcd quorum holds with one down; one node at a time; rollback by `talosctl` without a console                         |
| `sandboxd` crashes on a control plane                      | That node's etcd restarts with the container plane     | `sandboxd` has `oom_score_adj` -1000 and is restarted by Talos; quorum holds with one member down; one node at a time |
| Unplanned reboot of mc1 or mc2 between PR 2 and their turn | That node starts isolated earlier than planned         | Do PR 2 and the two applies in one session; the verification list still applies                                       |
| nv1 on v1.14.0 gets `true` by mistake                      | CRI restart loop on every boot, no console             | Explicit `false` patch, render test, the contract-bump guard                                                          |
| The contract bump turns it on by itself                    | Unplanned isolation on the next apply and reboot       | The all-layer `true` and the nv1 `false` are explicit; render test with the v1.14 base                                |

## Out of scope

- Upgrading nv1 itself (its own task, before phase 3), building Jetson installers, enforcing SELinux, tuppr.
- The `TALOS_CONTRACT` bump (its own change; this spec only makes it safe).
- Any change to privileged workloads (Ceph, multus, the nvidia pods) to reduce what they can reach.

## Open items for the implementation plan

- The exact Prometheus queries for the baseline and the comparison (node-exporter filesystem series, the
  `node-disk-health` queries), and which RBD-backed pod on mc3, mc2 and mc1 is safe to restart for the attach test.
- Whether `talosctl get` has a resource that shows the running isolation state (to prove it is on after the reboot);
  otherwise the proof is the processes in `talosctl logs sandboxd` and the PID namespace seen from a debug pod.
- Which nightly jobs (CNPG, volsync) cover the 48 hour soak, to name them in the gate.
