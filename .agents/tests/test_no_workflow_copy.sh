#!/usr/bin/env bash
# The instruction files refer to the workflow; they must not restate it.
# A line may name at most one process level and at most one topology, and must not spell out the lifecycle.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

LEVELS='QUICK STANDARD DEEP'
TOPOLOGIES='SOLO HANDOFF PARALLEL REVIEW'

check_no_copy() { # root
  local root="$1" f line word n bad=0
  while IFS= read -r f; do
    while IFS= read -r line; do
      for group in "$LEVELS" "$TOPOLOGIES"; do
        n=0
        for word in $group; do
          printf '%s' "$line" | grep -qw "$word" && n=$((n + 1))
        done
        if [ "$n" -gt 1 ]; then echo "${f#"$root"/}: line names several of [$group]: $line"; bad=1; fi
      done
      if printf '%s' "$line" | grep -qE 'Spec *(→|->|>) *Plan *(→|->|>) *Build'; then
        echo "${f#"$root"/}: lifecycle spelled out: $line"; bad=1
      fi
    done < "$f"
  done < <(instruction_files "$root")
  return $bad
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "no workflow definitions in instruction files" check_no_copy "$REPO_ROOT"

echo "-- negative fixtures"
fixture "$TMP/a"; printf '\nProfiles: QUICK, STANDARD and DEEP.\n' >> "$TMP/a/AGENTS.md"
assert_fails "list of process levels is detected" check_no_copy "$TMP/a"
fixture "$TMP/b"; printf '\nTopologies: SOLO or HANDOFF.\n' >> "$TMP/b/.agents/README.md"
assert_fails "list of topologies is detected" check_no_copy "$TMP/b"
fixture "$TMP/c"; printf '\nLifecycle: Spec → Plan → Build → Test.\n' >> "$TMP/c/CLAUDE.md"
assert_fails "spelled-out lifecycle is detected" check_no_copy "$TMP/c"
finish
