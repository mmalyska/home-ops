# TODO

General backlog items not tied to a specific plan.

---

## Talos — Node Operations

- [ ] **Investigate Talos taint modification on existing nodes** — during the Jetson iGPU work (`docs/superpowers/plans/2026-08-13-jetson-igpu.md`, Phase 0 Task 4), `task talos:apply` on nv1's renamed `nodeTaints` key (`nv` → `nvidia.com/gpu`) never reached the live Node object. `talosctl dmesg` showed `k8s.NodeApplyController` repeatedly failing: `nodes "nv1" is forbidden: node "nv1" is not allowed to modify taints`, even though `talosctl get nodetaintspecs` showed Talos had the correct desired state internally.
  - Root cause (as understood in the moment, not deeply verified): Kubernetes' `NodeRestriction` admission controller allows a kubelet to set taints only via `--register-with-taints` at **initial node registration** (a `CREATE`), and blocks any later `UPDATE` to `.spec.taints` from that same node identity — so Talos's config-driven taint reconciliation only works the first time a node joins, not on a config change to an already-running node.
  - Worked around by manually `kubectl taint`-ing the new key, then reapplying the Talos config to confirm no further drift (errors stopped once live state matched Talos's `NodeTaintSpec`).
  - Worth checking: is there an official Talos-supported flow for this (e.g. a documented "cordon, taint via kubectl, let Talos adopt/own it" pattern, a controller flag, elevated RBAC binding Talos is meant to have but doesn't in this cluster, or a `talosctl` subcommand that bypasses the kubelet identity)? Check Talos GitHub issues/docs for `NodeApplyController` + taints.
  - If no first-class fix exists, write a skill (e.g. `talos-taint-changes`) documenting the manual `kubectl taint` + config-reapply-to-confirm-no-drift procedure, so future taint renames/additions on already-registered nodes are a known, repeatable, low-risk operation instead of a surprise mid-plan.

## Apps — Chart Upgrades

- [ ] **Jellyfin** — migrate from local custom chart to official `jellyfin/jellyfin` Helm chart
  - Upstream chart: https://github.com/jellyfin/jellyfin-helm/tree/master/charts/jellyfin
  - Current: `cluster/apps/default/jellyfin/` is a hand-rolled chart with no external dep
  - Check if official chart supports Gateway API `route:` natively (would let us drop `templates/httproute.yaml` too)
  - Review if PVC/storage config, LoadBalancer service (`192.168.48.22`), and resource requests map cleanly to new chart values
  - Do after Traefik → Envoy migration Phase 1 is stable
