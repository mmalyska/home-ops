#!/usr/bin/env bash
# Tests for scripts/config-map.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p/all"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
YAML
cat > "$TMP/p/all/10-time.yaml" <<'YAML'
# What:   NTP servers
# Why:    etcd needs time sync
# Nodes:  all nodes
# Apply:  live
machine:
  time:
    disabled: false
YAML
gen() { PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/config-map.sh" "$@"; }

gen "$TMP/map.md"
out="$(cat "$TMP/map.md")"
assert_contains "$out" "# Talos configuration map" "has a title"
assert_contains "$out" "Generated" "says it is generated"
assert_contains "$out" "markdownlint-disable MD013" "disables the line-length rule for the wide tables"
assert_contains "$out" "## mc1" "has a section per node"
assert_contains "$out" "NTP servers" "contains the patch descriptions"

assert_ok "check passes when the file is up to date" gen --check "$TMP/map.md"
sed -i 's/NTP servers/stale text/' "$TMP/map.md"
assert_fails "check fails when the file is stale" gen --check "$TMP/map.md"
assert_fails "check fails when the file is missing" gen --check "$TMP/missing.md"
finish
