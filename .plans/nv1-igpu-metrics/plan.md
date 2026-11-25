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

- 2026-11-25: spec written and decided.
- 2026-11-25: owner's pre-check done ([evidence.md](evidence.md)). Changes to the spec: EMC activity exported raw (not a percent), `is_railgated`/`gpu_powered_on` added, `enable_3d_scaling` and `trans_stat` dropped, INA3221 pairing confirmed.
- 2026-11-25: follow-up pre-check done (state files hold words). Task 2 done: `gpu-exporter.sh` and `gpu-exporter.test.sh` (44 checks pass, shellcheck and promtool clean; run with dash and mawk, busybox not available here). Next: task 3.
- 2026-11-25: task 3 done: `gpu-exporter.yaml` (DaemonSet, PodMonitor with a `node` label), ConfigMap generated from the script with a hash suffix. Found: the promtool step of `task lint:manifests` without an app name renders no rules, because yq v4.54 rejects the `-s` output path ("path must stay within the current directory"), and reports PASS. CI (`manifest-lint`) had the same false PASS.
- 2026-11-25: lint fixed in this PR (owner's request): `check-manifests.sh` runs yq inside the rules directory and fails when fewer rule files are extracted than PrometheusRules rendered. Full run: 46 PrometheusRules checked, PASS; with a yq that fails on split: `promtool FAIL extracted 0 of 1`, exit 1. Next: task 4.

## Delivery

One PR from `feat/nv1-igpu-metrics` (spec, plan, exporter, rule, dashboard, docs). Merging deploys a new DaemonSet to nv1 through the `nvidia` Argo CD app and a new dashboard ConfigMap through `prometheus-stack`; no existing pod or setting changes. Push, PR and merge only on the owner's instruction.
