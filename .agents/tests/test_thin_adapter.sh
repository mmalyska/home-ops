#!/usr/bin/env bash
# CLAUDE.md is a thin adapter; AGENTS.md stays small, neutral and carries the workflow reference marker.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

MAX_ADAPTER_LINES=40
MAX_AGENTS_LINES=200
MAX_AGENTS_BYTES=20480
# Harness tool names that must not appear in the harness-neutral file.
TOOL_NAMES='Skill tool|AskUserQuestion|TodoWrite|EnterPlanMode|ExitPlanMode|EnterWorktree|Bash\(|SendMessage'

check_adapter_size() { [ "$(wc -l < "$1/CLAUDE.md")" -lt "$MAX_ADAPTER_LINES" ]; }
check_agents_size() {
  [ "$(wc -l < "$1/AGENTS.md")" -lt "$MAX_AGENTS_LINES" ] && [ "$(wc -c < "$1/AGENTS.md")" -lt "$MAX_AGENTS_BYTES" ]
}
check_import() { grep -qx '@AGENTS.md' "$1/CLAUDE.md"; }
check_no_shared_heading() { # root: no heading text appears in both files
  local shared
  shared="$(comm -12 <(grep '^#' "$1/CLAUDE.md" | sed 's/^#* *//' | sort -u) <(grep '^#' "$1/AGENTS.md" | sed 's/^#* *//' | sort -u))"
  [ -z "$shared" ] || { echo "shared headings: $shared"; return 1; }
}
check_no_tool_names() { ! grep -nE "$TOOL_NAMES" "$1/AGENTS.md"; }
check_marker() { [ "$(grep -c 'workflow-ref' "$1/AGENTS.md")" -eq 1 ]; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "CLAUDE.md under $MAX_ADAPTER_LINES lines" check_adapter_size "$REPO_ROOT"
assert_ok "AGENTS.md under $MAX_AGENTS_LINES lines and 20 KiB" check_agents_size "$REPO_ROOT"
assert_ok "CLAUDE.md imports AGENTS.md" check_import "$REPO_ROOT"
assert_ok "no heading shared by CLAUDE.md and AGENTS.md" check_no_shared_heading "$REPO_ROOT"
assert_ok "AGENTS.md names no harness tool" check_no_tool_names "$REPO_ROOT"
assert_ok "AGENTS.md has exactly one workflow-ref marker" check_marker "$REPO_ROOT"

echo "-- negative fixtures"
fixture "$TMP/a"; yes 'filler line' | head -60 >> "$TMP/a/CLAUDE.md"
assert_fails "oversized adapter is detected" check_adapter_size "$TMP/a"
fixture "$TMP/b"; yes 'filler line' | head -250 >> "$TMP/b/AGENTS.md"
assert_fails "oversized AGENTS.md is detected" check_agents_size "$TMP/b"
fixture "$TMP/c"; printf '\n## Verification\n' >> "$TMP/c/CLAUDE.md"
assert_fails "duplicated heading is detected" check_no_shared_heading "$TMP/c"
fixture "$TMP/d"; printf '\nUse the Skill tool.\n' >> "$TMP/d/AGENTS.md"
assert_fails "harness tool name is detected" check_no_tool_names "$TMP/d"
fixture "$TMP/e"; sed -i 's/workflow-ref/x/' "$TMP/e/AGENTS.md"
assert_fails "missing marker is detected" check_marker "$TMP/e"
finish
