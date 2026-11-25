#!/usr/bin/env bash
# Behavior test for gpu-exporter.sh: fake sysfs/debugfs trees in the r39 formats (.archive/.plans/nv1-igpu-metrics/evidence.md).
# Run as a non-root user (unreadable-file cases rely on file modes):
#   bash cluster/apps/system/nvidia/resources/gpu-exporter.test.sh
# Uses promtool to validate the exposition format when it is on PATH.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "${TMP}"; rm -rf "${TMP}"' EXIT
FAIL=0

GPU=sys/devices/platform/bus@0/17000000.gpu
DEVFREQ=sys/bus/platform/devices/17000000.gpu/devfreq/17000000.gpu
EMC=sys/kernel/debug/bpmp/debug/clk/emc
ACTMON=sys/kernel/debug/bpmp/debug/actmon/mc_all_avg_activity
MAPS=sys/kernel/debug/nvmap/iovmm/maps

# tree <dir>: a full fake tree, values as seen on nv1 under load (evidence.md).
tree() {
  local r="$1"
  mkdir -p "${r}/${GPU}" "${r}/${DEVFREQ}" "${r}/${EMC}" "$(dirname "${r}/${ACTMON}")" "$(dirname "${r}/${MAPS}")"
  echo 999 >"${r}/${GPU}/load"
  echo no >"${r}/${GPU}/is_railgated"
  echo on >"${r}/${GPU}/gpu_powered_on"
  echo 0 >"${r}/${GPU}/railgate_enable"
  echo 0 >"${r}/${GPU}/tpc_pg_mask"
  echo 918000000 >"${r}/${DEVFREQ}/cur_freq"
  echo 918000000 >"${r}/${DEVFREQ}/min_freq"
  echo 918000000 >"${r}/${DEVFREQ}/max_freq"
  echo performance >"${r}/${DEVFREQ}/governor"
  echo 3199000000 >"${r}/${EMC}/rate"
  echo 204000000 >"${r}/${EMC}/min_rate"
  echo 3199000000 >"${r}/${EMC}/max_rate"
  echo 34700000 >"${r}/${ACTMON}"
  cat >"${r}/${MAPS}" <<'EOF'
CLIENT                        PROCESS      PID        SIZE
                                          BASE        SIZE    FLAGS  SHARE       UID                  MAPS            MAPSIZE
user                     llama-server     3335    4510836K
                                             0       2048K  8000003      1                0                                0K
                                             0       2048K  8000003      1                0                1            2048K
                                                                                            112b64000   -   112d64000   2048K
                                             0         64K  8000003      1                0                                0K

total                                             4510836K
EOF
}

# run <root>: exporter output without the CGI header.
run() { ROOT="$1" QUERY_STRING='x=1' sh "${HERE}/gpu-exporter.sh" </dev/null | sed '1,/^\r*$/d'; }

has() { # name output line
  if grep -qxF -- "$3" <<<"$2"; then echo "PASS $1"; else echo "FAIL $1 (missing: $3)"; FAIL=1; fi
}
hasnt() { # name output regex
  if grep -qE -- "$3" <<<"$2"; then echo "FAIL $1 (unexpected: $3)"; FAIL=1; else echo "PASS $1"; fi
}
valid() { # name output
  command -v promtool >/dev/null || { echo "SKIP $1 (no promtool)"; return; }
  local lint
  if lint=$(promtool check metrics <<<"$2" 2>&1); then echo "PASS $1"; else echo "FAIL $1: ${lint}"; FAIL=1; fi
}

