#!/usr/bin/env bash
# Minimal test helpers. Source from a test file, call finish at the end.
FAILS=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1))
  printf '  FAIL %s\n' "$1"
  [ -z "${2:-}" ] || printf '       %s\n' "$2"
}
assert_eq() { # expected actual name
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}
assert_contains() { # haystack needle name
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" "[$2] not found in [$1]" ;; esac
}
assert_not_contains() { # haystack needle name
  case "$1" in *"$2"*) fail "$3" "[$2] found in [$1]" ;; *) pass "$3" ;; esac
}
assert_ok() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}
assert_fails() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}
finish() {
  printf '%s tests, %s failed\n' "$TESTS" "$FAILS"
  [ "$FAILS" -eq 0 ]
}
