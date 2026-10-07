#!/usr/bin/env bash
# normalize.sh <machineconfig.yaml>
# Canonical form of a (multi-document) machine config on stdout: documents sorted by kind/name, keys
# sorted at every depth, comments dropped. Values are kept as they are, so two configs normalize
# equal only if they are semantically equal. Pipe diffs through mask.sh before showing them.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: normalize.sh <machineconfig.yaml>" >&2; exit 2; }
yq ea -o=json '[.]' "$1" \
  | jq -S 'map(select(. != null)) | sort_by((.kind // "v1alpha1") + "/" + (.name // ""))' \
  | yq -P -o=yaml
