#!/usr/bin/env bash
# Tests for scripts/pki-parity.sh: legacy live configs (v1.13 contract) against the rendered PKI documents.
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rendered" "$TMP/live"

talosctl gen secrets -o "$TMP/secrets.yaml" >/dev/null 2>&1
export SECRETS_FILE="$TMP/secrets.yaml"
export KUBERNETES_VERSION=v1.35.9 TALOS_VERSION=v1.14.2
export TALHELPER_CLUSTERDOMAIN=cluster.test TALHELPER_CLUSTERENDPOINTIP=192.0.2.1
export TALHELPER_UPSMONHOST=ups.test TALHELPER_UPSMONUSER=upsuser TALHELPER_UPSMONPASSWD=upspass
export TALHELPER_CLUSTERNAME="$(printf 'A%.0s' $(seq 43))=" TALHELPER_CLUSTERSECRET="$(printf 'B%.0s' $(seq 43))="
export TALHELPER_AESCBCENCYPTIONKEY="$(yq '.secrets.secretboxencryptionsecret' "$TMP/secrets.yaml")"

# the "live" side: what the nodes run today, the legacy fields from the v1.13 contract
for pair in "mc1 controlplane" "nv1 worker"; do
  set -- $pair
  talosctl gen config home https://cluster.test:6443 --with-secrets "$TMP/secrets.yaml" --talos-version v1.13 --kubernetes-version "$KUBERNETES_VERSION" --output-types "$2" --with-docs=false --with-examples=false -o "$TMP/live/$1.yaml" --force >/dev/null 2>&1
  "$SCRIPTS/render.sh" "$1" "$TMP/rendered/home-$1.yaml" >/dev/null 2>&1
done
run() { RENDERED_DIR="$TMP/rendered" LIVE_DIR="$TMP/live" "$SCRIPTS/pki-parity.sh" "$@"; }

echo "-- legacy fields on the node, documents in the repo"
assert_ok "a control plane with the same values passes" run mc1
out="$(run mc1)"
assert_eq "6" "$(echo "$out" | grep -c ' ok$')" "all six control plane fields compare equal"
assert_not_contains "$out" "absent" "no control plane field is absent on both sides (a broken extraction would show up here)"
assert_ok "a worker with the same values passes" run nv1
out="$(run nv1)"
assert_contains "$out" "nv1: ca_crt ok" "the worker CA certificate equals the accepted CA"
assert_contains "$out" "nv1: ca_key absent" "a worker has no CA key on either side"

echo "-- documents on the node too (after the rollout)"
cp "$TMP/rendered/home-mc1.yaml" "$TMP/live/mc1.yaml"
assert_ok "documents against documents pass" run mc1

echo "-- a difference is found"
cp "$TMP/live/mc1.yaml" "$TMP/keep.yaml"
yq -i '(select(.kind == "KubeAPIServerCAConfig") | .issuingCA.cert) |= sub("A", "B")' "$TMP/live/mc1.yaml"
assert_fails "a changed CA certificate fails" run mc1
assert_contains "$(run mc1 2>&1 || true)" "mc1: ca_crt DIFFERS" "the changed field is named"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
yq -i 'select(.kind != "KubeAggregatorCAConfig")' "$TMP/live/mc1.yaml"
assert_contains "$(run mc1 2>&1 || true)" "mc1: aggregator_crt DIFFERS" "a missing document is a difference"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
yq -i '(select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers[0].secretbox.keys[0].secret) = "AAAA"' "$TMP/live/mc1.yaml"
assert_contains "$(run mc1 2>&1 || true)" "mc1: etcd_encryption_secret DIFFERS" "a changed etcd encryption secret is a difference"

echo "-- no value is ever printed"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
all="$(run mc1 2>&1; run nv1 2>&1)"
assert_not_contains "$all" "BEGIN" "no PEM marker in the output"
assert_not_contains "$all" "$TALHELPER_AESCBCENCYPTIONKEY" "the etcd encryption secret is not in the output"
assert_fails "an unknown node is rejected" run nope
finish
