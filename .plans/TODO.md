# TODO

General backlog items not tied to a specific migration plan.

---

## Infrastructure — Logging

- [ ] **No centralized log aggregation exists** — `monitoring` namespace is metrics-only (kube-prometheus-stack + smartctl-exporter), no Loki/Promtail/Fluent Bit/Vector anywhere in the cluster
  - Surfaced while disabling rook-ceph's `logCollector` (PR #4468) to reclaim ~1.3 cores/1.3Gi of idle reservation — without it, Ceph component logs are `kubectl logs`-only (ephemeral, lost on restart/rotation)
  - Accepted as a tradeoff for now; revisit if Ceph log history is ever needed for debugging a real incident
  - If pursued, a lightweight option (e.g. Grafana Loki + Promtail/Alloy) would also benefit every other app in the cluster, not just rook-ceph

## Apps — Chart Upgrades

- [ ] **Jellyfin** — migrate from local custom chart to official `jellyfin/jellyfin` Helm chart
  - Upstream chart: https://github.com/jellyfin/jellyfin-helm/tree/master/charts/jellyfin
  - Current: `cluster/apps/default/jellyfin/` is a hand-rolled chart with no external dep
  - Check if official chart supports Gateway API `route:` natively (would let us drop `templates/httproute.yaml` too)
  - Review if PVC/storage config, LoadBalancer service (`192.168.48.22`), and resource requests map cleanly to new chart values
  - Do after Traefik → Envoy migration Phase 1 is stable
