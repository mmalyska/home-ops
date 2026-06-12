---
name: node-disk-health
description: Use when auditing disk health, filesystem usage, or I/O on cluster nodes — especially when filesystem queries return incomplete results or a node's second drive is missing from metrics.
---

# Node Disk Health

## Overview

Each mc node (mc1/mc2/mc3) has **two drives with different visibility in Prometheus**. A filesystem-only query silently misses the SSD entirely because Ceph uses it as a raw block device with no mountpoint.

## Cluster Disk Topology

| Node | IP | Device | Model | Protocol | Size | Role | Visible in `node_filesystem_*`? |
|------|----|--------|-------|----------|------|------|--------------------------------|
| mc1 | 192.168.48.2 | `nvme0n1` → `nvme0n1p4` | Samsung MZVLB256HBHQ | NVMe | 238.5 GiB | OS + `/var` | ✅ Yes |
| mc1 | 192.168.48.2 | `sda` | **Crucial MX500** (CT500MX500SSD1) | SATA | 465.8 GiB | Ceph OSD-1 (raw block) | ❌ No |
| mc3 | 192.168.48.3 | `nvme0n1` → `nvme0n1p4` | Samsung MZVLB256HBHQ | NVMe | 238.5 GiB | OS + `/var` | ✅ Yes |
| mc3 | 192.168.48.3 | `sda` | **Crucial MX500** (CT500MX500SSD1) | SATA | 465.8 GiB | Ceph OSD-2 (raw block) | ❌ No |
| mc2 | 192.168.48.4 | `nvme0n1` → `nvme0n1p4` | Samsung MZVLB256HAHQ | NVMe | 238.5 GiB | OS + `/var` | ✅ Yes |
| mc2 | 192.168.48.4 | `sda` | **Crucial MX500** (CT500MX500SSD1) | SATA | 465.8 GiB | Ceph OSD-0 (raw block) | ❌ No |
| (4th node) | 192.168.48.5 | `nvme0n1` | FORESEE XP1000F256G | NVMe | 236 GiB | OS + `/var` | ✅ Yes |
| Jaskinia | 192.168.50.8 | `nvme0n1`, `nvme1n1` | — | NVMe | — | QNAP storage | ✅ SMART available |

**`sda` SMART note:** The Crucial MX500 is a **SATA SSD** — `node_nvme_*` metrics do not cover it (NVMe protocol only). SMART for `sda` requires `smartctl -a /dev/sda` via a privileged DaemonSet or job.

**The trap:** `node_filesystem_size_bytes` only returns mounted filesystems. Ceph OSDs (`sda`) have no mountpoint — they are raw block devices. Use `node_disk_io_time_seconds_total` to discover all block devices first.

## Query Reference

### Step 1 — Discover all block devices (don't assume)

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=node_disk_io_time_seconds_total{job="node-exporter",instance=~"192.168.48.*"}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
from collections import defaultdict
by_node = defaultdict(list)
for r in d['data']['result']:
  by_node[r['metric']['instance']].append(r['metric']['device'])
for node in sorted(by_node):
  print(f'{node}: {sorted(by_node[node])}')
"
```

Expected: `nvme0n1`, `sda`, and many `rbd*` (Ceph RBD mapped volumes) per mc node.

### Step 2 — NVMe filesystem usage (`/var`)

```bash
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=(1 - node_filesystem_avail_bytes{fstype!~"tmpfs|rootfs|overlay|squashfs|fuse.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|rootfs|overlay|squashfs|fuse.*"}) * 100' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
from collections import defaultdict
by_node = defaultdict(list)
for r in d['data']['result']:
  by_node[r['metric']['instance']].append((float(r['value'][1]), r['metric']['mountpoint'], r['metric']['device']))
for node in sorted(by_node):
  print(f'\n{node}')
  for pct, mp, dev in sorted(by_node[node]):
    flag = ' *** CRITICAL' if pct > 85 else (' ** WARNING' if pct > 70 else (' (watch)' if pct > 50 else ''))
    print(f'  {pct:5.1f}%  {mp}  {dev}{flag}')
"
```

### Step 3 — SSD (Ceph OSD) I/O health

Capacity is tracked at the Ceph cluster level, not per-device. Use these for I/O health:

```bash
# Busy % — flag if sustained >50%
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=rate(node_disk_io_time_seconds_total{device="sda",job="node-exporter"}[5m]) * 100'

# Write throughput MiB/s
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=rate(node_disk_written_bytes_total{device="sda",job="node-exporter"}[5m]) / 1024 / 1024'

