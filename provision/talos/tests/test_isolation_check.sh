#!/usr/bin/env bash
# Tests for scripts/isolation-check.sh with stubbed talosctl and kubectl
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Canned answers, selected by STUB_* variables (defaults describe a healthy isolated node)
cat > "$TMP/bin/talosctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *" processes")
    echo "NODE PID STATE THREADS CPU-TIME VIRTMEM RESMEM ARGS"
    echo "192.168.48.4 135 S 12 1.0 1.5GB 70MB /sbin/sandboxd"
    echo "192.168.48.4 148 S 12 1.0 1.5GB 70MB /bin/containerd --address /system/run/containerd/containerd.sock --state /system/run/containerd --root /system"
    echo "192.168.48.4 48397 S 20 1.0 1.6GB 216MB /bin/containerd --address /run/containerd/containerd.sock --config /etc/cri/containerd.toml"
    echo "192.168.48.4 552 S 105 1.0 5.6GB 230MB /usr/local/bin/kubelet --config=/etc/kubernetes/kubelet.yaml"
    ;;
  *"read /proc/"*)
    # per PID: 148 is the system containerd (always host namespace), 552 the kubelet, anything else the CRI containerd
    args="$*"; pid="${args##*/proc/}"; pid="${pid%%/*}"
    case "$pid" in
      148) v=1 ;;
      552) v="${STUB_NSPID_KUBELET:-${STUB_NSPID:-2}}" ;;
      *) v="${STUB_NSPID:-2}" ;;
    esac
    if [ "$v" = "2" ]; then printf 'Name:\tx\nNSpid:\t%s\t12\n' "$pid"; else printf 'Name:\tx\nNSpid:\t%s\n' "$pid"; fi
    ;;
  *" services")
    echo "NODE SERVICE STATE HEALTH LAST-CHANGE LAST-EVENT"
    echo "192.168.48.4 cri Running OK 1h ok"
    echo "192.168.48.4 kubelet Running OK 1h ok"
    echo "192.168.48.4 sandboxd ${STUB_SANDBOXD:-Running} OK 1h ok"
    ;;
  *"get machineconfig"*)
    echo "spec: |"
    echo "  version: v1alpha1"
    echo "  machine: {}"
    case "${STUB_CONFIG:-true}" in
      none) ;;
      *) printf '  ---\n  apiVersion: v1alpha1\n  kind: SecurityProfileConfig\n  workloadIsolation: %s\n' "${STUB_CONFIG:-true}" ;;
    esac
    ;;
  *"etcd status") exit "${STUB_ETCD_RC:-0}" ;;
esac
SH
cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get node"*) printf '%s' "${STUB_READY:-True}" ;;
  *"get cephcluster"*) printf '%s' "${STUB_CEPH:-HEALTH_OK}" ;;
esac
SH
chmod +x "$TMP/bin/talosctl" "$TMP/bin/kubectl"
cat > "$TMP/run.sh" <<SH
#!/usr/bin/env bash
PATH="$TMP/bin:\$PATH" exec "$SCRIPTS/isolation-check.sh" "\$@"
SH
chmod +x "$TMP/run.sh"
run() { "$TMP/run.sh" "$@"; }

echo "-- a healthy isolated node"
assert_ok "an isolated node passes the check for on" run mc3 on
assert_ok "on is the default expectation" run mc3
out="$(run mc3 on 2>&1)"
assert_contains "$out" "containerd runs in the sandbox PID namespace" "reports the containerd namespace"
assert_contains "$out" "kubelet runs in the sandbox PID namespace" "reports the kubelet namespace"

echo "-- an isolated node checked for off, and the reverse"
assert_fails "isolated processes fail the check for off" env STUB_CONFIG=false "$TMP/run.sh" mc3 off
assert_fails "host processes fail the check for on" env STUB_NSPID=1 "$TMP/run.sh" mc3 on
assert_ok "a node with no document and host processes passes the check for off" env STUB_NSPID=1 STUB_CONFIG=none "$TMP/run.sh" mc3 off
assert_ok "a node with workloadIsolation false and host processes passes the check for off" env STUB_NSPID=1 STUB_CONFIG=false "$TMP/run.sh" mc3 off

echo "-- the kubelet alone in the wrong namespace (the CRI containerd is told apart from the system one)"
out="$(env STUB_NSPID=2 STUB_NSPID_KUBELET=1 "$TMP/run.sh" mc3 on 2>&1 || true)"
assert_contains "$out" "FAIL kubelet runs in the sandbox PID namespace" "a kubelet on the host fails the check for on"
assert_not_contains "$out" "FAIL containerd runs in the sandbox PID namespace" "the CRI containerd is still seen as isolated"
out="$(env STUB_NSPID=1 STUB_NSPID_KUBELET=2 "$TMP/run.sh" mc3 off 2>&1 || true)"
assert_contains "$out" "FAIL kubelet runs in the host PID namespace" "an isolated kubelet fails the check for off"

echo "-- the apply without a reboot (config true, processes still on the host)"
out="$(env STUB_NSPID=1 STUB_CONFIG=true "$TMP/run.sh" mc3 on 2>&1 || true)"
assert_contains "$out" "FAIL containerd runs in the sandbox PID namespace" "the namespace check fails although the config says true"
assert_fails "the apply without a reboot fails the check for on" env STUB_NSPID=1 STUB_CONFIG=true "$TMP/run.sh" mc3 on

echo "-- health"
assert_fails "a stopped sandboxd fails the check for on" env STUB_SANDBOXD=Finished "$TMP/run.sh" mc3 on
assert_fails "a Ceph warning fails the check" env STUB_CEPH=HEALTH_WARN "$TMP/run.sh" mc3 on
assert_fails "a NotReady node fails the check" env STUB_READY=False "$TMP/run.sh" mc3 on
assert_fails "an etcd error on a control plane fails the check" env STUB_ETCD_RC=1 "$TMP/run.sh" mc3 on

echo "-- usage"
assert_fails "an unknown node fails" run nope on
assert_fails "no node fails" run
assert_fails "an unknown expectation fails" run mc3 maybe
finish
