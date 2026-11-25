# nv1 iGPU utilization metrics — Design

Source: the `.plans/TODO.md` item "nv1 iGPU utilization metrics". Written 2026-11-25. Spec only: no plan, no index row until it is approved.

Decided by the owner on 2026-11-25:

- Our own exporter that reads sysfs and debugfs directly (option C below), running **privileged** so it can read the debugfs metrics.
- `JetsonGpuClockAboveCap` is `critical`.
- A separate Grafana dashboard for GPU nodes, not a row in "Cluster Nodes".
- This workspace is read-only. Checks that need nv1's files are run by the owner in a session with more access ("Pre-check from a privileged session" below).

## Problem

nv1 (Jetson Orin NX 16GB, GA10B iGPU, JetPack 7 / r39 `nvgpu`) runs `llama-server`, but Prometheus has no metric for how busy the GPU or the memory controller is, or at which clocks they run. Jetson has no `nvidia-smi` and no DCGM, so the usual NVIDIA exporters do not apply. Today we see:

| Signal                               | Source                                                     | State (checked 2026-11-25)                                     |
| ------------------------------------ | ---------------------------------------------------------- | -------------------------------------------------------------- |
| GPU temperature                      | node-exporter `node_thermal_zone_temp{type="gpu-thermal"}` | present, on "Cluster Nodes" → "Thermal Zones"                  |
| Board power rails                    | node-exporter hwmon, chip `i2c_1_1_0040` (`ina3221`)       | **present but unused**: `VDD_IN`, `VDD_CPU_GPU_CV`, `VDD_SOC`  |
| Fan PWM                              | node-exporter hwmon, chip `platform_pwm_fan`               | present, unused                                                |
| GPU load                             | —                                                          | **missing**                                                    |
| GPU clock (current, min, max)        | —                                                          | **missing**                                                    |
| GPU devfreq governor / present        | only in `jetson-power-mode` logs                           | **missing** as a metric                                        |
| GPU power gating state               | —                                                          | missing                                                        |
| Memory controller (EMC) utilization  | —                                                          | **missing**                                                    |
| EMC clock                            | only in `jetson-power-mode` logs (debugfs)                 | missing as a metric                                            |
| GPU memory per process               | —                                                          | **missing**                                                    |

Two of these matter beyond curiosity:

- **EMC utilization.** LLM token generation is mostly bound by memory bandwidth, so for `llama-server` the memory controller's activity says more than GPU load does.
- **GPU clock cap.** The board must not run the 1173 MHz Super clock; `power-mode.yaml` caps it at 918 MHz. Whether the cap holds is only visible in pod logs. A metric lets an alert check it continuously.

## Goals

1. GPU load (0–1), GPU clock, the devfreq cap (`max_freq`, `min_freq`, governor) and whether the devfreq node exists, in Prometheus every 15 s.
2. EMC utilization and EMC clock.
3. GPU memory per process (`llama-server` in practice).
4. GPU power gating flags (rail gating, TPC power gating, 3D scaling).
5. An alert when the GPU maximum clock is above the 918 MHz cap.
6. Panels for all of the above and for the INA3221 power rails that node-exporter already collects.

Non-goals: NVENC/NVDEC/NVJPG/VIC/DLA/PVA engine clocks (nothing on nv1 uses them; easy to add later from `debug/clk/*`), multi-node support beyond the `accelerator: jetson-orin` selector already used by the nvidia DaemonSets.

## What the node exposes

The workspace cannot read nv1 sysfs or debugfs, so this list comes from earlier work on nv1 and from the jetson-stats (`jtop`) source (`rbonghi/jetson_stats`, `jtop/core/gpu.py`, `memory.py`, `processes.py`, read 2026-11-25). Which candidate exists on r39 is checked in the first rollout: the exporter logs the paths it found at start.

Sysfs (GPU device dir `/sys/devices/platform/bus@0/17000000.gpu`):

- `load`: GPU load in tenths of a percent (0–1000). Used to measure "about 95 %" during a `llama-server` request (`docs/src/k8s/nv1-jetson.md`; `.archive/.plans/superpowers/plans/2026-10-07-talos-workload-isolation.md`). jtop reads the same file.
- `railgate_enable`, `tpc_pg_mask`, `enable_3d_scaling`: gating flags (jtop reads them when readable).
- `devfreq/17000000.gpu/`: `cur_freq`, `min_freq`, `max_freq`, `governor`, maybe `trans_stat`. **Created only at the first GPU use after boot** (r39), so it can be absent.

