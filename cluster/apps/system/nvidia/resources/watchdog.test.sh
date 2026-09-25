#!/usr/bin/env bash
# Behavior test for watchdog.sh: a fake socket dir and dummy "plugin" processes.
# Run: bash cluster/apps/system/nvidia/resources/watchdog.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "${TMP}"' EXIT
FAIL=0

check() { # name want(alive|dead) pid
  local got=dead
  kill -0 "$3" 2>/dev/null && got=alive
  if [ "${got}" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got ${got})"; FAIL=1; fi
}
recreate_socket() { sleep 1.1; rm -f "${TMP}/kubelet.sock"; touch "${TMP}/kubelet.sock"; }

touch "${TMP}/kubelet.sock"
SOCK_DIR="${TMP}" PLUGIN_PATTERN='^sleep 4242$' INTERVAL=1 "${HERE}/watchdog.sh" >"${TMP}/wd.log" 2>&1 &

sleep 4242 & P1=$!
sleep 3;            check "no change leaves the plugin running" alive "${P1}"
recreate_socket; sleep 3; check "kubelet.sock re-created restarts the plugin" dead "${P1}"

sleep 4242 & P2=$!
sleep 3;            check "baseline is refreshed after a restart" alive "${P2}"
recreate_socket; sleep 3; check "a second re-creation restarts it again" dead "${P2}"

rm -f "${TMP}/kubelet.sock"; sleep 3
sleep 4242 & P3=$!
sleep 2;            check "missing socket (kubelet starting) is not acted on" alive "${P3}"
sleep 1.1; touch "${TMP}/kubelet.sock"; sleep 3
check "socket reappearing after a gap restarts the plugin" dead "${P3}"

[ "${FAIL}" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; cat "${TMP}/wd.log"; }
exit "${FAIL}"
