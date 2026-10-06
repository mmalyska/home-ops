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
assert_eq "8" "$(echo "$out" | grep -c ' ok$')" "all eight control plane fields compare equal (key name and provider list included)"
assert_eq "mc1: aescbc absent" "$(echo "$out" | grep absent)" "only the aescbc field is absent on a control plane, as expected"
assert_ok "a worker with the same values passes" run nv1
out="$(run nv1)"
assert_contains "$out" "nv1: ca_crt ok" "the worker CA certificate equals the accepted CA"
assert_contains "$out" "nv1: ca_key absent" "a worker has no CA key on either side"

echo "-- documents on the node too (after the rollout)"
cp "$TMP/rendered/home-mc1.yaml" "$TMP/live/mc1.yaml"
assert_ok "documents against documents pass" run mc1
assert_eq "8" "$(run mc1 | grep -c ' ok$')" "documents against documents compare all eight fields, not vacuously"

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

echo "-- the encryption layout is compared, not just the secret"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
yq -i '(select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers[0].secretbox.keys[0].name) = "key9"' "$TMP/live/mc1.yaml"
assert_fails "a renamed etcd encryption key fails" run mc1
assert_contains "$(run mc1 2>&1 || true)" "mc1: etcd_key_name DIFFERS" "the renamed key is named"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
yq -i '(select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers) |= [.[0]]' "$TMP/live/mc1.yaml"
assert_contains "$(run mc1 2>&1 || true)" "mc1: etcd_providers DIFFERS" "a dropped identity fallback is a difference"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
yq -i '(select(.machine != null) | .cluster.aescbcEncryptionSecret) = "AAAA"' "$TMP/live/mc1.yaml"
yq -i 'select(.kind != "KubeEtcdEncryptionConfig")' "$TMP/live/mc1.yaml"
assert_contains "$(run mc1 2>&1 || true)" "mc1: aescbc DIFFERS" "a legacy aescbc secret on the node is a difference"
echo "-- missing data is a failure, not a pass"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
mkdir -p "$TMP/empty-live" "$TMP/empty-rendered"
assert_fails "missing config files fail instead of printing absent" env RENDERED_DIR="$TMP/empty-rendered" LIVE_DIR="$TMP/empty-live" "$SCRIPTS/pki-parity.sh" mc1
printf 'machine: {}\n' > "$TMP/empty-live/mc1.yaml"; cp "$TMP/empty-live/mc1.yaml" "$TMP/empty-rendered/home-mc1.yaml"
assert_fails "configs with no PKI at all fail on a control plane" env RENDERED_DIR="$TMP/empty-rendered" LIVE_DIR="$TMP/empty-live" "$SCRIPTS/pki-parity.sh" mc1
assert_contains "$(env RENDERED_DIR="$TMP/empty-rendered" LIVE_DIR="$TMP/empty-live" "$SCRIPTS/pki-parity.sh" mc1 2>&1 || true)" "mc1: ca_crt MISSING" "an unexpectedly absent field is named MISSING"
printf 'machine: {}\n' > "$TMP/empty-live/nv1.yaml"; cp "$TMP/empty-live/nv1.yaml" "$TMP/empty-rendered/home-nv1.yaml"
assert_fails "a worker with no CA at all fails" env RENDERED_DIR="$TMP/empty-rendered" LIVE_DIR="$TMP/empty-live" "$SCRIPTS/pki-parity.sh" nv1

echo "-- no value is ever printed"
cp "$TMP/keep.yaml" "$TMP/live/mc1.yaml"
all="$(run mc1 2>&1; run nv1 2>&1)"
assert_not_contains "$all" "BEGIN" "no PEM marker in the output"
assert_not_contains "$all" "$TALHELPER_AESCBCENCYPTIONKEY" "the etcd encryption secret is not in the output"
assert_fails "an unknown node is rejected" run nope
finish
