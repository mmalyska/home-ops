# Tasks: SMART Disk Health Monitoring

## Phase 1 — NVMe SMART via node-exporter

- [ ] Create branch `feat/smart-monitoring`
- [ ] In `cluster/apps/system/prometheus-stack/values.yaml`, add `--collector.nvme` to `prometheus-node-exporter.extraArgs`
- [ ] Run `helm dependency update . && helm template prometheus-stack . -f values.yaml` from the prometheus-stack app dir; confirm node-exporter DaemonSet args include `--collector.nvme`
- [ ] Confirm rendered DaemonSet has hostPath mounts for `/dev` and `/sys` (required for NVMe ioctl); if absent, add `prometheus-node-exporter.extraHostVolumes` / `extraHostVolumeMounts` for `/dev`
- [ ] Run `task lint:all` — confirm passes
- [ ] Commit: `chore(monitoring): enable node-exporter nvme collector for SMART metrics`
- [ ] Push branch, open PR, merge
- [ ] After ArgoCD sync, port-forward Prometheus and verify `node_nvme_temperature_celsius{instance=~"192.168.48.*"}` returns values for all 4 cluster nodes
- [ ] Verify `node_nvme_percentage_used_ratio`, `node_nvme_available_spare_ratio`, `node_nvme_media_errors_total` are also present

## Phase 2 — SATA SMART via smartmon-exporter

- [ ] Run `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update && helm show values prometheus-community/prometheus-smartmon` to inspect available values and note exact key names for privileged context, device filter, and serviceMonitor
- [ ] Create `cluster/apps/system/smartmon-exporter/app-config.yaml` (namespace: monitoring, selfHeal: true, prune: false — monitoring namespace is pre-existing with privileged PSA)
- [ ] Create `cluster/apps/system/smartmon-exporter/Chart.yaml` with `prometheus-smartmon` as a dependency; use latest chart version from helm search output
- [ ] Create `cluster/apps/system/smartmon-exporter/values.yaml` with: `serviceMonitor.enabled: true`, `privileged: true` securityContext, device filter excluding `/dev/rbd*`, resource limits (cpu: 10m/50m, memory: 32Mi/64Mi)
- [ ] Run `helm dependency update . && helm template smartmon-exporter . -f values.yaml` from the new app dir; confirm DaemonSet has `privileged: true`, `/dev` hostPath mount, and correct device filter
- [ ] Run `task lint:all` — confirm passes

## Phase 3 — Grafana dashboard + PrometheusRules

- [ ] In `cluster/apps/system/prometheus-stack/values.yaml`, add under `kube-prometheus-stack.grafana.dashboards.device`: entry `smart-disk-health` with `gnetId: 20204, revision: 1, datasource: Prometheus`; if gnetId 20204 is unsuitable, add a custom `dashboards/smart-disk-health.json` and reference in `templates/device-dashboards-cm.yaml` following the `node.json` pattern
- [ ] Create `cluster/apps/system/prometheus-stack/templates/prometheusrule-smart.yaml` as a `PrometheusRule` resource with the alerts defined in plan.md (NVMeTemperatureHigh/Critical, NVMeWearHigh/Critical, NVMeMediaErrors, SATASmartHealthFailed, SATATemperatureHigh, SATAWearHigh)
- [ ] Run `helm template prometheus-stack . -f values.yaml` from prometheus-stack dir; confirm PrometheusRule appears in rendered output
- [ ] Run `task lint:all` — confirm passes
- [ ] Commit all Phase 2+3 changes: `feat(monitoring): add smartmon-exporter for SATA SMART metrics and alerts`
- [ ] Push, open PR, merge
- [ ] After ArgoCD sync, verify `smartmon-exporter` DaemonSet is Running on mc1/mc2/mc3: `kubectl get ds -n monitoring`
- [ ] Port-forward Prometheus, verify `smartmon_device_smart_healthy{instance=~"192.168.48.*"}` returns 1 for sda on mc1/mc2/mc3
- [ ] Verify PrometheusRules loaded: query `ALERTS{alertname=~"NVMe.*|SATA.*"}`
- [ ] Verify Grafana shows the new SMART dashboard

## Phase 4 — Update node-disk-health skill

- [ ] In `.claude/skills/node-disk-health/SKILL.md`, add NVMe SMART query examples to the Query Reference section (for cluster nodes, using `node_nvme_*` metrics)
- [ ] Add SATA SMART query examples using `smartmon_device_smart_healthy` and `smartmon_attr_raw_value{attr_name="Temperature_Celsius",device="sda"}`
- [ ] Remove the two "Known Gaps" items for NVMe and SATA SMART (now resolved)
- [ ] Commit: `docs(skill): update node-disk-health with SMART metric names`

## Completion

- [ ] Move `.plans/smart-monitoring/` to `.archive/.plans/smart-monitoring/`
- [ ] Remove entry from `.plans/list.md`; add entry to `.archive/.plans/list.md`