Debugfs (`/sys/kernel/debug`, root only):

- EMC clock: `bpmp/debug/clk/emc/{rate,min_rate,max_rate}` (also what `power-mode.yaml` writes).
- EMC utilization, first match of: `cactmon/mc_all`, `bpmp/debug/actmon/mc_all_avg_activity` (jtop's candidates, in jtop's order; jtop also tries `/sys/kernel/actmon_avg_activity/mc_all`). jtop computes the percentage as `mc_all // emc_rate_kHz` (`jtop/core/memory.py`, citing an NVIDIA forum answer), so the ratio is `mc_all / (rate / 1000) / 100`. To confirm against idle and loaded samples.
- Per-process GPU memory: `nvmap/iovmm/maps` (jtop: "nvmap debugfs is the authoritative source" on the nvgpu stack). jtop parses lines `<user> <process> <pid> <size><unit>` and a `total <size><unit>` line (`jtop/core/processes.py`, `MEM_TABLE_REG`); the unit is expected to be `K`.

`tegrastats` is a closed NVIDIA binary, so which files it reads is not known; its output covers the same areas (RAM, CPU, `EMC_FREQ`, `GR3D_FREQ`, engines, temperatures, rails).

## Options

| Option                                                                                | For                                                              | Against                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A. jetson-stats (`jtop`) + a jtop Prometheus exporter                                 | Widest metric set, maintained upstream, community dashboards     | Needs the `jtop` service (Python, a socket, privileged for debugfs anyway) and assumes L4T userspace (`/etc/nv_tegra_release`, `nvpmodel`) that Talos lacks; third-party exporters are small; two images to track. |
| B. `tegrastats` in a sidecar, parsed into node-exporter's textfile collector          | Familiar output                                                  | `tegrastats` comes from the L4T `.deb`s, not on the node; closed binary; a parser plus a shared hostPath; enabling the textfile collector changes node-exporter on all four nodes.                                         |
| **C. Read sysfs and debugfs directly, serve `/metrics` from a small exporter (chosen)** | No new image (busybox, already pinned), no L4T userspace, nv1 only | We own the script and the metric names; privileged for debugfs (same as A would need).                                                                                                                                   |

The metrics that make A and B richer than a sysfs-only exporter are almost all debugfs reads; C reads the same files. jtop's source is the reference for paths and unit conversions.

## Design

### Workload

A new DaemonSet `jetson-gpu-exporter` in `nvidia-system`, next to `jetson-power-mode`, in `cluster/apps/system/nvidia/resources/gpu-exporter.yaml`, added to `kustomization.yaml`.

- Selector and tolerations copied from `jetson-power-mode`: `nodeSelector: accelerator: jetson-orin`, `tolerations: [{operator: Exists}]`.
- Image: the same digest-pinned `busybox:1.38` as `power-mode.yaml` (Renovate already tracks it).
- `busybox httpd -f -p 9400` with a CGI script `/cgi-bin/metrics`; the script is in a ConfigMap (`gpu-exporter.sh`), mounted at `/www/cgi-bin/`. The script reads from a root directory (default `/`), so it can be tested against fake trees like `watchdog.test.sh` does.
- **Privileged** (`securityContext.privileged: true`), because debugfs is root-only; `jetson-power-mode` reads the same `bpmp` files with the same privileged hostPath mount. Whether a non-privileged root container with `SYS_ADMIN` would be enough is not worth testing: `SYS_ADMIN` is nearly as broad. Limits on what it can do:
  - `/sys` and `/sys/kernel/debug` hostPath mounts with `readOnly: true`; the script only reads.
  - `readOnlyRootFilesystem: true`; no host network, PID or IPC namespace.
  - The CGI script takes no input: it ignores the query string and the request body, and `httpd` serves nothing else (empty document root apart from `cgi-bin/metrics`).
  - No network policy: on 2026-11-25 there were none in `nvidia-system` and no cluster-wide Cilium policies, so one here would be the cluster's first. The endpoint serves metrics only.
- A separate DaemonSet, not a container in `jetson-power-mode`: that pod writes clocks; the exporter only reads, and a crash or restart in one must not restart the other.
- Resources: requests 5m / 8Mi, limits 50m / 16Mi; adjust after the first rollout (parsing `nvmap/iovmm/maps` is the largest read).
- `PodMonitor` in `nvidia-system` (the operator selects all PodMonitors: `podMonitorSelectorNilUsesHelmValues: false`), interval 15s.

Fallback: if busybox CGI proves awkward, run the same script in a loop writing a file and serve that file statically with `httpd`. Same metrics.

