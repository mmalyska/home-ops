# TODO

General backlog items not tied to a specific plan.

---

## Talos — Node Operations

- [ ] **Investigate Talos taint modification on existing nodes** — during the Jetson iGPU work (`docs/superpowers/plans/2026-08-13-jetson-igpu.md`, Phase 0 Task 4), `task talos:apply` on nv1's renamed `nodeTaints` key (`nv` → `nvidia.com/gpu`) never reached the live Node object. `talosctl dmesg` showed `k8s.NodeApplyController` repeatedly failing: `nodes "nv1" is forbidden: node "nv1" is not allowed to modify taints`, even though `talosctl get nodetaintspecs` showed Talos had the correct desired state internally.
  - Root cause (as understood in the moment, not deeply verified): Kubernetes' `NodeRestriction` admission controller allows a kubelet to set taints only via `--register-with-taints` at **initial node registration** (a `CREATE`), and blocks any later `UPDATE` to `.spec.taints` from that same node identity — so Talos's config-driven taint reconciliation only works the first time a node joins, not on a config change to an already-running node.
  - Worked around by manually `kubectl taint`-ing the new key, then reapplying the Talos config to confirm no further drift (errors stopped once live state matched Talos's `NodeTaintSpec`).
  - Worth checking: is there an official Talos-supported flow for this (e.g. a documented "cordon, taint via kubectl, let Talos adopt/own it" pattern, a controller flag, elevated RBAC binding Talos is meant to have but doesn't in this cluster, or a `talosctl` subcommand that bypasses the kubelet identity)? Check Talos GitHub issues/docs for `NodeApplyController` + taints.
  - If no first-class fix exists, write a skill (e.g. `talos-taint-changes`) documenting the manual `kubectl taint` + config-reapply-to-confirm-no-drift procedure, so future taint renames/additions on already-registered nodes are a known, repeatable, low-risk operation instead of a surprise mid-plan.

## Observability — Grafana Dashboards

- [ ] **nv1 iGPU utilization metrics** — `node-exporter` gives free thermal-zone temps for the Jetson Orin GA10B iGPU (`node_thermal_zone_temp{type="gpu-thermal"}`, already surfaced on the "Cluster Nodes" dashboard's "Thermal Zones" panel), but there is no exporter for GPU utilization/clocks — Jetson has no `nvidia-smi`. Investigate a `jtop`/jetson-stats Prometheus exporter or a `tegrastats`-parsing textfile-collector sidecar, in the spirit of the existing `docs/superpowers/specs/2026-08-13-jetson-igpu-design.md` pattern. Scope as its own design doc given nv1's GPU stack is still mid-rollout (see `docs/superpowers/plans/2026-08-13-jetson-igpu.md`).

## Storage — Rook-Ceph

- [ ] **🔒 GATED — Migrate CSI keys to the `aes256k` cipher and unmute the CephX warnings** — do **not** start until *both* gates below are true. Full background: `docs/src/k8s/rook-ceph-cephx.md`.
  - **Gate 1 — Linux kernel 7.0+ on every node.** `aes256k` is used by the *kernel* RBD/CephFS clients; forcing it on a 6.x kernel breaks every kernel mount and takes out all PVCs. Talos tracks the 6.18 **longterm** branch, so this is blocked on Talos adopting a 7.x kernel, not on Linux releasing one (7.2.x was already stable in 2026-09 while Talos v1.15 alphas were still on 6.18.49). Check: `kubectl get nodes -o custom-columns='NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion'`
  - **Gate 2 — ceph-csi ≥ v3.17.1** (was v3.17.0 at time of writing; Renovate will close this on its own). Check: `kubectl -n rook-ceph get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | grep cephcsi | sort -u`
  - **Then**, following Rook's "Migrating CSI keys to a new key type": rotate CSI keys with `keyType: aes256k`, `keyRotationPolicy: KeyGeneration`, a bumped `keyGeneration`, and `keepPriorKeyCountMax: 1` so in-use keys stay active; wait for `status.cephx.csi.keyGeneration`; then cordon/drain/reboot/uncordon each node in turn so pods remount with the new keys; then `keepPriorKeyCountMax: 0`.
  - **Finally**, restrict `spec.security.cephx.allowedCiphers` to `aes256k` and flip all four `spec.healthCheck.muteHealthWarning` entries in `cluster/apps/core/rook-ceph/cluster/values.yaml` from `mute` to `unmute`, so any stray `aes` key becomes visible again. Leaving them muted after migration is the failure mode to avoid — it would hide a real regression.
  - Do **not** set `allowedCiphers` before the CSI keys have moved: the CRD warns it "can disrupt cluster availability", and restricting it early locks out the CSI clients — an immediate storage outage.

## Apps — Chart Upgrades

- [ ] **Jellyfin** — migrate from local custom chart to official `jellyfin/jellyfin` Helm chart
  - Upstream chart: https://github.com/jellyfin/jellyfin-helm/tree/master/charts/jellyfin
  - Current: `cluster/apps/default/jellyfin/` is a hand-rolled chart with no external dep
  - Check if official chart supports Gateway API `route:` natively (would let us drop `templates/httproute.yaml` too)
  - Review if PVC/storage config, LoadBalancer service (`192.168.48.22`), and resource requests map cleanly to new chart values
  - Do after Traefik → Envoy migration Phase 1 is stable
