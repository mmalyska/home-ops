#!/usr/bin/env bash
# Shared helpers for the Talos render/explain/diff scripts. Source it, do not execute it.

TALOS_DIR="${TALOS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PATCHES_DIR="${PATCHES_DIR:-$TALOS_DIR/patches}"
NODES_FILE="${NODES_FILE:-$TALOS_DIR/nodes.yaml}"

# Talos config contract that `talosctl gen config` is pinned to. It must match what the live nodes
# run: the 1.14 contract generates a fully multi-document base that cannot be mixed with the
# legacy fields still used here. Bump it deliberately, see README.md.
TALOS_CONTRACT="${TALOS_CONTRACT:-v1.13}"
CLUSTER_NAME="${CLUSTER_NAME:-home}"

# The only variables envsubst may replace, and only inside *.yaml.tpl patches.
TPL_VARS='${TALHELPER_CLUSTERENDPOINTIP} ${TALHELPER_CLUSTERDOMAIN} ${TALHELPER_UPSMONHOST} ${TALHELPER_UPSMONUSER} ${TALHELPER_UPSMONPASSWD} ${TALOS_VERSION} ${KUBERNETES_VERSION}'

die() { echo "error: $*" >&2; exit 1; }

# node_field <node> <field>: a field from nodes.yaml (empty when the node does not exist)
node_field() {
  yq -r ".nodes[] | select(.name == \"$1\") | .$2" "$NODES_FILE"
}

# node_names: every node name, one per line
node_names() {
  yq -r '.nodes[].name' "$NODES_FILE"
}

# patch_dirs <node>: the layer directories for a node in merge order (only those that exist)
patch_dirs() {
  local node="$1" type
  type="$(node_field "$node" type)"
  [ -n "$type" ] || die "unknown node: $node"
  local d
  for d in "$PATCHES_DIR/all" "$PATCHES_DIR/$type" "$PATCHES_DIR/node/$node"; do
    [ -d "$d" ] && echo "$d"
  done
  return 0
}

# patch_files <node>: the patch files for a node in merge order, one path per line
patch_files() {
  local d
  while IFS= read -r d; do
    find "$d" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yaml.tpl' \) | LC_ALL=C sort
  done < <(patch_dirs "$1")
}

# header_value <file> <Key>: value of a "# Key: value" header line, continuation lines
# ("#   more text", three or more spaces) joined with single spaces
header_value() {
  awk -v key="$2" '
    BEGIN { pat = "^# " key ":[ ]*" }
    $0 ~ pat { sub(pat, ""); out = $0; found = 1; next }
    found && /^#   [ ]*[^ ]/ { sub(/^#[ ]+/, ""); out = out " " $0; next }
    found { exit }
    END { if (found) print out }
  ' "$1"
}

# touches <file>: what a patch changes, one item per line: Kind/name for a document,
# machine.<key> or cluster.<key> for the legacy v1alpha1 shape
touches() {
  yq -N 'select(.kind != null) | (.kind + "/" + (.name // "")) | sub("/$"; "")' "$1"
  yq -N 'select(.kind == null) | ((.machine // {} | keys | map("machine." + .)) + (.cluster // {} | keys | map("cluster." + .))) | .[]' "$1"
}

# expected_version <rendered-config>: the Talos version a node should run, read from the tag of its
# install image ("v1.14.2" for a Factory image, "v1.14.0" for v1.14.0-6.18.48-nvgpu... custom tags)
expected_version() {
  local image tag
  image="$(yq -N 'select(.machine != null) | .machine.install.image' "$1")"
  tag="${image##*:}"
  echo "${tag%%-*}"
}
