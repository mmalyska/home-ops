#!/usr/bin/env bash
# expected-version.sh <rendered-config>: the Talos version a node should run, from its install image tag.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 1 ] || { echo "usage: expected-version.sh <rendered-config>" >&2; exit 2; }
expected_version "$1"