# Ceph cluster fill level (authoritative capacity metric for sda drives)
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=ceph_cluster_total_used_bytes / ceph_cluster_total_bytes * 100'
```

### Step 4 — NVMe SMART (all nodes)

These metrics are available after ArgoCD syncs the node-exporter DaemonSet with `--collector.nvme`. Covers all 4 cluster nodes (mc1/mc2/mc3 at 192.168.48.2–4 and the 4th node at 192.168.48.5) AND Jaskinia (192.168.50.8).

```bash
# Check which nodes expose NVMe SMART
for metric in node_nvme_percentage_used_ratio node_nvme_available_spare_ratio \
              node_nvme_media_errors_total node_nvme_temperature_celsius \
              node_nvme_power_on_hours_total node_nvme_unsafe_shutdowns_total; do
  echo "--- $metric ---"
  curl -s 'http://localhost:9090/api/v1/query' --data-urlencode "query=$metric" \
    | python3 -c "import sys,json; [print(f'  {r[\"metric\"].get(\"instance\")}  {r[\"metric\"].get(\"device\")}  {r[\"value\"][1]}') for r in json.load(sys.stdin)[\"data\"][\"result\"]]"
done
```

### Step 5 — SATA SMART via smartctl-exporter (mc1/mc2/mc3 `sda` only)

The `smartmon-exporter` DaemonSet runs `smartctl -a` on each drive. After sync, metrics are in the `monitoring` namespace scraped by Prometheus.

```bash
# SATA device overall health (1=PASSED, 0=FAILED)
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=smartctl_device_smart_status{device="sda"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {r[\"metric\"].get(\"instance\")}  healthy={r[\"value\"][1]}') for r in d['data']['result']]"

# SATA temperature (Celsius)
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=smartctl_device_temperature{device="sda"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {r[\"metric\"].get(\"instance\")}  temp={r[\"value\"][1]}°C') for r in d['data']['result']]"

# SATA wear — Crucial MX500 uses attribute 202 "Percent_Lifetime_Remain" (raw value = % remaining)
# smartctl_device_percentage_used is NVMe-only and returns NO DATA for SATA drives
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=100 - smartctl_device_attribute{device="sda", attribute_name="Percent_Lifetime_Remain", value_type="raw"}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); [print(f'  {r[\"metric\"].get(\"node\",r[\"metric\"].get(\"instance\"))}  wear%={r[\"value\"][1]}') for r in d['data']['result']]"
```

Note: `smartctl_device_*` metrics include a `node` label (set via ServiceMonitor relabeling from `__meta_kubernetes_pod_node_name`) in addition to the pod IP `instance` label.

### Step 6 — 7-day growth trend (for nodes near threshold)

```bash
WEEK_AGO=$(date -d '7 days ago' +%s)
# Replace instance value as needed
curl -s "http://localhost:9090/api/v1/query?time=${WEEK_AGO}" \
  --data-urlencode 'query=(1 - node_filesystem_avail_bytes{instance="192.168.48.3:9100",mountpoint="/var"} / node_filesystem_size_bytes{instance="192.168.48.3:9100",mountpoint="/var"}) * 100'
```

## Thresholds

| Metric | Watch | Warning | Critical |
|--------|-------|---------|----------|
| NVMe `/var` usage | >50% | >70% | >85% |
| SSD busy % | >30% | >50% | >80% |
| Ceph cluster used | >60% | >75% | >85% |
| NVMe wear (`percentage_used`) | >50% | >80% | >95% |
| SATA wear (Crucial MX500, `100 - Percent_Lifetime_Remain`) | >50% | >80% | >95% |
| NVMe temperature | >60°C | >70°C | >80°C |

## Known Gaps

- **mc3 `/var` filling** — historically at 82% (2026-06-11), growing ~2.7 pp/week. Suspected cause: Ceph logs/crash dumps at `/var/log/ceph` and `/var/lib/ceph/crash`. Investigate with `du -sh /var/log/ceph /var/lib/ceph/crash /var/lib/containers` on mc3.

## Drive Identity Reference

Use `node_disk_info{device!~"rbd.*|loop.*|zram.*",job="node-exporter"}` to re-query. Key labels: `model`, `serial`, `rotational` (0=SSD, 1=HDD), `path` (contains `ata` for SATA, `nvme` for NVMe).

| Node | Device | Model | Serial | Firmware | Protocol |
|------|--------|-------|--------|----------|----------|
| mc1 (48.2) | nvme0n1 | Samsung MZVLB256HBHQ-000L7 | S4ELNF0M695054 | 3L2QEXH7 | NVMe |
| mc1 (48.2) | sda | Crucial CT500MX500SSD1 | 2147E5E7AB2E | M3CR043 | SATA |
| mc3 (48.3) | nvme0n1 | Samsung MZVLB256HBHQ-000L7 | S4ELNF0M694879 | 3L2QEXH7 | NVMe |
| mc3 (48.3) | sda | Crucial CT500MX500SSD1 | 2147E5E7B554 | M3CR043 | SATA |
| mc2 (48.4) | nvme0n1 | Samsung MZVLB256HAHQ-000L7 | S41GNX0N202586 | 1L2QEXD7 | NVMe |
| mc2 (48.4) | sda | Crucial CT500MX500SSD1 | 2147E5E7B557 | M3CR043 | SATA |
| 192.168.48.5 | nvme0n1 | FORESEE XP1000F256G | PED265Q000146 | V1.28 | NVMe |
