---
name: container-fs-writes-double-count
description: container_fs_writes_bytes_total has a pod-level series next to the per-container ones; sums without a container filter are exactly 2x
metadata:
  type: reference
---

`container_fs_writes_bytes_total` (cAdvisor) carries one series per container plus one pod-level series with `container=""`, so a selector on `pod=~...` alone matches both. A `sum(rate(...{pod=~"x.*"}[..]))` therefore counts everything twice. Seen 2026-10-23: Prometheus read 0.17 MB/s unfiltered and 0.086 with `container="prometheus"`, Loki 0.095 against 0.047, the mons 0.15 against 0.07 to 0.08.

**Why:** a wrong 2x number sent the Loki write-amplification analysis the wrong way ("half is filesystem overhead") until the app-level counters (0.04 MB/s) disagreed with the disk figure (0.081).

**How to apply:** always select `container!=""` (or one `container="..."`) for per-workload write or read rates, and cross-check against the app's own counters when a ratio looks odd. Same applies to the other `container_fs_*` and `container_network_*` pod-level duplicates. See [[reference-ceph-alert-job-scoping]] for another query trap in the same stack.
