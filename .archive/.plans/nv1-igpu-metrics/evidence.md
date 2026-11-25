# Evidence: nv1 pre-check (2026-11-25)

Run by the owner from a session with `kubectl exec`, using the prompt in `spec.md` ("Pre-check from a privileged session"), through the `jetson-power-mode` pod (root in the container). Read-only; the only thing started was a port-forward to `svc/llama-server` for one 400-token chat request in step 7, killed afterwards. Summarized from the owner's report; values are as reported.

## GPU sysfs (`/sys/devices/platform/bus@0/17000000.gpu/`)

- `load` 444, `railgate_enable` 744, `tpc_pg_mask` 744, all root-owned. Idle values: `load=0`, `railgate_enable=0`, `tpc_pg_mask=0`.
- `enable_3d_scaling`: does not exist.
- Also present: `gpu_powered_on`, `is_railgated`, `gpu_temperature_{avg,max,min}`, `nvdec{0,1}_load`, `nvenc{0,1}_load`, `nvjpg0_load`, `ofa_load`, `usage_count`, ECC counters (444), `gpu_flr` (write-only), the `devfreq` directory.

## devfreq (`/sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu`)

- `cur_freq=918000000`, `min_freq=918000000`, `max_freq=918000000`, `governor=performance`: the GPU is pinned at 918 MHz, so `cur_freq` does not vary.
- `available_frequencies`: 306, 408, 510, 612, 714, 816, 918, 1020, 1122, 1173 MHz.
- `trans_stat`: the header runs the last columns together (`918000000102000000011220000001173000000`); not safely parseable.
- Modes: `cur_freq`, `target_freq`, `available_*`, `name` 444; `governor`, `min_freq`, `max_freq`, `trans_stat` 644.

## EMC (debugfs `bpmp/debug/clk/emc`)

`rate=3199000000`, `min_rate=204000000`, `max_rate=3199000000` (Hz).

## actmon

- `/sys/kernel/debug/bpmp/debug/actmon/mc_all_avg_activity` exists (idle sample 222283); the only candidate that does.
- `/sys/kernel/debug/cactmon/mc_all` and `/sys/kernel/actmon_avg_activity/mc_all`: no such file.

## nvmap (`/sys/kernel/debug/nvmap/iovmm/maps`)

```text
CLIENT                        PROCESS      PID        SIZE
                                          BASE        SIZE    FLAGS  SHARE       UID                  MAPS            MAPSIZE
user                     llama-server     3335    4510836K
                                             0       2048K  8000003      1                0                                0K
   ... (one row per allocation; some followed by a map row:)
                                                                                            112b64000   -   112d64000   2048K
...
total                                             4510836K
```

- Process header: `<client> <process> <pid> <size>K`. Allocation rows: `BASE SIZE FLAGS SHARE UID MAPS MAPSIZE`. A mapped allocation is followed by `<start> - <end> <size>K`. Footer `total <size>K`. Unit KiB.

## INA3221 (hwmon2, `ina3221`)

`in1`/`curr1` = `VDD_IN`, `in2`/`curr2` = `VDD_CPU_GPU_CV`, `in3`/`curr3` = `VDD_SOC`; `in7` = sum of shunt voltages; `curr4`, `in4`–`in6` unlabeled. sysfs units mV and mA (node-exporter reports V and A). Other hwmons: `pwmfan`, `usb_charger_0` (no labels), `nvme` (`temp1_label=Composite`).

## busybox

`busybox:1.38` image (BusyBox v1.38.0, 2026-05-13) has `httpd` and `awk`.

## Idle vs load (5 samples, 1 s apart; currents in mA)

| State         | `load`                  | `cur_freq` | EMC `rate` | `mc_all_avg_activity`               | curr1 / curr2 / curr3             |
| ------------- | ----------------------- | ---------- | ---------- | ----------------------------------- | --------------------------------- |
| Idle          | 0 ×5                    | 918000000  | 3199000000 | 120412, 101537, 80198, 77536, 68223 | 1496–1568 / 512–560 / 512–536     |
| Under request | 999, 904, 905, 892, 999 | 918000000  | 3199000000 | 26.8M, 31.6M, 33.6M, 34.4M, 34.7M   | 3232–4408 / 1176–2192 / 1048–1136 |