# 1. Full tree, nv1 values under load.
R="${TMP}/full"; tree "${R}"
OUT=$(run "${R}")
has "CGI header first" "$(ROOT="${R}" sh "${HERE}/gpu-exporter.sh" | head -1 | tr -d '\r')" "Content-Type: text/plain; version=0.0.4; charset=utf-8"
has "load 999 -> 0.999" "${OUT}" "jetson_gpu_load_ratio 0.999"
has "is_railgated no -> 0" "${OUT}" "jetson_gpu_railgated 0"
has "gpu_powered_on on -> 1" "${OUT}" "jetson_gpu_powered_on 1"
has "railgate_enable 0" "${OUT}" "jetson_gpu_railgate_enabled 0"
has "tpc_pg_mask 0" "${OUT}" "jetson_gpu_tpc_power_gating_enabled 0"
has "devfreq present" "${OUT}" "jetson_gpu_devfreq_present 1"
has "GPU cur clock" "${OUT}" "jetson_gpu_frequency_hz 918000000"
has "GPU max clock" "${OUT}" "jetson_gpu_frequency_max_hz 918000000"
has "governor label" "${OUT}" 'jetson_gpu_governor_info{governor="performance"} 1'
has "EMC rate, no float rounding" "${OUT}" "jetson_emc_frequency_hz 3199000000"
has "EMC activity raw" "${OUT}" "jetson_emc_activity 34700000"
has "process memory KiB -> bytes" "${OUT}" 'jetson_gpu_process_memory_bytes{command="llama-server"} 4619096064'
has "total memory" "${OUT}" "jetson_gpu_memory_bytes 4619096064"
hasnt "allocation and address rows not parsed as processes" "${OUT}" 'command="(0|112b64000|PROCESS|-)"'
hasnt "every source up" "${OUT}" 'jetson_exporter_source_up\{.*\} 0'
valid "full tree is valid exposition format" "${OUT}"

# 2. Idle after boot: devfreq node not created yet, GPU gated, two GPU processes, words as 1/0.
R="${TMP}/boot"; tree "${R}"
rm -rf "${R:?}/${DEVFREQ}"
echo 0 >"${R}/${GPU}/load"; echo yes >"${R}/${GPU}/is_railgated"; echo off >"${R}/${GPU}/gpu_powered_on"
echo 1 >"${R}/${GPU}/railgate_enable"; echo 3 >"${R}/${GPU}/tpc_pg_mask"
cat >"${R}/${MAPS}" <<'EOF'
CLIENT                        PROCESS      PID        SIZE
user                     llama-server     3335        2048K
                                             0       2048K  8000003      1                0                                0K
user                     llama-server     3400        1024K
                                             0       1024K  8000003      1                0                                0K
user                     my"proc\x         77          10K
                                             0         10K  8000003      1                0                                0K

total                                                 3082K
EOF
OUT=$(run "${R}")
has "devfreq absent -> present 0" "${OUT}" "jetson_gpu_devfreq_present 0"
hasnt "devfreq absent -> no clock metrics" "${OUT}" "^jetson_gpu_frequency|^jetson_gpu_governor_info"
hasnt "devfreq absent is not a source error" "${OUT}" 'source="gpu_devfreq"'
has "is_railgated yes -> 1" "${OUT}" "jetson_gpu_railgated 1"
has "gpu_powered_on off -> 0" "${OUT}" "jetson_gpu_powered_on 0"
has "railgate_enable 1" "${OUT}" "jetson_gpu_railgate_enabled 1"
has "tpc_pg_mask non-zero -> 1" "${OUT}" "jetson_gpu_tpc_power_gating_enabled 1"
has "load 0" "${OUT}" "jetson_gpu_load_ratio 0.000"
has "same name summed across pids" "${OUT}" 'jetson_gpu_process_memory_bytes{command="llama-server"} 3145728'
has "label escaping" "${OUT}" 'jetson_gpu_process_memory_bytes{command="my\"proc\\x"} 10240'
valid "boot tree is valid exposition format" "${OUT}"
echo 1 >"${R}/${GPU}/is_railgated"; echo 0 >"${R}/${GPU}/gpu_powered_on"
OUT=$(run "${R}")
has "is_railgated 1 accepted" "${OUT}" "jetson_gpu_railgated 1"
has "gpu_powered_on 0 accepted" "${OUT}" "jetson_gpu_powered_on 0"

