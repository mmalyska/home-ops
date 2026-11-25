#!/bin/sh
# gpu-exporter.sh — Prometheus metrics for the Jetson Orin iGPU, served as a busybox httpd CGI script.
#
# Reads sysfs and debugfs only; never writes. Takes no input: the query string and request body are ignored.
# A file that is missing or unreadable gives jetson_exporter_source_up{source=...} 0 and no value; the
# scrape never fails because of it. Design and the r39 file formats: .plans/nv1-igpu-metrics/spec.md and
# evidence.md (archived under .archive/.plans/ after shipping).
#
# Paths come from env vars with the r39 values as defaults. ROOT prefixes every path (tests use a fake tree).
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

# num <file>: print the file's content if it is a non-negative integer; fail otherwise.
num() {
  v=$(cat "$1" 2>/dev/null) || return 1
  case "${v}" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "${v}"
}

# word <file> <true-word> <false-word>: print 1 or 0 for a state file that holds words or 1/0.
word() {
  v=$(cat "$1" 2>/dev/null) || return 1
  case "${v}" in "$2" | 1) printf 1 ;; "$3" | 0) printf 0 ;; *) return 1 ;; esac
}

# gauge <name> <help> <value>: one family with a single unlabeled sample.
gauge() {
  printf '# HELP %s %s\n# TYPE %s gauge\n%s %s\n' "$1" "$2" "$1" "$1" "$3"
}

printf 'Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n\r\n'

# ── GPU load: 0–1000 (999 is about 100 %) ──────────────────────────────────────
if v=$(num "${GPU_DIR}/load"); then
  gauge jetson_gpu_load_ratio "GPU load, 0 to 1 (sysfs load / 1000)." "$(awk -v v="${v}" 'BEGIN { printf "%.3f", v / 1000 }')"
  up gpu_load 1
else up gpu_load 0; fi

# ── GPU power state (words) and power-gating settings (numbers) ────────────────
if v=$(word "${GPU_DIR}/is_railgated" yes no); then
  gauge jetson_gpu_railgated "1 when the GPU is rail-gated (powered down) right now." "${v}"
  up gpu_railgated 1
else up gpu_railgated 0; fi

if v=$(word "${GPU_DIR}/gpu_powered_on" on off); then
  gauge jetson_gpu_powered_on "1 when the GPU is powered on." "${v}"
  up gpu_powered_on 1
else up gpu_powered_on 0; fi

if v=$(num "${GPU_DIR}/railgate_enable"); then
  [ "${v}" = 0 ] || v=1
  gauge jetson_gpu_railgate_enabled "1 when GPU rail gating is enabled (setting)." "${v}"
  up gpu_railgate_enable 1
else up gpu_railgate_enable 0; fi

if v=$(num "${GPU_DIR}/tpc_pg_mask"); then
  [ "${v}" = 0 ] || v=1
  gauge jetson_gpu_tpc_power_gating_enabled "1 when a TPC power-gating mask is set (setting)." "${v}"
  up gpu_tpc_pg_mask 1
else up gpu_tpc_pg_mask 0; fi

# ── GPU devfreq: created only at the first GPU use after boot (r39) ────────────
if [ -d "${DEVFREQ_DIR}" ]; then
  gauge jetson_gpu_devfreq_present "1 when the GPU devfreq node exists (it appears at the first GPU use after boot)." 1
  if cur=$(num "${DEVFREQ_DIR}/cur_freq") && min=$(num "${DEVFREQ_DIR}/min_freq") &&
    max=$(num "${DEVFREQ_DIR}/max_freq") && gov=$(cat "${DEVFREQ_DIR}/governor" 2>/dev/null); then
    gauge jetson_gpu_frequency_hz "Current GPU clock." "${cur}"
    gauge jetson_gpu_frequency_min_hz "Minimum GPU clock (devfreq min_freq)." "${min}"
    gauge jetson_gpu_frequency_max_hz "Maximum GPU clock (devfreq max_freq); capped by jetson-power-mode." "${max}"
    gov=$(printf '%s' "${gov}" | tr -cd 'A-Za-z0-9_.-')
    printf '# HELP jetson_gpu_governor_info GPU devfreq governor.\n# TYPE jetson_gpu_governor_info gauge\n'
    printf 'jetson_gpu_governor_info{governor="%s"} 1\n' "${gov}"
    up gpu_devfreq 1
  else up gpu_devfreq 0; fi
else
  gauge jetson_gpu_devfreq_present "1 when the GPU devfreq node exists (it appears at the first GPU use after boot)." 0
fi

# ── EMC (memory controller): clock and actmon activity, debugfs ────────────────
if rate=$(num "${EMC_DIR}/rate") && min=$(num "${EMC_DIR}/min_rate") && max=$(num "${EMC_DIR}/max_rate"); then
  gauge jetson_emc_frequency_hz "Current EMC (memory) clock." "${rate}"
  gauge jetson_emc_frequency_min_hz "Minimum EMC clock." "${min}"
  gauge jetson_emc_frequency_max_hz "Maximum EMC clock." "${max}"
  up emc_clock 1
else up emc_clock 0; fi

if v=$(num "${ACTMON_FILE}"); then
  gauge jetson_emc_activity "EMC actmon mc_all_avg_activity, raw moving average; relative, not a percent." "${v}"
  up emc_activity 1
else up emc_activity 0; fi

# ── GPU memory per process (nvmap iovmm), KiB in the file ──────────────────────
# Process header lines: <client> <process> <pid> <size>K. Allocation rows have 6 or 7 fields (MAPS can be
# empty), address rows have "-" as field 2, the footer is "total <size>K". Summed per process name, without a pid label.
if [ -r "${NVMAP_MAPS}" ] && maps=$(cat "${NVMAP_MAPS}" 2>/dev/null); then
  printf '%s\n' "${maps}" | awk '
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
    }'
  up nvmap 1
else up nvmap 0; fi

# ── Source health ──────────────────────────────────────────────────────────────
printf '# HELP jetson_exporter_source_up 1 when the source file was read, 0 when missing or unreadable.\n'
printf '# TYPE jetson_exporter_source_up gauge\n'
for s in ${SOURCES}; do
  printf 'jetson_exporter_source_up{source="%s"} %s\n' "${s%=*}" "${s#*=}"
done
