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

### Step 0 — Prepare bootable USB

Prepare the USB before taking any node down. The ISO must use the correct schematic so Talos
boots with the right extensions (same as the running cluster).

**Schematic ID:** `a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0`

Check the current cluster version first (use it as `<TALOS_VERSION>` below):

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl version -n 192.168.48.2 --short
```

Download the ISO from Talos Image Factory and write it to a USB drive:

```bash
TALOS_VERSION=v1.13.4   # confirm with talosctl version above
SCHEMATIC=a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0

curl -Lo talos-mc.iso \
  "https://factory.talos.dev/image/${SCHEMATIC}/${TALOS_VERSION}/metal-amd64.iso"

# Replace /dev/sdX with your USB device — verify with lsblk first
dd if=talos-mc.iso of=/dev/sdX bs=4M status=progress && sync
```

Verify the USB boots to the Talos maintenance screen on a spare machine or on the target node
before starting the replacement. Keep the USB ready — you will need it for each node.

### Step 1 — Mark Ceph OSD out and wait for rebalancing to complete

Find the OSD ID for the node's `sda` drive, then mark it out so Ceph rebalances all data to the
remaining two OSDs **before** the node goes offline:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out <osd-id>
```

**Wait for rebalancing to fully complete** before proceeding. The node will be offline for 1–2+
hours during the swap and reinstall — Ceph cannot access `sda` while the node is powered off,
so all data must be on the remaining OSDs before you cut power:

```bash
# Watch until all PGs show active+clean with no degraded/backfilling/recovering
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -w

# Final check — must show "X pgs: X active+clean" before proceeding
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph pg stat
```

### Step 2 — Reset the node

`talosctl reset` gracefully leaves etcd, drains the node, wipes the system disk (`nvme0n1` only —
`sda` is not touched), and powers off the machine:

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n <node-ip> reset
```

### Step 3 — Delete from Kubernetes

The reset does not remove the node object from Kubernetes — do that manually:

```bash
kubectl delete node <node>
```

### Step 4 — Swap the NVMe

The machine is already off after the reset. Open the M720q, replace `nvme0n1`. Leave `sda` untouched.

### Step 5 — Reinstall Talos

Boot from the USB prepared in Step 0. The node will get the same IP via DHCP reservation (the
NIC MAC address is unchanged), so `<node-ip>` below is the same as before.

Apply the existing machine config from the repo:

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl apply-config --insecure -n <node-ip> \
  -f provision/talos/clusterconfig/home-<node>.yaml
```

Talos installs itself onto the new drive and rejoins etcd automatically.

### Step 6 — Verify node is back

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
kubectl get node <node>                        # should reach Ready
talosctl -n <node-ip> etcd members            # should show 3 members
```

### Step 7 — Re-add Ceph OSD and wait for HEALTH_OK

The OSD pod will restart when the node comes back and register as UP, but it stays **OUT** because
you explicitly marked it out in Step 1. Mark it in manually and wait for full recovery:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd in <osd-id>
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -w
# Wait for HEALTH_OK (all PGs active+clean, 3 replicas) before moving to the next node
```

## Node Reference

| Node | IP | Config file |
|------|-----|-------------|
| mc1 | 192.168.48.2 | `provision/talos/clusterconfig/home-mc1.yaml` |
| mc2 | 192.168.48.3 | `provision/talos/clusterconfig/home-mc2.yaml` |
| mc3 | 192.168.48.4 | `provision/talos/clusterconfig/home-mc3.yaml` |

## Key Risks

| Risk | Mitigation |
|------|-----------|
| etcd split brain | `talosctl reset` leaves etcd automatically; never take 2 nodes down at once |
| Ceph data loss | Wait for `pg stat` to show `active+clean` (no degraded) before powering off |
| Wrong Talos version or schematic | Prepare USB from Image Factory with the schematic in this doc; confirm version with `talosctl version` first |
| Config drift | Machine configs live in `provision/talos/clusterconfig/` — always use those, never regenerate |
