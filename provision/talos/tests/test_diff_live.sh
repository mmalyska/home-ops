#!/usr/bin/env bash
# Tests for scripts/diff-live.sh and expected_version (lib.sh)
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
source "$SCRIPTS/lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rendered" "$TMP/live"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
YAML
cat > "$TMP/rendered/home-mc1.yaml" <<'YAML'
version: v1alpha1
machine:
  token: sometoken
  sysctls:
    a: "1"
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/abc:v1.14.2
YAML
cp "$TMP/rendered/home-mc1.yaml" "$TMP/live/mc1.yaml"
run() { NODES_FILE="$TMP/nodes.yaml" RENDERED_DIR="$TMP/rendered" LIVE_DIR="$TMP/live" "$SCRIPTS/diff-live.sh" "$@"; }

echo "-- expected_version"
assert_eq "v1.14.2" "$(expected_version "$TMP/rendered/home-mc1.yaml")" "a Factory image tag is the version"
cat > "$TMP/custom.yaml" <<'YAML'
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
assert_eq "v1.14.0" "$(expected_version "$TMP/custom.yaml")" "a custom installer tag yields its leading Talos version"

echo "-- diff"
assert_ok "identical live and repo configs pass" run
out="$(run)"
assert_contains "$out" "mc1: no differences" "reports no differences"

sed -i 's/a: "1"/a: "2"/' "$TMP/live/mc1.yaml"
assert_fails "a differing live config fails" run
assert_contains "$(run 2>&1 || true)" 'a: "' "shows the difference"

sed -i 's/sometoken/othertoken/' "$TMP/live/mc1.yaml"
out="$(run 2>&1 || true)"
assert_not_contains "$out" "sometoken" "never prints the repo-side secret"
assert_not_contains "$out" "othertoken" "never prints the live-side secret"
finish
