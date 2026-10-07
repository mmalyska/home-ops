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
  '+clusterID: c2lkLXZhbHVl' \
  '-clusterSecret: c2VjLXZhbHVl' \
  '       MONITOR ups.example 1 user pass secondary' \
  '+    hostname: mc1' | "$SCRIPTS/mask.sh")"
assert_not_contains "$masked" "LS0tLS1CRUdJTg" "certificate value is masked"
assert_not_contains "$masked" "c2VjcmV0" "private key value is masked"
assert_not_contains "$masked" "abc.def" "token value is masked"
assert_not_contains "$masked" "s3cr3t" "secret value is masked"
assert_not_contains "$masked" "xyz" "secretboxEncryptionSecret value is masked"
assert_not_contains "$masked" "c2lkLXZhbHVl" "clusterID value is masked"
assert_not_contains "$masked" "c2VjLXZhbHVl" "clusterSecret value is masked"
assert_contains "$masked" "-clusterSecret: <masked>" "the key name and diff marker of clusterSecret stay visible"
assert_not_contains "$masked" "ups.example" "nut MONITOR line is masked"
assert_contains "$masked" "+    hostname: mc1" "ordinary lines are untouched"
assert_contains "$masked" "+    crt: <masked>" "the key name and diff marker stay visible"

echo "-- mask.sh block scalars"
# the PEM markers are built here so that this file does not itself look like a private key to gitleaks
PKB="-----BEGIN EC PRIVATE"" KEY-----"; PKE="-----END EC PRIVATE"" KEY-----"
pem="$(printf '%s\n' \
  '@@ -1,3 +1,3 @@' \
  '+  issuingCA:' \
  '+    key: |' \
  '+      '"$PKB"'' \
  '+      FAKEBODYONE' \
  '+' \
  '+      FAKEBODYTWO' \
  '+      '"$PKE"'' \
  '+    cert: |-' \
  '+      FAKECERTBODY' \
  '+    other: kept' \
  ' acceptedCAs:' \
  '-  - |' \
  '-    -----BEGIN CERTIFICATE-----' \
  '-    FAKEACCEPTED' \
  '-    -----END CERTIFICATE-----' \
  '+  - |+' \
  '+    -----BEGIN CERTIFICATE-----' \
  '+    FAKEACCEPTEDTWO' \
  '   after: kept' \
  '+  privateKey: >' \
  '+    FAKEPRIVATE' \
  '+  next: kept' \
  '+  - cert: |' \
  '+      FAKELISTCERT' \
  '+  - name: kept2' | "$SCRIPTS/mask.sh")"
for leak in FAKEBODYONE FAKEBODYTWO FAKECERTBODY FAKEACCEPTED FAKEACCEPTEDTWO FAKEPRIVATE FAKELISTCERT "BEGIN EC PRIVATE KEY" "BEGIN CERTIFICATE" "END EC PRIVATE KEY"; do
  assert_not_contains "$pem" "$leak" "block scalar content [$leak] is not shown"
done
assert_contains "$pem" "+    key: <masked>" "a masked block keeps its key and diff marker"
assert_contains "$pem" "+    cert: <masked>" "the cert key is masked (|- header)"
assert_contains "$pem" "+  privateKey: <masked>" "the privateKey key is masked (> header)"
assert_contains "$pem" "+    other: kept" "the line after a masked block is not masked"
assert_contains "$pem" "   after: kept" "a line at the list level after a PEM list item is not masked"
assert_contains "$pem" "+  next: kept" "the line after a masked folded block is not masked"
assert_contains "$pem" "+  - name: kept2" "a list item after a masked block is not masked"
assert_contains "$pem" "@@ -1,3 +1,3 @@" "hunk headers are kept"

plain="$(printf '%s\n' \
  '+    content: |' \
  '+      [plugins]' \
  '+        option = true' \
  '+    MONITOR: x' | "$SCRIPTS/mask.sh")"
assert_contains "$plain" "[plugins]" "an ordinary block scalar stays visible"
assert_contains "$plain" "option = true" "the whole ordinary block scalar stays visible"

hunk="$(printf '%s\n' '+    key: |' '+      FAKEHUNKBODY' '@@ -9,2 +9,2 @@' '+      visible after hunk' | "$SCRIPTS/mask.sh")"
assert_not_contains "$hunk" "FAKEHUNKBODY" "a block is masked up to the hunk header"
assert_contains "$hunk" "visible after hunk" "a hunk header ends the masked block"

echo "-- mask.sh on a real diff of normalized configs"
printf '%s\n' 'machine:' '  ca:' '    crt: AAAA' > "$TMP/old.yaml"
printf '%s\n' 'kind: Doc' 'apiVersion: v1alpha1' 'issuingCA:' '  key: |' '    '"$PKB"'' '    REALDIFFBODY' '    '"$PKE"'' 'acceptedCAs:' '  - |' '    -----BEGIN CERTIFICATE-----' '    REALDIFFCERT' '    -----END CERTIFICATE-----' > "$TMP/new.yaml"
"$SCRIPTS/normalize.sh" "$TMP/old.yaml" > "$TMP/old.norm"; "$SCRIPTS/normalize.sh" "$TMP/new.yaml" > "$TMP/new.norm"
real="$(diff -u "$TMP/old.norm" "$TMP/new.norm" | "$SCRIPTS/mask.sh")"
assert_contains "$real" "kind: Doc" "the real diff shows ordinary lines"
assert_not_contains "$real" "REALDIFFBODY" "no private key body appears in a masked real diff"
assert_not_contains "$real" "REALDIFFCERT" "no accepted CA body appears in a masked real diff"
assert_not_contains "$real" "-----BEGIN" "no PEM marker appears in a masked real diff"
finish
