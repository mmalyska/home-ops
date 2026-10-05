#!/usr/bin/env bash
# diff-live.sh [node...]
# Compare what the repo renders with what each node runs (machine config), and the running Talos
# version with the expected one. Differences are masked (secret values hidden). Exit 1 on any
# difference or version mismatch. Needs the same environment as render.sh and a reachable cluster.
#
# Test/offline overrides: RENDERED_DIR (pre-rendered home-<node>.yaml files, skips render.sh) and
# LIVE_DIR (<node>.yaml raw live configs, skips talosctl and the version check).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TALOSCONFIG="${TALOSCONFIG:-$TALOS_DIR/clusterconfig/talosconfig}"

nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || mapfile -t nodes < <(node_names)
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

status=0
for node in "${nodes[@]}"; do
  ip="$(node_field "$node" ip)"
  [ -n "$ip" ] || { echo "unknown node: $node" >&2; status=1; continue; }

  if [ -n "${RENDERED_DIR:-}" ]; then rendered="$RENDERED_DIR/home-$node.yaml"
  else rendered="$tmp/rendered-$node.yaml"; "$SCRIPTS/render.sh" "$node" "$rendered" || { status=1; continue; }; fi

  if [ -n "${LIVE_DIR:-}" ]; then live="$LIVE_DIR/$node.yaml"
  else live="$tmp/live-$node.yaml"; talosctl get machineconfig -n "$ip" -o yaml 2>/dev/null | yq '.spec' > "$live" || { echo "$node: cannot read the live config" >&2; status=1; continue; }; fi

  "$SCRIPTS/normalize.sh" "$live" > "$tmp/live.norm" && "$SCRIPTS/normalize.sh" "$rendered" > "$tmp/repo.norm" \
    || { echo "$node: cannot normalize" >&2; status=1; continue; }
  if diff -u "$tmp/live.norm" "$tmp/repo.norm" > "$tmp/diff.txt"; then
    echo "$node: no differences"
  else
    echo "$node: live (-) differs from the repo (+)"
    "$SCRIPTS/mask.sh" < "$tmp/diff.txt"
    status=1
  fi

  if [ -z "${LIVE_DIR:-}" ]; then
    want="$(expected_version "$rendered")"
    have="$(talosctl version -n "$ip" 2>/dev/null | sed -n '/Server:/,$p' | sed -n 's/^[[:space:]]*Tag:[[:space:]]*//p' | head -1)"
    if [ "$have" = "$want" ]; then echo "$node: running $have"
    else echo "$node: running ${have:-unknown}, expected $want"; status=1; fi
  fi
done
exit $status
