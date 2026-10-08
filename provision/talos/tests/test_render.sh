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
export TALHELPER_CLUSTERNAME="$(printf "A%.0s" $(seq 43))=" TALHELPER_CLUSTERSECRET="$(printf "B%.0s" $(seq 43))="
export TALHELPER_AESCBCENCYPTIONKEY="$(yq '.secrets.secretboxencryptionsecret' "$TMP/secrets.yaml")"
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
assert_eq "$TALHELPER_CLUSTERNAME|$TALHELPER_CLUSTERSECRET" "$(yq 'select(.kind == "DiscoveryIdentityConfig") | .clusterID + "|" + .clusterSecret' "$TMP/mc1.yaml")" "the discovery identity is rendered from the TALHELPER variables"
assert_eq "primary|https://discovery.talos.dev/" "$(yq 'select(.kind == "DiscoveryServiceConfig") | .name + "|" + .endpoint' "$TMP/mc1.yaml")" "the discovery service document uses the default endpoint"
assert_eq "false" "$(yq 'select(.machine != null) | .cluster | (has("id") or has("secret") or has("discovery"))' "$TMP/mc1.yaml")" "the legacy cluster.id, cluster.secret and cluster.discovery are removed"
assert_eq "false" "$(yq 'select(.machine != null) | .cluster | (has("ca") or has("aggregatorCA") or has("serviceAccount") or has("secretboxEncryptionSecret"))' "$TMP/mc1.yaml")" "the legacy PKI fields are removed from a control plane"
assert_eq "4" "$(yq 'select(.kind == "KubeAPIServerCAConfig" or .kind == "KubeAggregatorCAConfig" or .kind == "KubeServiceAccountConfig" or .kind == "KubeEtcdEncryptionConfig") | .kind' "$TMP/mc1.yaml" | grep -vc '^---')" "a control plane has the four PKI documents"
assert_eq "key2|secretbox identity" "$(yq 'select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers[0].secretbox.keys[0].name + "|" + (.config.resources[0].providers | map(keys | .[0]) | join(" "))' "$TMP/mc1.yaml")" "the etcd encryption key is named key2 with the identity provider as fallback (never rename: it is part of every stored ciphertext)"
assert_eq "$TALHELPER_AESCBCENCYPTIONKEY" "$(yq 'select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers[0].secretbox.keys[0].secret' "$TMP/mc1.yaml")" "the etcd encryption secret is the bundle's secretbox secret"
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
assert_contains "$out" "ghcr.io/mmalyska/custom-installer:" "nv1 uses its custom installer image"
assert_not_contains "$out" "factory.talos.dev/metal-installer" "the role image is overridden by the node patch"
assert_contains "$out" "nvidia.com/gpu: present:NoSchedule" "workers get the GPU taint"
assert_not_contains "$out" "kind: EthernetConfig" "workers do not get the control-plane EthernetConfig"
assert_not_contains "$out" "kind: KubeAuthorizerConfig" "workers have no kube-apiserver authorizer documents"
assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/nv1.yaml")" "nv1 keeps the disk selector and wipe false"
assert_eq "ghcr.io/mmalyska/custom-installer:v1.14.2-6.18.54-nvgpu39.2.1-jp7" "$(yq 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$TMP/nv1.yaml")" "nv1's custom installer image is carried by the document"
assert_eq "v1.14.2" "$("$SCRIPTS/expected-version.sh" "$TMP/nv1.yaml")" "nv1's expected Talos version is read as v1.14.2 from the custom tag"