- `load` 0–1000; 999 ≈ 100 %.
- `mc_all_avg_activity / (rate / 1000)` (jtop's formula): idle ≈ 0.02–0.04, load ≈ 8.4–10.8. Not 0–100, and no divisor in the data makes it a percent. It is a moving average: it climbs over the load samples and decays slowly at idle.
- File modes under `/sys/kernel/debug` on the host were not checked (root in the container).

## Follow-up (2026-11-25, owner, read-only, nothing started)

- `is_railgated=no`, `gpu_powered_on=on`, `usage_count=16`, all mode 444. **The two state files hold words, not 0/1**: the exporter maps `yes`/`no` and `on`/`off` (and accepts `1`/`0`).
- `nvmap/iovmm/maps`: 264 lines, 32,938 bytes, read in about 60 ms (the slowest read; well inside a 15 s scrape).
- `mc_all_avg_activity` (217644) and EMC `rate` together read in under 10 ms.
- The exporter's process-header filter (`NF==4 && $2!="-" && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+K$/`) matched exactly one line, `user llama-server 3335 4510836K`, and nothing else (not allocation rows, map rows, the `total` line or column headers). Its size equals the `total` line. Only one GPU process existed, so the layout with several processes is not seen; the parser sums every header line, which does not depend on what separates them.
- The tail of the file is an allocation row, an empty line, then `total  4510836K`.
- The 25-line raw excerpt asked for in step 3 was not in the pasted report; test fixtures are built from the format above.

## Live checks after rollout (2026-11-25, read-only)

#6466 merged 12:40 UTC (`315d206d`), exporter pod Ready at 12:40:23; #6467 merged 14:02 UTC (`e3b10dbf`), new pod Ready at 14:02:43.

| Check                             | #6466 (process per file, HTTP probes)                            | #6467 (shell `read`, one awk, TCP probes) |
| --------------------------------- | ---------------------------------------------------------------- | ----------------------------------------- |
| Pod Ready, restarts               | yes, 0 (busybox `httpd` CGI through the ConfigMap symlink works) | yes, 0                                    |
| `jetson_exporter_source_up`       | all 9 = 1                                                        | all 9 = 1                                 |
| Scrape duration (max over 15 min) | 0.37 s                                                           | 0.011 s                                   |
| CPU (rate over 10 min)            | 0.0047 cores                                                     | 0.0005 cores                              |
| Throttled CPU periods (15 min)    | 58 %, `CPUThrottlingHigh` (info) firing                          | 0 %, no alert in `nvidia-system`          |
| Working set (max over 15 min)     | 1.8 MB                                                           | 1.4 MB                                    |

- Idle values matched the pre-check: GPU clock 918 MHz (current, min, max), governor `performance`, EMC 3199 MHz (min 204 MHz), load 0, powered on 1, rail-gated 0, both gating settings 0, `llama-server` 4,619,096,064 bytes (= total).
- Load (owner's elevated session, port-forward to `svc/llama-server`): a 13 s request (12:44:29–12:44:42, 400 tokens) was caught by one scrape (12:44:45): load 0.881, EMC activity 31,305,604, relative 9.79. The owner's `max_over_time((…)[5m:])` gave 0.0384: the subquery runs every 30 s (global interval) and skipped that sample. A 60 s request (12:47:19–12:48:19, 1800 tokens at 29.7 tok/s): load 0.90–0.92, EMC activity 34.9M–35.1M, relative 10.90–10.96, idle again within one scrape. GPU memory stayed flat.
- Power: `VDD_CPU_GPU_CV` averaged 2.638 W over 12:05–12:35 (before) and 2.628 W over 12:49–12:57 (after, idle); `VDD_IN` 8.04 W and 7.78 W. Reading the GPU files does not keep the GPU awake.
- Both alert rules loaded, healthy and inactive.
- Argo CD: after #6467 `nvidia` shows OutOfSync on the old ConfigMap `jetson-gpu-exporter-t62mmd9bck`. Every script change makes a ConfigMap with a new hash, and `nvidia` has `prune: false`, so the old one stays until pruned (owner's action). Nothing uses it.
- The workspace could not send the request itself: the `llm` NetworkPolicies drop it and it may not port-forward.