# 3. Missing and unreadable sources.
R="${TMP}/broken"; tree "${R}"
chmod 000 "${R}/${GPU}/load" "${R}/${DEVFREQ}/max_freq" "${R}/${MAPS}"
rm -f "${R}/${ACTMON}" "${R}/${EMC}/rate"
echo maybe >"${R}/${GPU}/is_railgated"
echo 12abc >"${R}/${GPU}/railgate_enable"
OUT=$(run "${R}")
has "unreadable load -> source down" "${OUT}" 'jetson_exporter_source_up{source="gpu_load"} 0'
hasnt "unreadable load -> no value" "${OUT}" "^jetson_gpu_load_ratio "
has "unreadable devfreq file -> source down" "${OUT}" 'jetson_exporter_source_up{source="gpu_devfreq"} 0'
hasnt "unreadable devfreq file -> no partial clocks" "${OUT}" "^jetson_gpu_frequency"
has "missing actmon -> source down" "${OUT}" 'jetson_exporter_source_up{source="emc_activity"} 0'
has "missing EMC rate -> source down" "${OUT}" 'jetson_exporter_source_up{source="emc_clock"} 0'
has "unreadable maps -> source down" "${OUT}" 'jetson_exporter_source_up{source="nvmap"} 0'
has "unknown word -> source down" "${OUT}" 'jetson_exporter_source_up{source="gpu_railgated"} 0'
has "non-numeric value -> source down" "${OUT}" 'jetson_exporter_source_up{source="gpu_railgate_enable"} 0'
has "other sources still up" "${OUT}" 'jetson_exporter_source_up{source="gpu_powered_on"} 1'
valid "broken tree is valid exposition format" "${OUT}"

# 4. Nothing there at all (wrong node or paths).
OUT=$(run "${TMP}/empty")
has "empty tree still answers" "${OUT}" "jetson_gpu_devfreq_present 0"
valid "empty tree is valid exposition format" "${OUT}"

# 5. Read-only: the script must not write to the tree.
R="${TMP}/ro"; tree "${R}"
snapshot() { (cd "$1" && find . -printf '%p %y %m %s %T@\n' && find . -type f -exec md5sum {} +) | sort; }
chmod -R a-w "${R}"
BEFORE=$(snapshot "${R}")
sleep 1
run "${R}" >/dev/null
AFTER=$(snapshot "${R}")
if [ "${BEFORE}" = "${AFTER}" ]; then echo "PASS read-only tree unchanged (content, modes, mtimes)"
else echo "FAIL read-only tree changed"; diff <(echo "${BEFORE}") <(echo "${AFTER}"); FAIL=1; fi

# 6. No process per file: with awk as the only external command, the output is complete and unchanged.
#    (A process per file was throttled under the 100m CPU limit; see the header of gpu-exporter.sh.)
mkdir -p "${TMP}/bin"
ln -s "$(command -v awk)" "${TMP}/bin/awk"
R="${TMP}/full"
FULL=$(run "${R}")
ONLYAWK=$(ROOT="${R}" PATH="${TMP}/bin" "$(command -v sh)" "${HERE}/gpu-exporter.sh" </dev/null 2>&1 | sed '1,/^\r*$/d')
if [ "${ONLYAWK}" = "${FULL}" ]; then echo "PASS only awk is needed"
else echo "FAIL output differs with only awk on PATH"; diff <(echo "${FULL}") <(echo "${ONLYAWK}"); FAIL=1; fi

# 7. Leading zeros are not read as octal.
R="${TMP}/octal"; tree "${R}"; echo 0089 >"${R}/${GPU}/load"
has "leading zeros" "$(run "${R}")" "jetson_gpu_load_ratio 0.089"

[ "${FAIL}" = 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit "${FAIL}"
