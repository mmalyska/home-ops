#!/usr/bin/env bash
# Tests for scripts/lib.sh helpers and scripts/expected-version.sh
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
export PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml"
source "$SCRIPTS/lib.sh"

echo "-- header_value"
cat > "$TMP/h.yaml" <<'YAML'
# What:   short
# Why:    first line
#         second line
#         third line
# Nodes:  all nodes
# Apply:  live
machine: {}
YAML
assert_eq "short" "$(header_value "$TMP/h.yaml" What)" "reads a one-line value"
assert_eq "first line second line third line" "$(header_value "$TMP/h.yaml" Why)" "joins continuation lines"
assert_eq "live" "$(header_value "$TMP/h.yaml" Apply)" "reads the last header line"
assert_eq "" "$(header_value "$TMP/h.yaml" Missing)" "an absent key is empty"

echo "-- touches"
cat > "$TMP/t1.yaml" <<'YAML'
machine:
  sysctls: {}
cluster:
  etcd: {}
YAML
cat > "$TMP/t2.yaml" <<'YAML'
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
YAML
cat > "$TMP/t3.yaml" <<'YAML'
apiVersion: v1alpha1
kind: HostnameConfig
$patch: delete
YAML
assert_eq "machine.sysctls cluster.etcd" "$(touches "$TMP/t1.yaml" | tr '\n' ' ' | sed 's/ $//')" "legacy shape lists machine.* and cluster.* keys"
assert_eq "EthernetConfig/eth0" "$(touches "$TMP/t2.yaml")" "a named document lists kind/name"
assert_eq "HostnameConfig" "$(touches "$TMP/t3.yaml")" "an unnamed document lists the kind only"

echo "-- patch_files order"
touch "$TMP/p/all/20-b.yaml" "$TMP/p/all/10-a.yaml" "$TMP/p/controlplane/10-c.yaml" "$TMP/p/worker/10-w.yaml" "$TMP/p/node/mc1/10-n.yaml" "$TMP/p/all/readme.txt"
assert_eq "all/10-a.yaml all/20-b.yaml controlplane/10-c.yaml node/mc1/10-n.yaml" \
  "$(patch_files mc1 | sed "s#$TMP/p/##" | tr '\n' ' ' | sed 's/ $//')" "control plane: all, then controlplane, then node, sorted, yaml only"
assert_eq "all/10-a.yaml all/20-b.yaml worker/10-w.yaml" \
  "$(patch_files nv1 | sed "s#$TMP/p/##" | tr '\n' ' ' | sed 's/ $//')" "worker: all, then worker (a missing node directory is skipped)"

echo "-- node_field"
assert_eq "192.168.48.5" "$(node_field nv1 ip)" "reads a field of a node"
assert_eq "" "$(node_field nope ip)" "an unknown node is empty"
assert_eq "" "$(node_field 'mc1") | .ip' ip)" "a node name with yq syntax is matched literally, not evaluated"
sub() { ( "$@" ); }   # die exits, so run it in a subshell
assert_fails "an invalid field name is refused" sub node_field mc1 'ip) | .name'

echo "-- touches on unreadable yaml"
printf 'machine: [unclosed\n' > "$TMP/bad.yaml"
assert_fails "touches fails when yq cannot read the file" touches "$TMP/bad.yaml"

echo "-- expected_version edge cases"
mkimg() { printf 'apiVersion: v1alpha1\nkind: UnattendedInstallConfig\ninstaller:\n  image: %s\n' "$1" > "$TMP/img.yaml"; }
mkimg 'factory.talos.dev/metal-installer/abc:v1.14.2@sha256:0123456789abcdef'
assert_eq "v1.14.2" "$(expected_version "$TMP/img.yaml")" "a digest after the tag is ignored"
mkimg 'registry.local:5000/installer:v1.14.2'
assert_eq "v1.14.2" "$(expected_version "$TMP/img.yaml")" "a registry port is not taken for the tag"
mkimg 'registry.local:5000/installer'
assert_fails "an image without a tag fails" expected_version "$TMP/img.yaml"
assert_contains "$(expected_version "$TMP/img.yaml" 2>&1 || true)" "has no tag" "says the image has no tag"
printf 'apiVersion: v1alpha1\nkind: UnattendedInstallConfig\ninstaller: {}\n' > "$TMP/img.yaml"
assert_fails "an empty installer image fails" expected_version "$TMP/img.yaml"
printf 'version: v1alpha1\nmachine: {}\n' > "$TMP/img.yaml"
assert_fails "a config without the install document fails" expected_version "$TMP/img.yaml"
assert_contains "$(expected_version "$TMP/img.yaml" 2>&1 || true)" "no UnattendedInstallConfig installer.image" "says the install image is missing"

echo "-- expected-version.sh"
cat > "$TMP/r.yaml" <<'YAML'
version: v1alpha1
machine:
  token: sometoken
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
assert_eq "v1.14.0" "$("$SCRIPTS/expected-version.sh" "$TMP/r.yaml")" "prints the leading Talos version of a custom tag"
assert_fails "fails without an argument" "$SCRIPTS/expected-version.sh"
finish