### Metrics

| Metric                                                | Type    | Source                                                                         |
| ----------------------------------------------------- | ------- | ------------------------------------------------------------------------------ |
| `jetson_gpu_load_ratio`                               | gauge   | `load` / 1000                                                                  |
| `jetson_gpu_devfreq_present`                          | gauge   | 1 when the devfreq dir exists, else 0 (the devfreq metrics are then omitted)   |
| `jetson_gpu_frequency_hz`                             | gauge   | `cur_freq`                                                                     |
| `jetson_gpu_frequency_min_hz`                         | gauge   | `min_freq`                                                                     |
| `jetson_gpu_frequency_max_hz`                         | gauge   | `max_freq`                                                                     |
| `jetson_gpu_governor_info{governor=…}`                | gauge 1 | `governor`                                                                     |
| `jetson_gpu_railgate_enabled`                         | gauge   | `railgate_enable`                                                              |
| `jetson_gpu_tpc_power_gating_enabled`                 | gauge   | `tpc_pg_mask` (as jtop interprets it)                                          |
| `jetson_gpu_3d_scaling_enabled`                       | gauge   | `enable_3d_scaling`                                                            |
| `jetson_emc_utilization_ratio`                        | gauge   | actmon `mc_all` (first candidate found), scaled as jtop does                   |
| `jetson_emc_frequency_hz`                             | gauge   | `bpmp/debug/clk/emc/rate`                                                      |
| `jetson_emc_frequency_min_hz`, `_max_hz`              | gauge   | `min_rate`, `max_rate`                                                         |
| `jetson_gpu_process_memory_bytes{command=…}`          | gauge   | `nvmap/iovmm/maps`, summed per command name (no `pid` label, to avoid churn)   |
| `jetson_gpu_memory_bytes`                             | gauge   | total of `nvmap/iovmm/maps`                                                    |
| `jetson_gpu_frequency_seconds_total{frequency_hz=…}`  | counter | `trans_stat` time-in-state, only if the file exists (optional)                 |
| `jetson_exporter_source_up{source=…}`                 | gauge   | 1 per source file read, 0 when missing or unreadable; replaces silent gaps     |

`node`/`instance` labels come from the PodMonitor; the pod runs only on nv1. A file that is missing or unreadable yields `source_up 0` and no value; it never fails the scrape.

### Alerts

A `PrometheusRule` in `nvidia-system`:

- `JetsonGpuClockAboveCap`: `jetson_gpu_frequency_max_hz > 918e6` for 2m, severity `critical`. The cap is the one in `power-mode.yaml` (MAXN, 918 MHz); the rule comment points there so the two change together. Also fires on `jetson_gpu_frequency_hz > 918e6`, which catches a governor that ignores `max_freq`.
- `JetsonGpuExporterDown`: the target is down for 10m while nv1 is Ready, severity `warning`.

No load- or bandwidth-based alert: high values during inference are normal.

### Dashboard

A new dashboard `cluster/apps/system/prometheus-stack/dashboards/jetson-gpu.json` ("Jetson GPU"), added to the `device-dashboards` ConfigMap (`templates/device-dashboards-cm.yaml`) next to `node.json`. A `node` variable from `jetson_gpu_load_ratio`, so a second Jetson node needs no dashboard change. Panels:

- GPU load (%) and EMC utilization (%) on one graph.
- GPU clock with min/max cap; EMC clock.
- GPU memory per process and total.
- Power per INA3221 rail: `node_hwmon_in_volts` × `node_hwmon_curr_amps` for `VDD_IN`, `VDD_CPU_GPU_CV`, `VDD_SOC`, named through `node_hwmon_sensor_label`. The `inN`/`currN` pairing must be checked before the panel is written (labels exist for `in1..in3`; `curr1..curr4` exist).
- Fan PWM and `gpu-thermal` next to them.

### Docs

`docs/src/k8s/nv1-jetson.md`: a "Metrics" section listing the metrics, the alert, the sysfs and debugfs sources (with the r39 paths the first rollout found) and the INA3221 rail names.

## Verification

