#!/bin/sh
# gpu-exporter.sh — Prometheus metrics for the Jetson Orin iGPU, served as a busybox httpd CGI script.
#
# Reads sysfs and debugfs only; never writes. Takes no input: the query string and request body are ignored.
# A file that is missing or unreadable gives jetson_exporter_source_up{source=...} 0 and no value; the
# scrape never fails because of it. Design and the r39 file formats: .plans/nv1-igpu-metrics/spec.md and
# evidence.md (archived under .archive/.plans/ after shipping).
#
# Paths come from env vars with the r39 values as defaults. ROOT prefixes every path (tests use a fake tree).
#
# Cheap on purpose: files are read with the shell's own `read` and the helpers set V instead of printing, so a
# scrape starts one process (awk, for nvmap) instead of one per file. With a process per file the bursts were
# throttled in 58 % of CPU periods under the 100m limit (CPUThrottlingHigh, 2026-11-25).
# Test: bash cluster/apps/system/nvidia/resources/gpu-exporter.test.sh

ROOT="${ROOT:-}"
GPU_DIR="${ROOT}${GPU_DIR:-/sys/devices/platform/bus@0/17000000.gpu}"
DEVFREQ_DIR="${ROOT}${DEVFREQ_DIR:-/sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu}"
EMC_DIR="${ROOT}${EMC_DIR:-/sys/kernel/debug/bpmp/debug/clk/emc}"
ACTMON_FILE="${ROOT}${ACTMON_FILE:-/sys/kernel/debug/bpmp/debug/actmon/mc_all_avg_activity}"
NVMAP_MAPS="${ROOT}${NVMAP_MAPS:-/sys/kernel/debug/nvmap/iovmm/maps}"

SOURCES=""

# up <source> <0|1>: remember the state of one source for jetson_exporter_source_up.
up() { SOURCES="${SOURCES} $1=$2"; }

# line <file>: set V to the first line of the file; fail when it cannot be read or is empty.
line() {
  V=
  { IFS= read -r V <"$1"; } 2>/dev/null || [ -n "${V}" ] || return 1
  [ -n "${V}" ]
}

# num <file>: set V to the file's content if it is a non-negative integer; fail otherwise.
num() {
  line "$1" || return 1
  case "${V}" in *[!0-9]*) return 1 ;; esac
}

# word <file> <true-word> <false-word>: set V to 1 or 0 for a state file that holds words or 1/0.
word() {
  line "$1" || return 1
  case "${V}" in "$2" | 1) V=1 ;; "$3" | 0) V=0 ;; *) return 1 ;; esac
}

# gauge <name> <help> <value>: one family with a single unlabeled sample.
gauge() {
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$1" "$2" "$1" "$1" "$3"
}

printf 'Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n\r\n'

# ── GPU load: 0–1000 (999 is about 100 %) ──────────────────────────────────────
if num "${GPU_DIR}/load"; then
  V="${V#"${V%%[!0]*}"}" # leading zeros would read as octal
  frac=$((${V:-0} % 1000))
  case "${frac}" in ?) frac="00${frac}" ;; ??) frac="0${frac}" ;; esac
  gauge jetson_gpu_load_ratio "GPU load, 0 to 1 (sysfs load / 1000)." "$((${V:-0} / 1000)).${frac}"
  up gpu_load 1
else up gpu_load 0; fi

# ── GPU power state (words) and power-gating settings (numbers) ────────────────
if word "${GPU_DIR}/is_railgated" yes no; then
  gauge jetson_gpu_railgated "1 when the GPU is rail-gated (powered down) right now." "${V}"
  up gpu_railgated 1
else up gpu_railgated 0; fi

if word "${GPU_DIR}/gpu_powered_on" on off; then
  gauge jetson_gpu_powered_on "1 when the GPU is powered on." "${V}"
  up gpu_powered_on 1
else up gpu_powered_on 0; fi

if num "${GPU_DIR}/railgate_enable"; then
  [ "${V}" = 0 ] || V=1
  gauge jetson_gpu_railgate_enabled "1 when GPU rail gating is enabled (setting)." "${V}"
  up gpu_railgate_enable 1
else up gpu_railgate_enable 0; fi

if num "${GPU_DIR}/tpc_pg_mask"; then
  [ "${V}" = 0 ] || V=1
  gauge jetson_gpu_tpc_power_gating_enabled "1 when a TPC power-gating mask is set (setting)." "${V}"
  up gpu_tpc_pg_mask 1
