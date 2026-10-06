#!/usr/bin/env bash
# pki-parity.sh [node...]
# Prove that the PKI values a node runs equal the ones the repo renders, whichever form each side uses (legacy
# cluster.ca/aggregatorCA/serviceAccount/secretboxEncryptionSecret fields or the PKI documents). Each value is
# decoded, whitespace-normalized and compared by hash; the output is only "<node>: <field> ok|DIFFERS", never a value.
# Exit 1 on any difference. Needs the same environment as render.sh and a reachable cluster.
#
# Test/offline overrides, as in diff-live.sh: RENDERED_DIR (pre-rendered home-<node>.yaml, skips render.sh) and
# LIVE_DIR (<node>.yaml raw live configs, skips talosctl).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TALOSCONFIG="${TALOSCONFIG:-$TALOS_DIR/clusterconfig/talosconfig}"

# field_hash <config> <legacy-yq> <doc-kind> <doc-yq> <b64|plain>: hash of one value, empty-value hash when absent
field_hash() {
  local v
  v="$(yq -N "select(.machine != null) | $2" "$1" 2>/dev/null | grep -v '^null$' | head -c 100000)"
  if [ -n "$v" ]; then
    [ "$5" = b64 ] && v="$(printf '%s' "$v" | base64 -d 2>/dev/null)"
  else
    v="$(yq -N "select(.kind == \"$3\") | $4" "$1" 2>/dev/null | grep -v '^null$')"
  fi
  printf '%s' "$v" | tr -d ' \n\r\t' | sha256sum | cut -d' ' -f1
}

# pki_values <config>: "field hash" lines
pki_values() {
  echo "ca_crt $(field_hash "$1" '.cluster.ca.crt' KubeAPIServerCAConfig '(.issuingCA.cert // .acceptedCAs[0])' b64)"
  echo "ca_key $(field_hash "$1" '.cluster.ca.key' KubeAPIServerCAConfig '.issuingCA.key' b64)"
  echo "aggregator_crt $(field_hash "$1" '.cluster.aggregatorCA.crt' KubeAggregatorCAConfig '.issuingCA.cert' b64)"
  echo "aggregator_key $(field_hash "$1" '.cluster.aggregatorCA.key' KubeAggregatorCAConfig '.issuingCA.key' b64)"
  echo "serviceaccount_key $(field_hash "$1" '.cluster.serviceAccount.key' KubeServiceAccountConfig '.issuer.privateKey' b64)"
  echo "etcd_encryption_secret $(field_hash "$1" '.cluster.secretboxEncryptionSecret' KubeEtcdEncryptionConfig '.config.resources[0].providers[] | select(.secretbox) | .secretbox.keys[0].secret' plain)"
}

nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || mapfile -t nodes < <(node_names)
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

empty="$(printf '' | sha256sum | cut -d' ' -f1)"
status=0
for node in "${nodes[@]}"; do
  ip="$(node_field "$node" ip)"
  [ -n "$ip" ] || { echo "unknown node: $node" >&2; status=1; continue; }

  if [ -n "${RENDERED_DIR:-}" ]; then rendered="$RENDERED_DIR/home-$node.yaml"
  else rendered="$tmp/rendered-$node.yaml"; "$SCRIPTS/render.sh" "$node" "$rendered" || { status=1; continue; }; fi

  if [ -n "${LIVE_DIR:-}" ]; then live="$LIVE_DIR/$node.yaml"
  else live="$tmp/live-$node.yaml"; talosctl get machineconfig v1alpha1 -n "$ip" -o yaml 2>/dev/null | yq '.spec' > "$live" || { echo "$node: cannot read the live config" >&2; status=1; continue; }; fi

  pki_values "$live" > "$tmp/live.vals"
  pki_values "$rendered" > "$tmp/repo.vals"
  while read -r field lhash; do
    rhash="$(awk -v f="$field" '$1 == f {print $2}' "$tmp/repo.vals")"
    if [ "$lhash" != "$rhash" ]; then echo "$node: $field DIFFERS"; status=1
    elif [ "$lhash" = "$empty" ]; then echo "$node: $field absent"   # on both sides, expected for a worker only
    else echo "$node: $field ok"; fi
  done < "$tmp/live.vals"
done
exit $status
