#!/usr/bin/env bash
# explain.sh [--markdown] [node...]
# For each node (default: all), list every patch file in merge order with what it does, what applying
# it costs, what it touches, and which earlier file touches the same top-level item. Reads the file headers; needs yq.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

markdown=0
if [ "${1:-}" = "--markdown" ]; then markdown=1; shift; fi
nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || mapfile -t nodes < <(node_names)

repo_path() { echo "provision/talos/patches/${1#"$PATCHES_DIR"/}"; }
esc() { sed 's/|/\\|/g' <<<"$1"; }

first=1
for node in "${nodes[@]}"; do
  [ "$first" -eq 1 ] || echo
  first=0
  type="$(node_field "$node" type)"
  [ -n "$type" ] || die "unknown node: $node"
  ip="$(node_field "$node" ip)"
  if [ "$markdown" -eq 1 ]; then
    printf '## %s\n\n%s, %s\n\n' "$node" "$type" "$ip"
    printf '| File | What | Apply | Touches | Notes |\n| --- | --- | --- | --- | --- |\n'
  else
    printf '== %s (%s, %s)\n' "$node" "$type" "$ip"
  fi
  declare -A seen=()
  while IFS= read -r f; do
    what="$(header_value "$f" What)"; why="$(header_value "$f" Why)"; apply="$(header_value "$f" Apply)"
    touched_out="$(touches "$f")" || die "cannot read $(repo_path "$f") with yq"
    mapfile -t items <<<"$touched_out"
    [ -n "$touched_out" ] || items=()
    notes=""
    for item in "${items[@]}"; do
      if [ -n "${seen[$item]:-}" ]; then notes="${notes:+$notes; }shares $item with $(repo_path "${seen[$item]}")"; fi
      seen[$item]="$f"
    done
    touched="${items[*]}"
    if [ "$markdown" -eq 1 ]; then
      printf '| `%s` | %s | %s | %s | %s |\n' "$(repo_path "$f")" "$(esc "$what")" "$(esc "$apply")" "$(esc "${touched:-}")" "$(esc "$notes")"
    else
      printf '\n%s\n  what:    %s\n  why:     %s\n  apply:   %s\n  touches: %s\n' "$(repo_path "$f")" "$what" "$why" "$apply" "${touched:-}"
      [ -z "$notes" ] || printf '  notes:   %s\n' "$notes"
    fi
  done < <(patch_files "$node")
  unset seen
done
