# NVMe Drive Replacement (Control Plane Nodes)

## Context

Each mc node (mc1/mc2/mc3 — Lenovo M720q) has two drives:

| Device | Model | Role |
|--------|-------|------|
| `nvme0n1` | Samsung PM981 (MZVLB256HBHQ-000L7) 256 GB M.2 2280 PCIe 3.0 x4 | OS + `/var` |
| `sda` | Crucial MX500 (CT500MX500SSD1) 500 GB SATA | Ceph OSD (raw block) |

This procedure covers replacing `nvme0n1` only. The Ceph OSD (`sda`) stays physically untouched throughout.

## Replacement Drive

Any **M.2 2280 NVMe PCIe** drive fits the M720q slot. PCIe 4.0 is backwards-compatible.

- **512 GB recommended** — `/var` was at 82% fill on mc3 (2026-06-11 audit); 256 GB is too tight
- Suggested: Samsung 980, WD Black SN770, or equivalent
- Do **not** buy M.2 SATA (different keying, different performance)

## SMART Wear Status (as of 2026-06-12)

| Node | Wear | Priority |
|------|------|----------|
| mc3 | 98% 🔴 | Replace first |
| mc1 | 74% ⚠️ | Replace second |
| mc2 | 73% ⚠️ | Replace third |

Monitor via Prometheus: `smartctl_device_percentage_used{device="nvme0n1"}`

## Procedure

**Replace one node at a time.** etcd requires 2/3 quorum — never take two nodes down simultaneously.

### Step 1 — Mark Ceph OSD out

Find the OSD ID for the node's `sda` drive, then mark it out so Ceph starts rebalancing data away before the node goes offline:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out <osd-id>
# Wait for Ceph to start rebalancing — status should show HEALTH_WARN (backfilling), not HEALTH_ERR
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
```

### Step 2 — Drain the node

```bash
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

### Step 3 — Remove from etcd

Do this **before** shutdown. Skipping this step causes the new node to fail rejoining.

```bash
talosctl -n <node-ip> etcd remove-member <node>
# Verify 2 members remain
talosctl -n <other-node-ip> etcd members
```

### Step 4 — Delete from Kubernetes and shut down

```bash
kubectl delete node <node>
talosctl -n <node-ip> shutdown
```

### Step 5 — Swap the NVMe

Power off, open the M720q, replace `nvme0n1`. Leave `sda` untouched.

### Step 6 — Reinstall Talos

Boot from Talos ISO (USB or PXE) — same version as the running cluster.

Check current cluster version before proceeding:

```bash
talosctl version -n 192.168.48.2
```

Apply the existing machine config from the repo:

```bash
talosctl apply-config --insecure -n <node-ip> \
  -f provision/talos/clusterconfig/<node>.yaml
```

Talos installs itself onto the new drive and rejoins etcd automatically.

### Step 7 — Verify node is back

```bash
kubectl get node <node>                        # should reach Ready
talosctl -n <node-ip> etcd members            # should show 3 members
```

### Step 8 — Re-add Ceph OSD

The OSD on `sda` should auto-rejoin once the node is back. If it doesn't:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd in <osd-id>
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
# Wait for HEALTH_OK before moving to the next node
```

### Step 9 — Uncordon

```bash
kubectl uncordon <node>
```

## Node Reference

| Node | IP | etcd name | Config file |
|------|----|-----------|-------------|
| mc1 | 192.168.48.2 | mc1 | `provision/talos/clusterconfig/mc1.yaml` |
| mc3 | 192.168.48.3 | mc3 | `provision/talos/clusterconfig/mc3.yaml` |
| mc2 | 192.168.48.4 | mc2 | `provision/talos/clusterconfig/mc2.yaml` |

## Key Risks

| Risk | Mitigation |
|------|-----------|
| etcd split brain | Always remove-member before shutdown; never take 2 nodes down at once |
| Ceph data loss | Mark OSD out and wait for rebalancing to start before powering off |
| Wrong Talos version | Check `talosctl version` on a running node before applying config |
| Config drift | Machine configs live in `provision/talos/clusterconfig/` — always use those, never regenerate |
