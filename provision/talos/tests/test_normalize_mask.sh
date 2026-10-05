#!/usr/bin/env bash
# Tests for scripts/normalize.sh and scripts/mask.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- normalize.sh"
cat > "$TMP/a.yaml" <<'YAML'
# a comment
version: v1alpha1
machine:
  type: worker
  sysctls:
    b: "2"
    a: "1"
---
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 1
YAML
cat > "$TMP/b.yaml" <<'YAML'
apiVersion: v1alpha1
kind: EthernetConfig
rings:
  rx: 1
name: eth0
---
machine:
  sysctls:
    a: "1"
    b: "2"
  type: worker
version: v1alpha1
YAML
assert_eq "$("$SCRIPTS/normalize.sh" "$TMP/a.yaml")" "$("$SCRIPTS/normalize.sh" "$TMP/b.yaml")" \
  "same content in a different document/key order and with comments normalizes identically"

sed 's/"2"/"3"/' "$TMP/a.yaml" > "$TMP/c.yaml"
if [ "$("$SCRIPTS/normalize.sh" "$TMP/a.yaml")" != "$("$SCRIPTS/normalize.sh" "$TMP/c.yaml")" ]; then
  pass "a changed value is still visible after normalizing"
else
  fail "a changed value is still visible after normalizing"
fi

echo "-- mask.sh"
masked="$(printf '%s\n' \
  '+    crt: LS0tLS1CRUdJTg==' \
  '-      key: c2VjcmV0' \
  '     token: abc.def' \
  '+  secret: s3cr3t' \
  '+  secretboxEncryptionSecret: xyz' \
  '       MONITOR ups.example 1 user pass secondary' \
  '+    hostname: mc1' | "$SCRIPTS/mask.sh")"
assert_not_contains "$masked" "LS0tLS1CRUdJTg" "certificate value is masked"
assert_not_contains "$masked" "c2VjcmV0" "private key value is masked"
assert_not_contains "$masked" "abc.def" "token value is masked"
assert_not_contains "$masked" "s3cr3t" "secret value is masked"
assert_not_contains "$masked" "xyz" "secretboxEncryptionSecret value is masked"
assert_not_contains "$masked" "ups.example" "nut MONITOR line is masked"
assert_contains "$masked" "+    hostname: mc1" "ordinary lines are untouched"
assert_contains "$masked" "+    crt: <masked>" "the key name and diff marker stay visible"
finish