assert_eq "1|none|false" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | (.acceptedCAs | length | tostring) + "|" + (.issuingCA // "none" | tostring)' "$TMP/nv1.yaml")|$(yq 'select(.machine != null) | .cluster | has("ca")' "$TMP/nv1.yaml")" "a worker has the accepted CA only and no legacy cluster.ca"
assert_not_contains "$(cat "$TMP/nv1.yaml")" "kind: KubeEtcdEncryptionConfig" "a worker has no etcd encryption document"

echo "-- failure modes"
assert_fails "an unset variable used by a .tpl patch fails the render" env -u TALHELPER_UPSMONHOST "$SCRIPTS/render.sh" mc1 "$TMP/unset.yaml"
assert_fails "an unset cluster secret fails the render" env -u TALHELPER_CLUSTERSECRET "$SCRIPTS/render.sh" mc1 "$TMP/unset3.yaml"
assert_fails "an empty cluster id fails the render" env TALHELPER_CLUSTERNAME= "$SCRIPTS/render.sh" mc1 "$TMP/empty.yaml"
assert_fails "an unset etcd encryption secret fails the render" env -u TALHELPER_AESCBCENCYPTIONKEY "$SCRIPTS/render.sh" mc1 "$TMP/unset4.yaml"
assert_fails "an empty etcd encryption secret fails the render" env TALHELPER_AESCBCENCYPTIONKEY= "$SCRIPTS/render.sh" mc1 "$TMP/empty2.yaml"
assert_fails "a failing PKI document generation fails the render" env PKI_CONTRACT=v1.13 "$SCRIPTS/render.sh" mc1 "$TMP/nopki.yaml"
mkdir -p "$TMP/tmpdir"
TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/clean.yaml" >/dev/null 2>&1
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory (with the secrets bundle) is left behind"
(unset TALHELPER_UPSMONHOST; TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/unset2.yaml" >/dev/null 2>&1 || true)
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory is left behind after a failed render either"

echo "-- install document on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/$n.yaml")" "$n renders the install disk selector and wipe false"
  assert_ok "$n output is a valid metal config (a lost selector fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- safety"
out="$(cat "$TMP/mc1.yaml" "$TMP/nv1.yaml")"
assert_not_contains "$out" "leaked" "variables outside the allowlist are never substituted"
assert_fails "an unknown node is rejected" "$SCRIPTS/render.sh" nope "$TMP/x.yaml"

echo "-- discovery documents on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1 1" "$(yq 'select(.kind == "DiscoveryIdentityConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ') $(yq 'select(.kind == "DiscoveryServiceConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')" "$n has exactly one identity and one service document"
  assert_ok "$n output is a valid metal config (a legacy field left next to the documents fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- PKI documents on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')" "$n has exactly one API server CA document"
  assert_ok "$n output is a valid metal config (a legacy PKI field left next to the documents fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- cluster, time and API access documents"
cluster_name="$(bash -c 'source "$1/lib.sh"; echo "$CLUSTER_NAME"' _ "$SCRIPTS")"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "$cluster_name|https://cluster.test:6443" "$(yq 'select(.kind == "KubeClusterConfig") | .clusterName + "|" + .endpoint' "$TMP/$n.yaml")" "$n has the KubeClusterConfig document with the base cluster name and the endpoint"
  assert_eq "false" "$(yq 'select(.machine != null) | .cluster | (has("clusterName") or has("controlPlane"))' "$TMP/$n.yaml")" "$n has no legacy cluster.clusterName or cluster.controlPlane"
  assert_eq "true|162.159.200.123,162.159.200.1,216.239.35.0,216.239.35.4" "$(yq 'select(.kind == "TimeSyncConfig") | (.enabled | tostring) + "|" + (.ntp.servers | join(","))' "$TMP/$n.yaml")" "$n has the TimeSyncConfig document with the four NTP servers by IP"
  assert_eq "false" "$(yq 'select(.machine != null) | .machine | has("time")' "$TMP/$n.yaml")" "$n has no legacy machine.time"
  assert_eq "false" "$(yq 'select(.machine != null) | (.machine.features // {}) | has("kubernetesTalosAPIAccess")' "$TMP/$n.yaml")" "$n has no legacy kubernetesTalosAPIAccess"
  assert_ok "$n output is a valid metal config (a legacy field left next to its document fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
done
assert_eq "os:etcd:backup|talos-backup" "$(yq 'select(.kind == "KubeTalosAPIAccessConfig") | (.allowedRoles | join(",")) + "|" + (.allowedKubernetesNamespaces | join(","))' "$TMP/mc1.yaml")" "a control plane lets the talos-backup namespace use the etcd backup role"
assert_not_contains "$(cat "$TMP/nv1.yaml")" "kind: KubeTalosAPIAccessConfig" "a worker has no Talos API access document"

echo "-- filesystem trim on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1|168h0m0s" "$(yq 'select(.kind == "FilesystemTrimConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "FilesystemTrimConfig") | .interval' "$TMP/$n.yaml")" "$n has exactly one FilesystemTrimConfig with a weekly interval"
  assert_ok "$n output is a valid metal config" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- containerd config on nv1"
assert_eq "0" "$(yq 'select(.machine != null) | (.machine.files // []) | map(select(.path == "/etc/cri/containerd.toml")) | length' "$TMP/nv1.yaml")" "nv1 does not overwrite /etc/cri/containerd.toml (the generated config already enables CDI)"

echo "-- EPHEMERAL volume config on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1|false" "$(yq 'select(.kind == "VolumeConfig" and .name == "EPHEMERAL") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "VolumeConfig" and .name == "EPHEMERAL") | .mount.secure | tostring' "$TMP/$n.yaml")" "$n has one EPHEMERAL VolumeConfig with mount.secure explicitly false (unset would mean true)"
  assert_ok "$n output is a valid metal config" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- hardware watchdog on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1|/dev/watchdog0|4m0s" "$(yq 'select(.kind == "WatchdogTimerConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "WatchdogTimerConfig") | .device + "|" + .timeout' "$TMP/$n.yaml")" "$n has one WatchdogTimerConfig on /dev/watchdog0 with a 4 minute timeout (nv1's Tegra watchdog accepts at most 255 s)"
  assert_ok "$n output is a valid metal config" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- filesystem scrub (weekly, every node)"
for n in mc1 mc2 mc3 nv1; do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1|168h0m0s" "$(yq 'select(.kind == "FilesystemScrubConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "FilesystemScrubConfig") | .interval' "$TMP/$n.yaml")" "$n has one FilesystemScrubConfig with a 168 hour interval"
  assert_ok "$n output is a valid metal config" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- workload isolation (on for every node)"
source "$SCRIPTS/lib.sh"
for n in mc1 mc2 mc3 nv1; do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1|true" "$(yq 'select(.kind == "SecurityProfileConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "SecurityProfileConfig") | .workloadIsolation | tostring' "$TMP/$n.yaml")" "$n has exactly one SecurityProfileConfig with workloadIsolation true"
  assert_ok "$n output is a valid metal config" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- workload isolation survives the v1.14 contract bump"
# The v1.14 base already carries the document with true. The layer files for each node, applied over that base in
# merge order, must still give true on every node.
gen14="$TMP/gen14"
talosctl gen config isolation-guard https://192.0.2.1:6443 --talos-version v1.14 -o "$gen14" >/dev/null 2>&1
assert_eq "1" "$(yq 'select(.kind == "SecurityProfileConfig") | .kind' "$gen14/worker.yaml" | wc -l | tr -d ' ')" "the v1.14 contract base carries a SecurityProfileConfig (the premise of this guard)"
for n in mc1 mc2 mc3 nv1; do
  cur="$gen14/$(node_field "$n" type).yaml"; i=0
  while IFS= read -r f; do
    i=$((i + 1)); talosctl machineconfig patch "$cur" --patch "@$f" -o "$TMP/g14-$n-$i.yaml" >/dev/null 2>&1; cur="$TMP/g14-$n-$i.yaml"
  done < <(patch_files "$n" | grep '/65-security-profile.yaml$')
  assert_eq "true" "$(yq 'select(.kind == "SecurityProfileConfig") | .workloadIsolation | tostring' "$cur")" "$n keeps workloadIsolation true on a v1.14-contract base"
done
finish
