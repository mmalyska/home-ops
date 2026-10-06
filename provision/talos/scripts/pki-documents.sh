#!/usr/bin/env bash
# pki-documents.sh <controlplane|worker> <secrets-file>
# Print the PKI documents Talos generates for a role from a secrets bundle: KubeAPIServerCAConfig (both roles),
# plus KubeAggregatorCAConfig and KubeServiceAccountConfig for control planes. They come from a second
# `talosctl gen config` with PKI_CONTRACT, because the pinned TALOS_CONTRACT still generates the legacy fields.
# KubeEtcdEncryptionConfig is deliberately not printed: the key name is part of every stored ciphertext, so
# patches/controlplane/95-etcd-encryption.yaml.tpl pins it instead of trusting a generated default.
#
# Needs in the environment: KUBERNETES_VERSION, TALHELPER_CLUSTERDOMAIN.
set -euo pipefail
umask 077
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

role="${1:?usage: pki-documents.sh <controlplane|worker> <secrets-file>}"
secrets="${2:?usage: pki-documents.sh <controlplane|worker> <secrets-file>}"
: "${KUBERNETES_VERSION:?KUBERNETES_VERSION is not set}"
: "${TALHELPER_CLUSTERDOMAIN:?TALHELPER_CLUSTERDOMAIN is not set}"
[ -f "$secrets" ] || die "secrets file not found: $secrets"
case "$role" in
  controlplane) kinds=(KubeAPIServerCAConfig KubeAggregatorCAConfig KubeServiceAccountConfig) ;;
  worker) kinds=(KubeAPIServerCAConfig) ;;
  *) die "unknown role: $role" ;;
esac

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

talosctl gen config "$CLUSTER_NAME" "https://${TALHELPER_CLUSTERDOMAIN}:6443" \
  --with-secrets "$secrets" \
  --talos-version "$PKI_CONTRACT" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --output-types "$role" \
  --with-docs=false --with-examples=false \
  -o "$work/base.yaml" --force >"$work/gen.log" 2>&1 || { cat "$work/gen.log" >&2; die "talosctl gen config ($PKI_CONTRACT) failed"; }

for kind in "${kinds[@]}"; do
  [ "$(yq "select(.kind == \"$kind\") | .kind" "$work/base.yaml" | wc -l | tr -d ' ')" = "1" ] \
    || die "the $PKI_CONTRACT render has no single $kind document for $role"
done
sep=""
for kind in "${kinds[@]}"; do
  [ -z "$sep" ] || echo "$sep"
  yq "select(.kind == \"$kind\")" "$work/base.yaml"
  sep='---'
done
