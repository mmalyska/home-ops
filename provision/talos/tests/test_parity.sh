#!/usr/bin/env bash
# Tests for scripts/parity.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/old" "$TMP/new"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
YAML
cat > "$TMP/old/home-mc1.yaml" <<'YAML'
version: v1alpha1
machine:
  token: oldtoken
  sysctls:
    a: "1"
cluster:
  id: thecluster
YAML
cp "$TMP/old/home-mc1.yaml" "$TMP/new/home-mc1.yaml"
run() { NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/parity.sh" "$TMP/old" "$TMP/new"; }

assert_ok "identical configs pass" run
cat > "$TMP/new/home-mc1.yaml" <<'YAML'
cluster:
  id: thecluster
machine:
  sysctls:
    a: "1"
  token: oldtoken
version: v1alpha1
YAML
assert_ok "the same config in a different key order passes" run

sed -i 's/a: "1"/a: "2"/' "$TMP/new/home-mc1.yaml"
assert_fails "a changed value fails" run
out="$(run 2>&1 || true)"
assert_contains "$out" 'a: "2"' "the difference is shown"

sed -i 's/oldtoken/newtoken/' "$TMP/new/home-mc1.yaml"
out="$(run 2>&1 || true)"
assert_not_contains "$out" "newtoken" "a changed secret is not printed"
assert_not_contains "$out" "oldtoken" "the old secret is not printed either"
assert_contains "$out" "token: <masked>" "a changed secret still shows as a masked change"

rm "$TMP/new/home-mc1.yaml"
assert_fails "a missing rendered file fails" run
finish
