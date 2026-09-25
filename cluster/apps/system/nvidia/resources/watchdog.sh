#!/bin/sh
# Restarts the Jetson device plugin when the kubelet re-creates kubelet.sock.
#
# The plugin registers with the kubelet once at start and never re-registers.
# Every kubelet restart forgets the registration, leaving the node at
# nvidia.com/gpu: 0. Killing the plugin makes the container restart, which
# registers again. Requires shareProcessNamespace: true on the pod.
SOCK_DIR="${SOCK_DIR:-/var/lib/kubelet/device-plugins}"
PLUGIN_PATTERN="${PLUGIN_PATTERN:-^/jetson-device-plugin$}"
INTERVAL="${INTERVAL:-10}"
KUBELET_SOCK="${SOCK_DIR}/kubelet.sock"

# inode + ctime: an inode number alone can be reused by the next file.
fingerprint() { stat -c '%i:%Z' "${KUBELET_SOCK}" 2>/dev/null || echo none; }

BASE="$(fingerprint)"
echo "watchdog: watching ${KUBELET_SOCK} (baseline ${BASE}), interval ${INTERVAL}s"
while true; do
  sleep "${INTERVAL}"
  NOW="$(fingerprint)"
  # "none" = kubelet still starting; wait for the socket, don't act on a gap.
  if [ "${NOW}" != "none" ] && [ "${NOW}" != "${BASE}" ]; then
    echo "watchdog: kubelet.sock changed (${BASE} -> ${NOW}); restarting plugin"
    pkill -TERM -f "${PLUGIN_PATTERN}" || echo "watchdog: plugin process not found"
    BASE="${NOW}"
  fi
done
