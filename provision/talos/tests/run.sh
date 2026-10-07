#!/usr/bin/env bash
# Run every tests/test_*.sh. Needs yq (mikefarah v4), jq and talosctl on PATH.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
for tool in yq jq talosctl envsubst; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
status=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit $status
