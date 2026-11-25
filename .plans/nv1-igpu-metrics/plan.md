---
status: draft
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 0de93ed44110a7783f8166d6856ebb0ffe8e9491
branch: feat/nv1-igpu-metrics
worktree: .worktrees/feat/nv1-igpu-metrics
pr: not-opened
started: 2026-11-25
updated: 2026-11-25
---

# nv1 iGPU utilization metrics

Design: [spec.md](spec.md). Source: the `.plans/TODO.md` item "nv1 iGPU utilization metrics".

## Goal

GPU load, GPU and EMC clocks, EMC utilization, GPU memory per process and the GPU gating flags of nv1 in Prometheus, from a privileged read-only busybox exporter (`jetson-gpu-exporter` DaemonSet in `nvidia-system`); a `critical` alert when the GPU clock is above the 918 MHz cap; a separate "Jetson GPU" Grafana dashboard that also shows the INA3221 power rails node-exporter already collects.

## Decisions (owner, 2026-11-25)

- Own exporter reading sysfs and debugfs (spec option C), not jtop or tegrastats.
- Privileged pod, read-only mounts, script takes no input.
- `JetsonGpuClockAboveCap` is `critical`.
- Separate dashboard for GPU nodes.
- No network policy (none exist in the cluster; see spec).
- This workspace is read-only: nv1 file checks are run by the owner from a privileged session with the prompt in spec.md, "Pre-check from a privileged session".

## Status

- 2026-11-25: spec written and decided. Waiting on the owner's pre-check report (task 1). Tasks 2-6 can start on jtop's formats; fixtures are replaced when the report arrives.

## Delivery

One PR from `feat/nv1-igpu-metrics` (spec, plan, exporter, rule, dashboard, docs). Merging deploys a new DaemonSet to nv1 through the `nvidia` Argo CD app and a new dashboard ConfigMap through `prometheus-stack`; no existing pod or setting changes. Push, PR and merge only on the owner's instruction.
