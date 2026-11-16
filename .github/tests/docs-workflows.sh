#!/usr/bin/env bash
# Maintained invariants for the docs build supply chain. Four checks only:
#   1. every action reference in both docs workflows is pinned to a full commit SHA
#   2. both docs workflows build with --strict
#   3. the publication deploy job needs the build job
#   4. the lock header targets exactly the Python in .github/mkdocs/.python-version
# Check 4 fails closed: a missing or malformed lock header or version file is a failure.
# Usage: bash .github/tests/docs-workflows.sh [repo-root]
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PR_WORKFLOW="$ROOT/.github/workflows/docs-build.yaml"
PUB_WORKFLOW="$ROOT/.github/workflows/publish-pages.yaml"
LOCK="$ROOT/.github/mkdocs/requirements.txt"
PYTHON_FILE="$ROOT/.github/mkdocs/.python-version"

failures=0

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'PASS %s\n' "$1"
}

# 1. Full commit SHA pins for every action in both workflows.
check_sha_pins() {
  local before=$failures workflow name at count=0
  for workflow in "$PR_WORKFLOW" "$PUB_WORKFLOW"; do
    name="${workflow#"$ROOT"/}"
    if [ ! -f "$workflow" ]; then
      fail "sha-pins: $name is missing"
      continue
    fi
    while IFS= read -r at; do
      count=$((count + 1))
      if [ -z "$at" ]; then
        fail "sha-pins: $name has a uses entry without a ref"
        continue
      fi
      case "$at" in
        ./*)
          continue
          ;;
      esac
      if ! printf '%s' "$at" | grep -Eq '^[0-9a-f]{40}$'; then
        fail "sha-pins: $name pins '$at' instead of a full 40-character commit SHA"
      fi
    done < <(grep -hoE '^[[:space:]]*uses:[[:space:]]*[^[:space:]#]+' "$workflow" |
      sed -E 's/^[[:space:]]*uses:[[:space:]]*//' |
      sed -E 's/^.*@//')
  done
  if [ "$count" -eq 0 ]; then
    fail "sha-pins: no action references found in the docs workflows"
  fi
  if [ "$failures" -eq "$before" ]; then
    pass "sha-pins: $count action references in both workflows use full commit SHAs"
  fi
}

# 2. Strict build mode in both workflows.
check_strict_mode() {
  local before=$failures workflow name
  for workflow in "$PR_WORKFLOW" "$PUB_WORKFLOW"; do
    name="${workflow#"$ROOT"/}"
    if [ ! -f "$workflow" ]; then
      fail "strict-mode: $name is missing"
      continue
    fi
    if ! grep -Eq 'mkdocs build[^#]*--strict' "$workflow"; then
      fail "strict-mode: $name has no mkdocs build --strict invocation"
    fi
  done
  if [ "$failures" -eq "$before" ]; then
    pass "strict-mode: both workflows run mkdocs build --strict"
  fi
}

# 3. Publication deploy depends on the build job.
check_deploy_needs_build() {
  local before=$failures needs
  if [ ! -f "$PUB_WORKFLOW" ]; then
    fail "deploy-needs-build: .github/workflows/publish-pages.yaml is missing"
    return
  fi
  needs="$(awk '
    /^  deploy:[[:space:]]*$/ { in_deploy = 1; next }
    in_deploy && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_deploy = 0 }
    in_deploy && /^[[:space:]]+needs:/ { print; exit }
  ' "$PUB_WORKFLOW")"
  if ! printf '%s' "$needs" | grep -Eq '^[[:space:]]+needs:[[:space:]]*(\[)?[[:space:]]*build[[:space:],]?(\])?[[:space:]]*$'; then
    fail "deploy-needs-build: the deploy job in .github/workflows/publish-pages.yaml does not declare needs: build"
  fi
  if [ "$failures" -eq "$before" ]; then
    pass "deploy-needs-build: the publication deploy job declares needs: build"
  fi
}

# 4. Lock header Python equals .github/mkdocs/.python-version. Fails closed.
check_header_python() {
  local before=$failures pin header
  if [ ! -f "$PYTHON_FILE" ]; then
    fail "header-python: .github/mkdocs/.python-version is missing"
    return
  fi
  if [ ! -f "$LOCK" ]; then
    fail "header-python: .github/mkdocs/requirements.txt is missing"
    return
  fi
  pin="$(tr -d '[:space:]' <"$PYTHON_FILE")"
  if ! printf '%s' "$pin" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "header-python: .github/mkdocs/.python-version '$pin' is not an exact major.minor.patch version"
    return
  fi
  header="$(sed -nE 's/.*--python-version=([^[:space:]]+).*/\1/p' "$LOCK" | head -n 1)"
  if [ -z "$header" ]; then
    fail "header-python: the lock header in .github/mkdocs/requirements.txt has no --python-version target"
    return
  fi
  if ! printf '%s' "$header" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "header-python: lock header target '$header' is not an exact major.minor.patch version"
    return
  fi
  if [ "$header" != "$pin" ]; then
    fail "header-python: lock header targets Python $header but .github/mkdocs/.python-version pins $pin; run task mkdocs:lock and commit the regenerated lock"
    return
  fi
  if [ "$failures" -eq "$before" ]; then
    pass "header-python: lock header target $header equals .github/mkdocs/.python-version"
  fi
}

check_sha_pins
check_strict_mode
check_deploy_needs_build
check_header_python

if [ "$failures" -ne 0 ]; then
  printf 'FAILED %d invariant check(s)\n' "$failures" >&2
  exit 1
fi

printf 'PASS all docs workflow invariants\n'
