#!/usr/bin/env bash
# Tests for scripts/pki-documents.sh: renders the PKI documents from a throwaway secrets bundle.
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

talosctl gen secrets -o "$TMP/secrets.yaml" >/dev/null 2>&1
export KUBERNETES_VERSION=v1.35.9 TALHELPER_CLUSTERDOMAIN=cluster.test
gen() { "$SCRIPTS/pki-documents.sh" "$1" "$TMP/secrets.yaml"; }
kinds() { yq '.kind' "$1" | grep -v '^---' | tr '\n' ' ' | sed 's/ $//'; }
norm() { tr -d ' \n\r\t'; }

echo "-- control plane"
gen controlplane > "$TMP/cp.yaml"
assert_eq "KubeAPIServerCAConfig KubeAggregatorCAConfig KubeServiceAccountConfig" "$(kinds "$TMP/cp.yaml")" "a control plane gets the CA, aggregator CA and service account documents"
assert_not_contains "$(cat "$TMP/cp.yaml")" "KubeEtcdEncryptionConfig" "the etcd encryption document is never generated (it is pinned in a patch)"
assert_eq "https://cluster.test:6443" "$(yq 'select(.kind == "KubeServiceAccountConfig") | .issuer.issuerURL' "$TMP/cp.yaml")" "the issuer URL is the control plane endpoint"

echo "-- worker"
gen worker > "$TMP/worker.yaml"
assert_eq "KubeAPIServerCAConfig" "$(kinds "$TMP/worker.yaml")" "a worker gets only the API server CA document"
assert_eq "1|none" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | (.acceptedCAs | length | tostring) + "|" + (.issuingCA // "none" | tostring)' "$TMP/worker.yaml")" "a worker gets the accepted CA and no CA key"

echo "-- values equal the legacy fields of the same bundle"
legacy() { talosctl gen config home https://cluster.test:6443 --with-secrets "$TMP/secrets.yaml" --talos-version v1.13 --kubernetes-version "$KUBERNETES_VERSION" --output-types "$1" --with-docs=false --with-examples=false -o "$TMP/legacy-$1.yaml" --force >/dev/null 2>&1; }
legacy controlplane; legacy worker
lv() { yq "select(.machine != null) | $2" "$TMP/legacy-$1.yaml" | base64 -d | norm; }
assert_eq "$(lv controlplane .cluster.ca.crt)" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | .issuingCA.cert' "$TMP/cp.yaml" | norm)" "CA certificate"
assert_eq "$(lv controlplane .cluster.ca.key)" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | .issuingCA.key' "$TMP/cp.yaml" | norm)" "CA key"
assert_eq "$(lv controlplane .cluster.aggregatorCA.crt)" "$(yq 'select(.kind == "KubeAggregatorCAConfig") | .issuingCA.cert' "$TMP/cp.yaml" | norm)" "aggregator CA certificate"
assert_eq "$(lv controlplane .cluster.aggregatorCA.key)" "$(yq 'select(.kind == "KubeAggregatorCAConfig") | .issuingCA.key' "$TMP/cp.yaml" | norm)" "aggregator CA key"
assert_eq "$(lv controlplane .cluster.serviceAccount.key)" "$(yq 'select(.kind == "KubeServiceAccountConfig") | .issuer.privateKey' "$TMP/cp.yaml" | norm)" "service account key"
assert_eq "$(lv worker .cluster.ca.crt)" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | .acceptedCAs[0]' "$TMP/worker.yaml" | norm)" "worker accepted CA is the CA certificate"

echo "-- failure modes"
assert_fails "an unknown role is rejected" "$SCRIPTS/pki-documents.sh" nope "$TMP/secrets.yaml"
assert_fails "a missing secrets file is rejected" "$SCRIPTS/pki-documents.sh" worker "$TMP/none.yaml"
(unset KUBERNETES_VERSION; assert_fails "an unset KUBERNETES_VERSION fails" "$SCRIPTS/pki-documents.sh" worker "$TMP/secrets.yaml")
(PKI_CONTRACT=v1.13; export PKI_CONTRACT; assert_fails "a contract that generates no PKI documents fails instead of printing nothing" "$SCRIPTS/pki-documents.sh" controlplane "$TMP/secrets.yaml")
mkdir -p "$TMP/tmpdir"
TMPDIR="$TMP/tmpdir" "$SCRIPTS/pki-documents.sh" controlplane "$TMP/secrets.yaml" >/dev/null 2>&1
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory is left behind"
(PKI_CONTRACT=v1.13; export PKI_CONTRACT; TMPDIR="$TMP/tmpdir" "$SCRIPTS/pki-documents.sh" controlplane "$TMP/secrets.yaml" >/dev/null 2>&1 || true)
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory is left behind after a failure either"
finish