| Check                                      | How                                                                                                                               |
| ------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| Script output is valid exposition format   | test script against fake trees: devfreq present and absent, each actmon candidate, unreadable files, an `iovmm/maps` sample; `promtool check metrics` |
| Script never writes                        | test runs the script against a read-only fake tree                                                                                |
| Manifests render and validate              | `kubectl kustomize`, `task lint:manifests -- nvidia`, `task lint:all`                                                             |
| Rules parse                                | `promtool check rules` (part of `lint:manifests`)                                                                                 |
| Live, after merge (owner's sync)           | every `source_up` is 1, or the missing source is explained; `jetson_gpu_load_ratio` and `jetson_emc_utilization_ratio` near 0 idle and high during a `llama-server` request; `jetson_gpu_frequency_max_hz` = 918000000; `llama-server` appears in `jetson_gpu_process_memory_bytes` |

The `iovmm/maps` sample format and the actmon scale are taken from jtop's parser until the first rollout shows the real r39 output; the test fixtures are then replaced with real (redacted, if needed) samples.

## Risks

- **Privileged pod on the GPU node.** A bug in it could, in principle, write to the host. Mitigated by read-only mounts, no input to the script, no host namespaces and a single small script reviewed in the PR. It runs the same image and privilege as `jetson-power-mode` today.
- **Reading GPU files may affect power gating.** Reading `load` or devfreq every 15 s might wake a rail-gated GPU or keep it from gating. Check after rollout: idle `VDD_CPU_GPU_CV` power before and after the exporter starts. If it changes, skip GPU reads while `railgate` shows the GPU gated, or lengthen the interval.
- **Paths and formats differ across L4T releases.** All paths come from env vars with r39 defaults; actmon has several candidates; a missing file shows as `source_up 0`.
- **Deploy impact.** Merging deploys a new DaemonSet to nv1 through Argo CD (the `nvidia` app). No change to existing pods, node-exporter or the power cap.

## Pre-check from a privileged session

Run by the owner before implementation, so the script, fixtures and tests are written against real r39 output instead of jtop's assumptions. Every command only reads. It uses the existing `jetson-power-mode` pod, which already mounts `/sys` and debugfs; `kubectl exec` is the owner's action, not this workspace's. Paste this into a Claude session that has `kubectl exec` rights:

```text
Read-only checks on nv1 for .plans/nv1-igpu-metrics/spec.md in mmalyska/home-ops. Do not write to any file, change any setting, or restart anything.
Run each command with: kubectl exec -n nvidia-system ds/jetson-power-mode -c power-mode -- sh -c '<command>'
1. GPU dir: ls -l /sys/devices/platform/bus@0/17000000.gpu/ ; for f in load railgate_enable tpc_pg_mask enable_3d_scaling; do echo "$f=$(cat /sys/devices/platform/bus@0/17000000.gpu/$f 2>&1)"; done
2. devfreq: D=/sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu; ls -l $D; for f in cur_freq min_freq max_freq governor available_frequencies; do echo "$f=$(cat $D/$f 2>&1)"; done; head -5 $D/trans_stat 2>&1
3. File modes: stat -c '%a %U %n' on load, railgate_enable and the devfreq files (is any root-only?).
4. EMC: for f in rate min_rate max_rate; do echo "$f=$(cat /sys/kernel/debug/bpmp/debug/clk/emc/$f 2>&1)"; done
5. actmon candidates: for p in /sys/kernel/debug/cactmon/mc_all /sys/kernel/debug/bpmp/debug/actmon/mc_all_avg_activity /sys/kernel/actmon_avg_activity/mc_all; do echo "$p=$(cat $p 2>&1)"; done
6. nvmap: head -20 /sys/kernel/debug/nvmap/iovmm/maps; tail -3 /sys/kernel/debug/nvmap/iovmm/maps
7. Repeat 1 (load only), 2 (cur_freq only), 4 (rate only) and 5 five times one second apart while a llama-server request runs (send one through LiteLLM or the llm namespace service), and once at idle.
8. hwmon pairing: for h in /sys/class/hwmon/hwmon*; do echo "== $h $(cat $h/name)"; for f in $h/*_label; do echo "$f=$(cat $f)"; done; done
9. busybox: busybox --list | grep -x -e httpd -e awk ; busybox | head -1
Report the raw outputs, then: which actmon path exists; whether mc_all / (rate/1000) gives a 0-100 value that rises under load; the exact iovmm/maps line format and unit; which INA3221 inN/currN belong to VDD_IN, VDD_CPU_GPU_CV, VDD_SOC; any file that is root-only.
```

Hand the report back to the implementing session; it goes into `.plans/nv1-igpu-metrics/evidence.md` and the test fixtures. Process names in `iovmm/maps` are not secret; nothing else in this output is sensitive.

## Open questions

None open. If the pre-check shows no actmon file on r39, EMC utilization drops out of phase 1 and the rest stands.
