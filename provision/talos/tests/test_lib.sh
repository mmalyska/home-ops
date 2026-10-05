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

echo "-- expected-version.sh"
cat > "$TMP/r.yaml" <<'YAML'
version: v1alpha1
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
assert_eq "v1.14.0" "$("$SCRIPTS/expected-version.sh" "$TMP/r.yaml")" "prints the leading Talos version of a custom tag"
assert_fails "fails without an argument" "$SCRIPTS/expected-version.sh"
finish
