---
name: ceph-osd-discard
description: BlueStore discard on the SATA OSD disks needs bdev_enable_discard plus bdev_async_discard_threads; bdev_async_discard alone does nothing; on since 2026-10-29, costs about 1.5-2 ms Ceph write latency
metadata:
  type: reference
---

On Ceph 20 `bdev_async_discard = true` is a deprecated alias for `bdev_async_discard_threads = 1` and does nothing while `bdev_enable_discard` is false (default). The OSD disks (raw Crucial MX500) got zero discards until 2026-10-29 (`node_disk_discards_completed_total` on `sda` was 0 for 7 days). Now set in the Rook `configOverride` (`bdev_enable_discard = true`, `bdev_async_discard_threads = 1`, PR #6012) and applied live with `ceph tell osd.N config set`; both options change at runtime, no OSD restart.

**Why:** the owner accepted about 25 to 35 % higher Ceph write latency (about 6 to 8 ms) and a few percent more `sda` busy time in exchange for less SSD write amplification; the wear comparison is due 2026-11-12 against the baseline in `.plans/TODO.md`.

**How to apply:** when checking SATA wear or OSD latency, remember discard is on. A file value in `ceph.conf` beats the central config DB, so test with `ceph tell`, not `ceph config set`. `osd.0` is on mc2, `osd.1` on mc1, `osd.2` on mc3 (the node-disk-health skill's table says otherwise). Related: [[container-fs-writes-double-count]].
