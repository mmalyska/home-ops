#!/usr/bin/env bash
# Tests for scripts/explain.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p/all" "$TMP/p/controlplane" "$TMP/p/worker" "$TMP/p/node/mc1"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
  - name: nv1
    ip: 192.168.48.5
    type: worker
YAML
cat > "$TMP/p/all/10-install.yaml" <<'YAML'
# What:   Install target
# Why:    one disk
# Nodes:  all nodes
# Apply:  install-only
machine:
  install:
    disk: /dev/nvme0n1
YAML
cat > "$TMP/p/controlplane/10-rings.yaml" <<'YAML'
# What:   NIC rings | with a pipe
# Why:    drops
#         second line of the reason
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
YAML
cat > "$TMP/p/node/mc1/20-install.yaml" <<'YAML'
# What:   mc1 installs from a custom image
# Why:    custom
# Nodes:  mc1
# Apply:  install-only
machine:
  install:
    image: example.test/custom:v1
YAML
cat > "$TMP/p/worker/10-taint.yaml" <<'YAML'
# What:   taint
# Why:    keep pods off
# Nodes:  workers
# Apply:  live
machine:
  nodeTaints:
    a: b:NoSchedule
YAML
ex() { PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/explain.sh" "$@"; }

echo "-- terminal output"
out="$(ex mc1)"
assert_contains "$out" "mc1" "names the node"
assert_contains "$out" "patches/all/10-install.yaml" "lists the all layer file"
assert_contains "$out" "patches/controlplane/10-rings.yaml" "lists the role layer file"
assert_contains "$out" "patches/node/mc1/20-install.yaml" "lists the node layer file"
assert_contains "$out" "EthernetConfig/eth0" "shows document kind and name"
assert_contains "$out" "machine.install" "shows the legacy field it touches"
assert_contains "$out" "second line of the reason" "joins continuation lines of the reason"
assert_contains "$out" "shares machine.install with provision/talos/patches/all/10-install.yaml" "flags a later file that touches the same item"
assert_not_contains "$out" "10-taint.yaml" "does not list another role's files"

echo "-- node selection"
assert_contains "$(ex nv1)" "10-taint.yaml" "a worker lists the worker layer"
assert_not_contains "$(ex nv1)" "10-rings.yaml" "a worker does not list control-plane files"
assert_contains "$(ex)" "== nv1" "without arguments every node is shown"
assert_fails "an unknown node fails" ex nope

echo "-- markdown output"
md="$(ex --markdown mc1)"
assert_contains "$md" "## mc1" "markdown has a heading per node"
assert_contains "$md" "| File | What | Apply | Touches | Notes |" "markdown has a table header"
assert_contains "$md" 'NIC rings \| with a pipe' "pipes in text are escaped"
finish
