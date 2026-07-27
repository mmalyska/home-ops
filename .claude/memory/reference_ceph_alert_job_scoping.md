---
name: reference-ceph-alert-job-scoping
description: "Rook-Ceph's bundled Ceph-mixin PrometheusRules have no job filter and can false-positive on unrelated Prometheus targets; fix via prometheusRuleOverrides expr override"
metadata:
  node_type: memory
  type: reference
  originSessionId: ce2af84b-be52-4e48-9b0b-8db6e2d9965d
  modified: 2026-07-27T10:27:44.622Z
---

Rook-Ceph's bundled Ceph-mixin alert rules (rendered from `prometheus/localrules.yaml` inside the `rook-ceph-cluster` chart) generally have **no `job` label filter** in their `expr` — they match any series with the right metric name across the whole Prometheus instance, not just real cluster/Ceph nodes.

This caused `CephNodeNetworkPacketErrors`/`CephNodeNetworkPacketDrops` to fire on the `asusrouter` scrape job (router `/metrics` at `192.168.50.1:9101`, see [[reference_home_network_hardware]]) instead of only the k8s nodes' `node-exporter` job — specifically on `eth5`, the router's 2.4GHz WiFi radio (confirmed via router syslog: `hostapd`/`wlceventd`/`acsd` log lines on that interface), not a wired NIC. The errors were normal 802.11 retry counters from a roaming client with weak signal — cosmetic, unrelated to cluster/storage health.

**Fix pattern**: `cluster/apps/core/rook-ceph/cluster/values.yaml` already has a `rook-ceph-cluster.monitoring.prometheusRuleOverrides` map (chart template does `mergeOverwrite $rule $ruleOverrides` keyed by alert name — see `templates/prometheusrules.yaml` in the vendored chart). Any rule field, including `expr`, can be overridden there. Fixed by adding `job="node-exporter"` to every `rate()` call in the affected rules' `expr`, matching how the bundled node-exporter mixin already scopes the equivalent alerts. PR: https://github.com/mmalyska/home-ops/pull/4693.

**How to apply**: if a new Discord/Alertmanager alert mentions a node/interface that doesn't match a real cluster node (mc1/mc2/mc3/nv1), check whether it's a Ceph-mixin default rule matching a non-cluster Prometheus target (`asusrouter`, `qnap` jobs) before assuming it's a real hardware/cluster issue. To inspect a rule's live `expr`/annotations, hit `/api/v1/rules` on the port-forwarded Prometheus (see [[prometheus-portforward-session]] skill) rather than guessing from the alert text alone — the default kube-prometheus-stack node-exporter mixin rules ARE properly job-scoped; it's specifically the Ceph-mixin ones that aren't.
