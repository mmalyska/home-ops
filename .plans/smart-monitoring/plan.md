# Plan: SMART Disk Health Monitoring

## Goal

Enable SMART health metrics for all drives on the 4 cluster nodes:
1. NVMe SMART (wear, temperature, media errors) for `nvme0n1` on mc1/mc2/mc3 and the 4th node (192.168.48.5) — via `--collector.nvme` in node-exporter.
2. SATA SSD SMART for `sda` (Crucial MX500) on mc1/mc2/mc3 — via a new `smartmon-exporter` DaemonSet app.
3. Grafana dashboard for disk SMART health.
4. PrometheusRule alerts for critical thresholds.
5. Update the `node-disk-health` skill with new metric names.

## Context

**Cluster nodes and drives:**

| Node | IP | Device | Protocol | Role | Current SMART coverage |
|------|----|--------|----------|------|----------------------|
| mc1 | 192.168.48.2 | nvme0n1 | NVMe | OS disk | identity only (`node_nvme_info`) |
| mc1 | 192.168.48.2 | sda | SATA | Ceph OSD | none |
| mc3 | 192.168.48.3 | nvme0n1 | NVMe | OS disk | identity only |
| mc3 | 192.168.48.3 | sda | SATA | Ceph OSD | none |
| mc2 | 192.168.48.4 | nvme0n1 | NVMe | OS disk | identity only |
| mc2 | 192.168.48.4 | sda | SATA | Ceph OSD | none |
| 4th node | 192.168.48.5 | nvme0n1 | NVMe | OS disk | identity only |
| Jaskinia | 192.168.50.8 | nvme* | NVMe | QNAP | full SMART already ✓ |

**Infrastructure:**
- `node-exporter` runs as a DaemonSet in `monitoring` namespace, deployed via `prometheus-stack` Helm chart (kube-prometheus-stack).
- Node-exporter values live in `cluster/apps/system/prometheus-stack/values.yaml` under `prometheus-node-exporter.extraArgs`.
- Prometheus scrapes all ServiceMonitors/PodMonitors in any namespace (`serviceMonitorSelectorNilUsesHelmValues: false`).
- The `monitoring` namespace has `pod-security.kubernetes.io/enforce: privileged` (set in prometheus-stack `app-config.yaml`).

## Architecture

### Part 1 — NVMe SMART via node-exporter (values.yaml change)

Add `--collector.nvme` to `prometheus-node-exporter.extraArgs` in `cluster/apps/system/prometheus-stack/values.yaml`.

This enables these metrics on all 4 cluster nodes:
- `node_nvme_temperature_celsius`
- `node_nvme_percentage_used_ratio` — wear indicator (0–1)
- `node_nvme_available_spare_ratio` — spare blocks remaining (0–1)
- `node_nvme_media_errors_total`
- `node_nvme_power_on_hours_total`
- `node_nvme_unsafe_shutdowns_total`

The kube-prometheus-stack chart already configures node-exporter with `/dev` and `/sys` hostPath mounts required for NVMe ioctl access. Confirm presence in rendered output before committing.

### Part 2 — SATA SMART via prometheus-smartmon (new app)

Deploy `prometheus-community/prometheus-smartmon` Helm chart as a new app at `cluster/apps/system/smartmon-exporter/`.

This chart deploys a privileged DaemonSet that runs `smartctl -a` on all drives and exposes Prometheus metrics on port 9633. Key configuration:
- `privileged: true` security context
- hostPath `/dev` mount
- Device filter to target `/dev/sda` and `/dev/nvme*`, excluding `/dev/rbd*` (Ceph RBD devices produce noise/spurious SMART failures)
- `serviceMonitor.enabled: true` for automatic Prometheus scraping
- Deploy to `monitoring` namespace (already privileged PSA — no additional namespace setup needed)

**App structure:**
```
cluster/apps/system/smartmon-exporter/
├── app-config.yaml
├── Chart.yaml
└── values.yaml
```

No secrets required.

### Part 3 — Grafana Dashboard

Add a Grafana dashboard entry under `kube-prometheus-stack.grafana.dashboards.device` in `prometheus-stack/values.yaml`:

```yaml
smart-disk-health:
  gnetId: 20204
  revision: 1
  datasource: Prometheus
```

If Grafana.com dashboard 20204 is unsuitable, fall back to a custom JSON in `dashboards/smart-disk-health.json` injected via `templates/device-dashboards-cm.yaml` (following the existing `node.json`/`router.json` pattern).

### Part 4 — PrometheusRule alerts

Add `cluster/apps/system/prometheus-stack/templates/prometheusrule-smart.yaml`:

| Alert | Condition | Severity |
|-------|-----------|----------|
| NVMeTemperatureHigh | `node_nvme_temperature_celsius > 70` for 5m | warning |
| NVMeTemperatureCritical | `node_nvme_temperature_celsius > 80` for 5m | critical |
| NVMeWearHigh | `node_nvme_percentage_used_ratio > 0.8` | warning |
| NVMeWearCritical | `node_nvme_percentage_used_ratio > 0.95` | critical |
| NVMeMediaErrors | `increase(node_nvme_media_errors_total[1h]) > 0` | critical |
| SATASmartHealthFailed | `smartmon_device_smart_healthy != 1` | critical |
| SATATemperatureHigh | `smartmon_attr_raw_value{attr_name="Temperature_Celsius"} > 70` for 5m | warning |
| SATAWearHigh | `smartmon_attr_value{attr_name="Wear_Leveling_Count"} < 20` | warning |

## Key Decisions

1. **`--collector.nvme` in node-exporter** — one-line change, no new pod, zero operational overhead.
2. **`prometheus-smartmon` chart for SATA** — canonical community chart; avoids hand-rolling a privileged DaemonSet.
3. **`monitoring` namespace for smartmon-exporter** — already has privileged PSA; consistent with node-exporter.
4. **PrometheusRule in prometheus-stack templates** — centralizes monitoring rules; avoids spreading across apps.
5. **gnetId-based Grafana dashboard** — avoids large JSON blob in git.

## Verification

After Phase 1 syncs:
```bash
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=node_nvme_temperature_celsius{instance=~"192.168.48.*"}' \
  | python3 -c "import sys,json; [print(r['metric']['instance'], r['metric']['device'], r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
pkill -f "port-forward.*prometheus"; true
```

After Phase 2 syncs:
```bash
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=smartmon_device_smart_healthy{instance=~"192.168.48.*"}'
pkill -f "port-forward.*prometheus"; true
```

## Current Status

Planning — not started.
