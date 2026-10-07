#!/usr/bin/env bash
# isolation-check.sh <node> [on|off]
# Read-only checks that a node runs (on, the default) or does not run (off) its container plane in the sandboxd
# namespace, plus basic health: Talos services, node readiness, Ceph, and etcd on a control plane. Exit 1 when any
# check fails, 2 on a usage error. The namespace is read from /proc/<pid>/status: NSpid lists one PID on the host
# namespace and two inside the sandbox, so a config that says true but was never rebooted still fails.
# Needs yq, talosctl (TALOSCONFIG defaults to clusterconfig/talosconfig) and kubectl on a reachable cluster.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export TALOSCONFIG="${TALOSCONFIG:-$TALOS_DIR/clusterconfig/talosconfig}"

node="${1:-}"; expect="${2:-on}"
[ -n "$node" ] || { echo "usage: isolation-check.sh <node> [on|off]" >&2; exit 2; }
[[ "$expect" == on || "$expect" == off ]] || { echo "expectation must be on or off, got '$expect'" >&2; exit 2; }
ip="$(node_field "$node" ip)"
[ -n "$ip" ] || { echo "unknown node: $node" >&2; exit 2; }
type="$(node_field "$node" type)"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# pid_of <pattern>: PID of the first process whose command line matches
pid_of() { talosctl -n "$ip" processes 2>/dev/null | awk -v pat="$1" '$0 ~ pat { print $2; exit }'; }

# depth_of <pid>: number of PID namespaces the process is in, 1 on the host namespace and 2 inside the sandbox
depth_of() { talosctl -n "$ip" read "/proc/$1/status" 2>/dev/null | awk '/^NSpid:/ { print NF - 1; found = 1 } END { if (!found) print 0 }'; }

want_depth=1; [ "$expect" = on ] && want_depth=2
for proc in "containerd:/bin/containerd --address /run/containerd/containerd.sock" "kubelet:/usr/local/bin/kubelet --"; do
  name="${proc%%:*}"; pattern="${proc#*:}"
  pid="$(pid_of "$pattern")"
  if [ -z "$pid" ]; then bad "$name process not found"; continue; fi
  depth="$(depth_of "$pid")"
  if [ "$depth" = "$want_depth" ]; then
    if [ "$expect" = on ]; then ok "$name runs in the sandbox PID namespace (pid $pid)"; else ok "$name runs in the host PID namespace (pid $pid)"; fi
  elif [ "$expect" = on ]; then bad "$name runs in the sandbox PID namespace (pid $pid has $depth namespace(s), expected 2)"
  else bad "$name runs in the host PID namespace (pid $pid has $depth namespace(s), expected 1)"
  fi
done

# live config: workloadIsolation must be true for on; absent or false for off
live="$(talosctl -n "$ip" get machineconfig v1alpha1 -o yaml 2>/dev/null | yq '.spec' | yq -N 'select(.kind == "SecurityProfileConfig") | .workloadIsolation')"
if [ "$expect" = on ]; then
  [ "$live" = "true" ] && ok "live config has workloadIsolation true" || bad "live config has workloadIsolation true (got '${live:-absent}')"
else
  { [ -z "$live" ] || [ "$live" = "false" ]; } && ok "live config has no isolation (${live:-absent})" || bad "live config has no isolation (got '$live')"
fi

# Talos services: cri and kubelet always, sandboxd when isolation is expected
svc_ok() { talosctl -n "$ip" services 2>/dev/null | awk -v s="$1" '$2 == s && $3 == "Running" && $4 == "OK" { found = 1 } END { exit !found }'; }
for svc in cri kubelet; do
  svc_ok "$svc" && ok "service $svc is Running and OK" || bad "service $svc is Running and OK"
done
if [ "$expect" = on ]; then
  svc_ok sandboxd && ok "service sandboxd is Running and OK" || bad "service sandboxd is Running and OK"
fi

ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "$ready" = "True" ] && ok "node $node is Ready" || bad "node $node is Ready (got '${ready:-unknown}')"

ceph="$(kubectl -n rook-ceph get cephcluster -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null)"
[ "$ceph" = "HEALTH_OK" ] && ok "Ceph is HEALTH_OK" || bad "Ceph is HEALTH_OK (got '${ceph:-unknown}')"

if [ "$type" = controlplane ]; then
  talosctl -n "$ip" etcd status >/dev/null 2>&1 && ok "etcd status answers" || bad "etcd status answers"
fi

[ "$fails" -eq 0 ] || { echo "isolation-check: $fails check(s) failed" >&2; exit 1; }
echo "isolation-check: $node ok ($expect)"
