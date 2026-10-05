#!/usr/bin/env bash
# parity.sh <old-dir> <new-dir>
# Compare home-<node>.yaml for every node in nodes.yaml between two directories, after normalizing both.
# Differences are shown masked (secret values hidden). Exit 1 when any node differs or a file is missing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 2 ] || { echo "usage: parity.sh <old-dir> <new-dir>" >&2; exit 2; }
old="$1"; new="$2"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

status=0
while IFS= read -r node; do
  for side in old new; do
    f="${!side}/home-$node.yaml"
    if [ ! -f "$f" ]; then echo "== $node: missing $f" >&2; status=1; continue 2; fi
    "$SCRIPTS/normalize.sh" "$f" > "$tmp/$side.norm" || { echo "== $node: cannot normalize $f" >&2; status=1; continue 2; }
  done
  if diff -u "$tmp/old.norm" "$tmp/new.norm" > "$tmp/diff.txt"; then
    echo "== $node: identical"
  else
    echo "== $node: DIFFERS"
    "$SCRIPTS/mask.sh" < "$tmp/diff.txt"
    status=1
  fi
done < <(node_names)
exit $status
