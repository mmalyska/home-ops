---
status: in-progress
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 0de93ed44110a7783f8166d6856ebb0ffe8e9491
branch: feat/nv1-igpu-metrics
worktree: .worktrees/feat/nv1-igpu-metrics
pr: "#6466"
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
- 2026-11-25: lint fixed in this PR (owner's request): `check-manifests.sh` runs yq inside the rules directory and fails when fewer rule files are extracted than PrometheusRules rendered. Full run: 46 PrometheusRules checked, PASS; with a yq that fails on split: `promtool FAIL extracted 0 of 1`, exit 1.
- 2026-11-25: task 4 done. `JetsonGpuClockAboveCap` (critical, 2m) and `JetsonGpuExporterDown` (warning, 15m) with 8 promtool test cases; `check-manifests.sh nvidia`: promtool PASS (1 rule), rule-tests PASS. A deliberately wrong threshold and `for:` made the tests fail.
- 2026-11-25: task 5 done. "Jetson GPU" dashboard, 14 panels in 5 rows. Every query run against live Prometheus with nv1 filled in: all parse; node-exporter panels return data (VDD_IN 8.3 W, VDD_CPU_GPU_CV 3.0 W, VDD_SOC 2.7 W, gpu-thermal 57 °C, fan 35 %), exporter panels are empty until it is deployed. Rendered ConfigMap JSON valid; `device-dashboards` is about 734 KB of the 1 MiB limit (node.json is 662 KB). Next: task 6 (docs).
- 2026-11-25: task 6 done: `docs/src/k8s/nv1-jetson.md` "Metrics" (exporter, metric table with r39 sources, EMC activity caveat, what is not exported, INA3221 rails, dashboard, alerts). Next: task 7 (review and gates).
- 2026-11-25: task 7 done. Review fixes: `check-manifests.sh` fails when counting a file's PrometheusRules fails (it used to count that as none), the nvmap comment (allocation rows have 6 or 7 fields), the spec's resource limits. Gates: exporter test PASS (44), shellcheck PASS, `check-manifests.sh` all apps PASS (render 74, kubeconform 1210 resources, promtool 47 PrometheusRules, rule tests 4 apps), `task lint:all` no finding in a changed file except older lines of `docs/src/k8s/nv1-jetson.md` (same as `main`), yamllint PASS, `check-plans` PASS. NOT RUN: the exporter under busybox (sh, awk, httpd CGI through the ConfigMap symlink); fetching the pinned busybox image to test it locally was denied by the session's permission check, so the first rollout is the first busybox run. markdownlint is not run on `.plans/` by `lint:all`; the plan files have long lines. Next: task 8 (PR, on the owner's instruction).
- 2026-11-25: task 8 done: PR #6466 opened on the owner's instruction (labels enhancement, area/cluster, docs). Next: CI, the owner's review and merge, then task 9 (live checks).
- 2026-11-25: #6466 merged 12:40 UTC; `nvidia` and `prometheus-stack` synced to `315d206d`. Task 9 live checks: pod Ready (busybox `httpd` CGI through the ConfigMap symlink works), all 9 sources up, values as in evidence.md; load 0.90-0.92 and EMC activity 34.9M-35.1M (relative 10.9) during a 60 s, 1800-token request run by the owner, idle afterwards within one scrape; GPU memory flat at 4,619,096,064 bytes; `VDD_CPU_GPU_CV` 2.638 W before vs 2.628 W after; no restart, 1.8 MB memory, scrape at most 0.37 s; both rules loaded and inactive. **Failed:** `CPUThrottlingHigh` (info) for the exporter, 58 % of CPU periods throttled at 0.005 cores on average: a process per file read (about 25 per scrape) plus probes that ran the script. Fix in a follow-up PR on `fix/jetson-gpu-exporter-cpu`: files read with the shell's `read`, helpers set a variable instead of printing, one awk per scrape, TCP probes; a test runs the script with only awk on PATH. Also found: 15 s scrapes catch a 13 s request in one sample only; the spec's "cluster's first network policy" is wrong (`llm` has NetworkPolicies). Both go into the close-out.

## Delivery

One PR from `feat/nv1-igpu-metrics` (spec, plan, exporter, rule, dashboard, docs). Merging deploys a new DaemonSet to nv1 through the `nvidia` Argo CD app and a new dashboard ConfigMap through `prometheus-stack`; no existing pod or setting changes. Push, PR and merge only on the owner's instruction.
