#!/usr/bin/env bash
# Tests for scripts/render.sh: renders real nodes with a throwaway secrets bundle and dummy values.
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

talosctl gen secrets -o "$TMP/secrets.yaml" >/dev/null 2>&1
export SECRETS_FILE="$TMP/secrets.yaml"
export KUBERNETES_VERSION=v1.35.9 TALOS_VERSION=v1.14.2
export TALHELPER_CLUSTERDOMAIN=cluster.test TALHELPER_CLUSTERENDPOINTIP=192.0.2.1
export TALHELPER_UPSMONHOST=ups.test TALHELPER_UPSMONUSER=upsuser TALHELPER_UPSMONPASSWD=upspass
export SECRET_SHOULD_NOT_LEAK=leaked

render() { "$SCRIPTS/render.sh" "$1" "$TMP/$1.yaml"; }

echo "-- control plane (mc1)"
assert_ok "mc1 renders" render mc1
assert_ok "mc1 output is a valid metal config" talosctl validate --config "$TMP/mc1.yaml" --mode metal
out="$(cat "$TMP/mc1.yaml")"
assert_contains "$out" "kind: EthernetConfig" "control plane gets the EthernetConfig document"
assert_contains "$out" "kind: ExtensionServiceConfig" "every node gets the nut-client document"
assert_contains "$out" "listen-metrics-urls: http://127.0.0.1:2381" "etcd metrics argument is applied"
assert_eq "192.0.2.1 cluster.test 127.0.0.1" "$(yq 'select(.kind == "KubeAPIServerConfig") | .certExtraSANs | join(" ")' "$TMP/mc1.yaml")" "template variables are substituted in .tpl patches"
assert_contains "$out" "ups.test 1 upsuser upspass secondary" "the nut-client secrets are substituted"
assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/mc1.yaml")" "the install disk selector survives the merge and wipe is false"
assert_eq "null" "$(yq 'select(.machine != null) | .machine.install' "$TMP/mc1.yaml")" "the legacy machine.install block is removed"
assert_eq "node rbac" "$(yq 'select(.kind == "KubeAuthorizerConfig") | .name' "$TMP/mc1.yaml" | grep -v '^---' | tr '\n' ' ' | sed 's/ $//')" "the API server authorizers are node then rbac"
assert_eq "kube-system" "$(yq 'select(.kind == "KubeAdmissionControlConfig") | .configuration.exemptions.namespaces[]' "$TMP/mc1.yaml")" "kube-system is exempt from PodSecurity"
assert_not_contains "$out" "kind: HostnameConfig" "the generated HostnameConfig document is removed"
assert_not_contains "$out" 'exclude-from-external-load-balancers' "the generated load-balancer exclusion label is removed"
assert_not_contains "$out" '${' "no unexpanded variable is left"
assert_eq "600" "$(stat -c '%a' "$TMP/mc1.yaml")" "the rendered file is readable by the owner only"

echo "-- worker (nv1)"
assert_ok "nv1 renders" render nv1
assert_ok "nv1 output is a valid metal config" talosctl validate --config "$TMP/nv1.yaml" --mode metal
out="$(cat "$TMP/nv1.yaml")"
assert_contains "$out" "ghcr.io/schwankner/custom-installer:" "nv1 uses its custom installer image"
assert_not_contains "$out" "factory.talos.dev/metal-installer" "the role image is overridden by the node patch"
assert_contains "$out" "nvidia.com/gpu: present:NoSchedule" "workers get the GPU taint"
assert_not_contains "$out" "kind: EthernetConfig" "workers do not get the control-plane EthernetConfig"
assert_not_contains "$out" "kind: KubeAuthorizerConfig" "workers have no kube-apiserver authorizer documents"
assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/nv1.yaml")" "nv1 keeps the disk selector and wipe false"
assert_eq "ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim" "$(yq 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$TMP/nv1.yaml")" "nv1's custom installer image is carried by the document"

echo "-- failure modes"
(unset TALHELPER_UPSMONHOST; assert_fails "an unset variable used by a .tpl patch fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/unset.yaml")
mkdir -p "$TMP/tmpdir"
TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/clean.yaml" >/dev/null 2>&1
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory (with the secrets bundle) is left behind"
(unset TALHELPER_UPSMONHOST; TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/unset2.yaml" >/dev/null 2>&1 || true)
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory is left behind after a failed render either"

echo "-- safety"
out="$(cat "$TMP/mc1.yaml" "$TMP/nv1.yaml")"
assert_not_contains "$out" "leaked" "variables outside the allowlist are never substituted"
assert_fails "an unknown node is rejected" "$SCRIPTS/render.sh" nope "$TMP/x.yaml"
finish
