#!/usr/bin/env bash
# Relative Markdown links in the instruction files resolve; CLAUDE.md imports AGENTS.md.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

check_links() { # root
  local root="$1" f dir target bad=0
  while IFS= read -r f; do
    dir="$(dirname "$f")"
    while IFS= read -r target; do
      target="${target%%#*}"
      case "$target" in ''|http://*|https://*|mailto:*) continue ;; esac
      if [ ! -e "$dir/$target" ]; then echo "broken link in ${f#"$root"/}: $target"; bad=1; fi
    done < <(grep -o '\]([^)]*)' "$f" | sed 's/^](//; s/)$//')
  done < <(instruction_files "$root")
  return $bad
}
check_import() { grep -qx '@AGENTS.md' "$1/CLAUDE.md"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "all relative links resolve" check_links "$REPO_ROOT"
assert_ok "CLAUDE.md imports AGENTS.md" check_import "$REPO_ROOT"

echo "-- negative fixtures"
fixture "$TMP/a"; printf '\nSee [gone](.agents/policy/missing.md).\n' >> "$TMP/a/AGENTS.md"
assert_fails "broken link is detected" check_links "$TMP/a"
fixture "$TMP/b"; sed -i '/^@AGENTS.md$/d' "$TMP/b/CLAUDE.md"
assert_fails "missing import is detected" check_import "$TMP/b"
finish