else up gpu_tpc_pg_mask 0; fi

# ── GPU devfreq: created only at the first GPU use after boot (r39) ────────────
if [ -d "${DEVFREQ_DIR}" ]; then
  gauge jetson_gpu_devfreq_present "1 when the GPU devfreq node exists (it appears at the first GPU use after boot)." 1
  if num "${DEVFREQ_DIR}/cur_freq" && cur="${V}" && num "${DEVFREQ_DIR}/min_freq" && min="${V}" &&
    num "${DEVFREQ_DIR}/max_freq" && max="${V}" && line "${DEVFREQ_DIR}/governor" && gov="${V}"; then
    gauge jetson_gpu_frequency_hz "Current GPU clock." "${cur}"
    gauge jetson_gpu_frequency_min_hz "Minimum GPU clock (devfreq min_freq)." "${min}"
    gauge jetson_gpu_frequency_max_hz "Maximum GPU clock (devfreq max_freq); capped by jetson-power-mode." "${max}"
    case "${gov}" in *[!A-Za-z0-9_.-]*) gov=unknown ;; esac
    printf '# HELP jetson_gpu_governor_info GPU devfreq governor.\n# TYPE jetson_gpu_governor_info gauge\n'
    printf 'jetson_gpu_governor_info{governor="%s"} 1\n' "${gov}"
    up gpu_devfreq 1
  else up gpu_devfreq 0; fi
else
  gauge jetson_gpu_devfreq_present "1 when the GPU devfreq node exists (it appears at the first GPU use after boot)." 0
fi

# ── EMC (memory controller): clock and actmon activity, debugfs ────────────────
if num "${EMC_DIR}/rate" && rate="${V}" && num "${EMC_DIR}/min_rate" && min="${V}" && num "${EMC_DIR}/max_rate" && max="${V}"; then
  gauge jetson_emc_frequency_hz "Current EMC (memory) clock." "${rate}"
  gauge jetson_emc_frequency_min_hz "Minimum EMC clock." "${min}"
  gauge jetson_emc_frequency_max_hz "Maximum EMC clock." "${max}"
  up emc_clock 1
else up emc_clock 0; fi

if num "${ACTMON_FILE}"; then
  gauge jetson_emc_activity "EMC actmon mc_all_avg_activity, raw moving average; relative, not a percent." "${V}"
  up emc_activity 1
else up emc_activity 0; fi

# ── GPU memory per process (nvmap iovmm), KiB in the file ──────────────────────
# Process header lines: <client> <process> <pid> <size>K. Allocation rows have 6 or 7 fields (MAPS can be
# empty), address rows have "-" as field 2, the footer is "total <size>K". Summed per process name, without a pid label.
if [ -r "${NVMAP_MAPS}" ] && awk '
    NF == 4 && $2 != "-" && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+K$/ {
      kib = $4; sub(/K$/, "", kib)
      name = $2; gsub(/\\/, "\\\\", name); gsub(/"/, "\\\"", name)
      if (!(name in mem)) order[++n] = name
      mem[name] += kib
      next
    }
    NF == 2 && $1 == "total" && $2 ~ /^[0-9]+K$/ { total = $2; sub(/K$/, "", total) }
    END {
      print "# HELP jetson_gpu_process_memory_bytes GPU (nvmap iovmm) memory per process name."
      print "# TYPE jetson_gpu_process_memory_bytes gauge"
      for (i = 1; i <= n; i++) printf "jetson_gpu_process_memory_bytes{command=\"%s\"} %.0f\n", order[i], mem[order[i]] * 1024
      if (total != "") {
        print "# HELP jetson_gpu_memory_bytes GPU (nvmap iovmm) memory in total."
        print "# TYPE jetson_gpu_memory_bytes gauge"
        printf "jetson_gpu_memory_bytes %.0f\n", total * 1024
      }
    }' "${NVMAP_MAPS}" 2>/dev/null; then
  up nvmap 1
else up nvmap 0; fi

# ── Source health ──────────────────────────────────────────────────────────────
printf '# HELP jetson_exporter_source_up 1 when the source file was read, 0 when missing or unreadable.\n'
printf '# TYPE jetson_exporter_source_up gauge\n'
for s in ${SOURCES}; do
  printf 'jetson_exporter_source_up{source="%s"} %s\n' "${s%=*}" "${s#*=}"
done
