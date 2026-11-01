#!/usr/bin/env bash
# Minimal test helpers for the instruction tests. Source from a test file, call finish at the end.
FAILS=0
TESTS=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass() { TESTS=$((TESTS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1))
  printf '  FAIL %s\n' "$1"
  [ -z "${2:-}" ] || printf '       %s\n' "$2"
}
assert_ok() { # name command...
  local name="$1"; shift
  local out
  if out="$("$@" 2>&1)"; then pass "$name"; else fail "$name" "$(printf '%s' "$out" | head -5)"; fi
}
assert_fails() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}
finish() {
  printf '%s tests, %s failed\n' "$TESTS" "$FAILS"
  [ "$FAILS" -eq 0 ]
}

# fixture <dir>: copy the files the instruction tests read into <dir>, with the canonical skills and their generated mirror.
fixture() {
  local dir="$1"
  mkdir -p "$dir/.agents" "$dir/.claude"
  cp "$REPO_ROOT/AGENTS.md" "$REPO_ROOT/CLAUDE.md" "$dir/"
  cp -a "$REPO_ROOT/.agents/README.md" "$REPO_ROOT/.agents/policy" "$dir/.agents/"
  cp "$REPO_ROOT/.claude/settings.json" "$dir/.claude/"
  cp -a "$REPO_ROOT/.agents/skills" "$dir/.agents/"
  cp -a "$REPO_ROOT/.claude/skills" "$dir/.claude/"
  mkdir -p "$dir/docs/src" "$dir/.github/mkdocs" "$dir/.github/workflows"
  cp -a "$REPO_ROOT/docs/src/contributing" "$dir/docs/src/"
  cp "$REPO_ROOT/.github/mkdocs/mkdocs.yml" "$dir/.github/mkdocs/"
  cp "$REPO_ROOT/.github/workflows/docs-build.yaml" "$dir/.github/workflows/"
}

# instruction_files <root>: the markdown files that carry agent instructions, including the public contributing pages.
instruction_files() {
  local root="$1"
  ls "$root/AGENTS.md" "$root/CLAUDE.md" "$root/.agents/README.md" "$root"/.agents/policy/*.md "$root"/docs/src/contributing/*.md
}
