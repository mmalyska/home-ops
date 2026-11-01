#!/usr/bin/env bash
# Run every test_*.sh in this directory. Needs jq and yq (mikefarah v4) on PATH; uses no network.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 2
for tool in jq yq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
status=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
[ "$status" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $status
