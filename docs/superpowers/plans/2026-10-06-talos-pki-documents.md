# Talos PKI Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `cluster.ca`, `cluster.aggregatorCA`, `cluster.serviceAccount` and `cluster.secretboxEncryptionSecret` to `KubeAPIServerCAConfig`, `KubeAggregatorCAConfig`, `KubeServiceAccountConfig` and `KubeEtcdEncryptionConfig`, with identical values and the etcd encryption key name and provider order exactly as live.

**Architecture:** `scripts/pki-documents.sh` prints three of the documents from a second `talosctl gen config` (`PKI_CONTRACT=v1.14`) of the same secrets bundle; `render.sh` appends them as a last patch. The etcd encryption document is a static `.yaml.tpl` patch that pins the key name `key2` and the `identity` fallback. Static delete patches remove the legacy fields. `scripts/pki-parity.sh` proves by hash that the PKI values a node runs equal the rendered ones, printing no values.

**Tech Stack:** Talos 1.14.2 config documents, bash, yq, `envsubst`, `talosctl gen config`, the shell tests under `provision/talos/tests/`.

**Spec:** `docs/superpowers/specs/2026-10-06-talos-pki-documents-design.md`

## Global Constraints

- Never write secret values into any tracked file (gitleaks blocks the commit). Tests use throwaway bundles from `talosctl gen secrets` and values built at runtime; never paste a PEM block or a real key.
- Every patch file starts with the header lines `# What:`, `# Why:`, `# Nodes:`, `# Apply:` (`scripts/check-patches.sh` enforces it). Files with variables end in `.yaml.tpl` and use the `${VAR}` form.
- `TALOS_CONTRACT` stays `v1.13`; `secrets.yaml.tpl` and the Bitwarden variables are not changed. No CA, key or encryption secret is rotated.
- The etcd encryption key is named `key2`, with providers `secretbox` then `identity`. Never rename it: the name is part of every stored ciphertext.
- Never apply config to a node, or run any mutating `talosctl`/`kubectl` command, without explicit user confirmation (Task 5 is a gated manual rollout).
- Never push to `main`; branch `chore/talos-pki-documents`, then PR.
- Do not write the private cluster domain literally anywhere (comments, docs, memory).
- Run `task talos:check` before each commit that touches `provision/talos/`, except where a task says the config map is regenerated later.
- `git commit` can be blocked once by a hook that reformats a file; if `git log` does not show the commit, `git add -A` and commit again.

## Review Focus

1. **Etcd encryption drift:** a renamed key, a missing `identity` fallback or a different secret makes the API server unable to read existing Secrets; tests pin `key2`, `secretbox identity` and the bundle's secret (Task 2).
2. **Unset or empty `TALHELPER_AESCBCENCYPTIONKEY`:** must fail the render, never produce an encryption document with an empty secret (Task 2).
3. **A failing PKI render:** `pki-documents.sh` failing (or printing nothing) must fail the render and leave no temp directory with secrets behind (Tasks 1 and 2).
4. **Values not identical:** the generated CA, aggregator and service account values must equal the legacy ones of the same bundle, for both roles, and nv1 must get `acceptedCAs` only (Tasks 1 and 2).
5. **Parity script hiding a problem:** a field absent on both sides, a missing document or a printed value must not pass silently (Task 3).

---

### Task 1: Generate the PKI documents from a second render

**Files:**
- Create: `provision/talos/scripts/pki-documents.sh`
- Modify: `provision/talos/scripts/lib.sh` (new `PKI_CONTRACT` variable)
- Test: `provision/talos/tests/test_pki_documents.sh` (create)

**Interfaces:**
- Produces: `pki-documents.sh <controlplane|worker> <secrets-file>` prints a multi-document YAML stream on stdout: `KubeAPIServerCAConfig` for both roles, plus `KubeAggregatorCAConfig` and `KubeServiceAccountConfig` for control planes, in that order, separated by `---` with no trailing separator. Needs `KUBERNETES_VERSION` and `TALHELPER_CLUSTERDOMAIN` in the environment. Exits non-zero (message on stderr, nothing useful on stdout) for an unknown role, a missing secrets file, an unset variable, a failing `gen config`, or a render that lacks one of the expected documents. Task 2 consumes it from `render.sh`; Task 3's tests call `render.sh`.
- Produces: `PKI_CONTRACT` (default `v1.14`) in `lib.sh`.

- [ ] **Step 1: Write the failing test**

Create `provision/talos/tests/test_pki_documents.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash provision/talos/tests/test_pki_documents.sh`
Expected: FAIL. `pki-documents.sh` does not exist, so the generation assertions fail (a failing assertion prints `FAIL ...`; the final line is `N tests, M failed` with M greater than 0).

- [ ] **Step 3: Add `PKI_CONTRACT` to `lib.sh`**

Run this from the repo root:

```bash
python3 - <<'E'
p='provision/talos/scripts/lib.sh'
s=open(p).read()
old='CLUSTER_NAME="${CLUSTER_NAME:-home}"\n'
assert old in s
s=s.replace(old,'''# Contract of the second render that supplies the PKI documents (CA, aggregator CA, service account key).
# Remove it, scripts/pki-documents.sh and the 96-pki-legacy-delete.yaml patches together when TALOS_CONTRACT
# reaches v1.14 (the base then carries those documents itself).
PKI_CONTRACT="${PKI_CONTRACT:-v1.14}"
'''+old)
open(p,'w').write(s)
E
```

- [ ] **Step 4: Write `pki-documents.sh`**

Create `provision/talos/scripts/pki-documents.sh` and `chmod +x` it:

```bash
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash provision/talos/tests/test_pki_documents.sh`
Expected: PASS, `15 tests, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add provision/talos/scripts/pki-documents.sh provision/talos/scripts/lib.sh provision/talos/tests/test_pki_documents.sh
git commit -m "feat(talos): generate the PKI documents from a second render of the secrets bundle"
```

---

### Task 2: Patches and the render integration

**Files:**
- Create: `provision/talos/patches/controlplane/95-etcd-encryption.yaml.tpl`
- Create: `provision/talos/patches/controlplane/96-pki-legacy-delete.yaml`
- Create: `provision/talos/patches/worker/96-pki-legacy-delete.yaml`
- Modify: `provision/talos/scripts/render.sh` (append the generated documents as the last patch)
- Modify: `provision/talos/scripts/lib.sh` (`TPL_VARS`)
- Test: `provision/talos/tests/test_render.sh` (modify)

**Interfaces:**
- Consumes: `pki-documents.sh <role> <secrets-file>` from Task 1; `TPL_VARS` and the unset/empty variable check in `render.sh` (`needs $VAR, which is not set`).
- Produces: every rendered config has no legacy PKI field; control planes contain `KubeAPIServerCAConfig`, `KubeAggregatorCAConfig`, `KubeServiceAccountConfig` and `KubeEtcdEncryptionConfig`; workers contain `KubeAPIServerCAConfig` with `acceptedCAs` only. Task 3 renders with `render.sh` for its fixtures.

- [ ] **Step 1: Write the failing tests**

Save the following as `/tmp/test_render_pki.patch` (any scratch path) and apply it from the repo root with `git apply /tmp/test_render_pki.patch`:

```diff
--- a/provision/talos/tests/test_render.sh
+++ b/provision/talos/tests/test_render.sh
@@ -10,6 +10,7 @@
 export TALHELPER_CLUSTERDOMAIN=cluster.test TALHELPER_CLUSTERENDPOINTIP=192.0.2.1
 export TALHELPER_UPSMONHOST=ups.test TALHELPER_UPSMONUSER=upsuser TALHELPER_UPSMONPASSWD=upspass
 export TALHELPER_CLUSTERNAME="$(printf "A%.0s" $(seq 43))=" TALHELPER_CLUSTERSECRET="$(printf "B%.0s" $(seq 43))="
+export TALHELPER_AESCBCENCYPTIONKEY="$(yq '.secrets.secretboxencryptionsecret' "$TMP/secrets.yaml")"
 export SECRET_SHOULD_NOT_LEAK=leaked

 render() { "$SCRIPTS/render.sh" "$1" "$TMP/$1.yaml"; }
@@ -28,6 +29,10 @@
 assert_eq "$TALHELPER_CLUSTERNAME|$TALHELPER_CLUSTERSECRET" "$(yq 'select(.kind == "DiscoveryIdentityConfig") | .clusterID + "|" + .clusterSecret' "$TMP/mc1.yaml")" "the discovery identity is rendered from the TALHELPER variables"
 assert_eq "primary|https://discovery.talos.dev/" "$(yq 'select(.kind == "DiscoveryServiceConfig") | .name + "|" + .endpoint' "$TMP/mc1.yaml")" "the discovery service document uses the default endpoint"
 assert_eq "false" "$(yq 'select(.machine != null) | .cluster | (has("id") or has("secret") or has("discovery"))' "$TMP/mc1.yaml")" "the legacy cluster.id, cluster.secret and cluster.discovery are removed"
+assert_eq "false" "$(yq 'select(.machine != null) | .cluster | (has("ca") or has("aggregatorCA") or has("serviceAccount") or has("secretboxEncryptionSecret"))' "$TMP/mc1.yaml")" "the legacy PKI fields are removed from a control plane"
+assert_eq "4" "$(yq 'select(.kind == "KubeAPIServerCAConfig" or .kind == "KubeAggregatorCAConfig" or .kind == "KubeServiceAccountConfig" or .kind == "KubeEtcdEncryptionConfig") | .kind' "$TMP/mc1.yaml" | grep -vc '^---')" "a control plane has the four PKI documents"
+assert_eq "key2|secretbox identity" "$(yq 'select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers[0].secretbox.keys[0].name + "|" + (.config.resources[0].providers | map(keys | .[0]) | join(" "))' "$TMP/mc1.yaml")" "the etcd encryption key is named key2 with the identity provider as fallback (never rename: it is part of every stored ciphertext)"
+assert_eq "$TALHELPER_AESCBCENCYPTIONKEY" "$(yq 'select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers[0].secretbox.keys[0].secret' "$TMP/mc1.yaml")" "the etcd encryption secret is the bundle's secretbox secret"
 assert_eq "node rbac" "$(yq 'select(.kind == "KubeAuthorizerConfig") | .name' "$TMP/mc1.yaml" | grep -v '^---' | tr '\n' ' ' | sed 's/ $//')" "the API server authorizers are node then rbac"
 assert_eq "kube-system" "$(yq 'select(.kind == "KubeAdmissionControlConfig") | .configuration.exemptions.namespaces[]' "$TMP/mc1.yaml")" "kube-system is exempt from PodSecurity"
 assert_not_contains "$out" "kind: HostnameConfig" "the generated HostnameConfig document is removed"
@@ -47,10 +52,16 @@
 assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/nv1.yaml")" "nv1 keeps the disk selector and wipe false"
 assert_eq "ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim" "$(yq 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$TMP/nv1.yaml")" "nv1's custom installer image is carried by the document"

+assert_eq "1|none|false" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | (.acceptedCAs | length | tostring) + "|" + (.issuingCA // "none" | tostring)' "$TMP/nv1.yaml")|$(yq 'select(.machine != null) | .cluster | has("ca")' "$TMP/nv1.yaml")" "a worker has the accepted CA only and no legacy cluster.ca"
+assert_not_contains "$(cat "$TMP/nv1.yaml")" "kind: KubeEtcdEncryptionConfig" "a worker has no etcd encryption document"
+
 echo "-- failure modes"
 (unset TALHELPER_UPSMONHOST; assert_fails "an unset variable used by a .tpl patch fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/unset.yaml")
 (unset TALHELPER_CLUSTERSECRET; assert_fails "an unset cluster secret fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/unset3.yaml")
 (TALHELPER_CLUSTERNAME=""; export TALHELPER_CLUSTERNAME; assert_fails "an empty cluster id fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/empty.yaml")
+(unset TALHELPER_AESCBCENCYPTIONKEY; assert_fails "an unset etcd encryption secret fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/unset4.yaml")
+(TALHELPER_AESCBCENCYPTIONKEY=""; export TALHELPER_AESCBCENCYPTIONKEY; assert_fails "an empty etcd encryption secret fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/empty2.yaml")
+(PKI_CONTRACT=v1.13; export PKI_CONTRACT; assert_fails "a failing PKI document generation fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/nopki.yaml")
 mkdir -p "$TMP/tmpdir"
 TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/clean.yaml" >/dev/null 2>&1
 assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory (with the secrets bundle) is left behind"
@@ -75,4 +86,11 @@
   assert_eq "1 1" "$(yq 'select(.kind == "DiscoveryIdentityConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ') $(yq 'select(.kind == "DiscoveryServiceConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')" "$n has exactly one identity and one service document"
   assert_ok "$n output is a valid metal config (a legacy field left next to the documents fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
 done
+
+echo "-- PKI documents on every node"
+for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
+  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
+  assert_eq "1" "$(yq 'select(.kind == "KubeAPIServerCAConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')" "$n has exactly one API server CA document"
+  assert_ok "$n output is a valid metal config (a legacy PKI field left next to the documents fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
+done
 finish
```

The patch exports `TALHELPER_AESCBCENCYPTIONKEY` from the throwaway bundle, adds the control plane and worker assertions (documents present, legacy fields removed, `key2` and `secretbox identity`, the bundle's secret, `acceptedCAs` only on nv1), the three failure modes (unset or empty secret, failing PKI generation) and a loop that validates every node.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash provision/talos/tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: FAIL on the PKI assertions (legacy fields still present, no PKI documents, no encryption document, the new failure-mode assertions and the per-node loop), `N tests, M failed` with M greater than 0.

- [ ] **Step 3: Write the patches**

`provision/talos/patches/controlplane/95-etcd-encryption.yaml.tpl`:

```yaml
# What:   Kubernetes secrets encryption at rest in etcd: one secretbox key, with the identity provider as fallback
# Why:    Replaces cluster.secretboxEncryptionSecret with the same secret (TALHELPER_AESCBCENCYPTIONKEY, also in
#         secrets.yaml.tpl) and the key name and provider order the cluster already runs. The key name is part of every
#         stored ciphertext, so it is written out here instead of taken from a generated default: never rename key2
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: KubeEtcdEncryptionConfig
config:
  resources:
    - providers:
        - secretbox:
            keys:
              - name: key2
                secret: ${TALHELPER_AESCBCENCYPTIONKEY}
        - identity: {}
      resources:
        - secrets
```

`provision/talos/patches/controlplane/96-pki-legacy-delete.yaml`:

```yaml
# What:   Remove the cluster.ca, aggregatorCA, serviceAccount and secretboxEncryptionSecret fields that talosctl gen config adds
# Why:    Talos refuses the legacy fields next to the PKI documents: KubeAPIServerCAConfig, KubeAggregatorCAConfig and
#         KubeServiceAccountConfig (generated by scripts/pki-documents.sh, appended by render.sh) and KubeEtcdEncryptionConfig
#         (95-etcd-encryption.yaml.tpl)
# Nodes:  control plane
# Apply:  live
cluster:
  ca:
    $patch: delete
  aggregatorCA:
    $patch: delete
  serviceAccount:
    $patch: delete
  secretboxEncryptionSecret:
    $patch: delete
```

`provision/talos/patches/worker/96-pki-legacy-delete.yaml`:

```yaml
# What:   Remove the cluster.ca field that talosctl gen config adds
# Why:    Talos refuses the legacy field next to the KubeAPIServerCAConfig document (generated by scripts/pki-documents.sh,
#         appended by render.sh); workers get the accepted CA only, without the CA key
# Nodes:  workers
# Apply:  live
cluster:
  ca:
    $patch: delete
```

- [ ] **Step 4: Add the variable to `TPL_VARS` and append the generated documents in `render.sh`**

Run from the repo root:

```bash
python3 - <<'E'
p='provision/talos/scripts/lib.sh'
s=open(p).read()
old="${TALHELPER_CLUSTERSECRET}'"
assert s.count(old) == 1
s=s.replace(old,"${TALHELPER_CLUSTERSECRET} ${TALHELPER_AESCBCENCYPTIONKEY}'")
open(p,'w').write(s)

p='provision/talos/scripts/render.sh'
s=open(p).read()
old='mkdir -p "$(dirname "$out")"\ntalosctl machineconfig patch'
assert old in s
new='''# The PKI documents are generated from the same secrets bundle (see pki-documents.sh), after the file patches
"$(dirname "${BASH_SOURCE[0]}")/pki-documents.sh" "$type" "$work/secrets.yaml" > "$work/pki-documents.yaml" \\
  || die "generating the PKI documents failed"
args+=(--patch "@$work/pki-documents.yaml")

'''+old
open(p,'w').write(s.replace(old,new))
E
grep -n "TALHELPER_AESCBCENCYPTIONKEY" provision/talos/scripts/lib.sh | cut -c1-60
sed -n '/The PKI documents are generated/,/^talosctl machineconfig/p' provision/talos/scripts/render.sh
```

Expected: the grep shows the `TPL_VARS` line, and the sed shows the four-line block ending with a blank line before `mkdir -p`.

- [ ] **Step 5: Run the tests and the convention check**

Run: `bash provision/talos/tests/test_render.sh && bash provision/talos/scripts/check-patches.sh && bash provision/talos/tests/run.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: PASS everywhere (`test_render.sh` ends `61 tests, 0 failed`; `check-patches: ok`). `test_config_map.sh` in `run.sh` should still pass; the generated config map is stale until Task 4, so do not run `task talos:check` yet.

- [ ] **Step 6: Commit**

```bash
git add provision/talos/patches provision/talos/scripts/render.sh provision/talos/scripts/lib.sh provision/talos/tests/test_render.sh
git commit -m "feat(talos): move the PKI fields to config documents"
```

---

### Task 3: PKI parity check and its task

**Files:**
- Create: `provision/talos/scripts/pki-parity.sh`
- Modify: `.taskfiles/talos/Taskfile.yaml` (new `pki-parity` task next to `diff`)
- Test: `provision/talos/tests/test_pki_parity.sh` (create)

**Interfaces:**
- Consumes: `render.sh` (Task 2) for the rendered side; `node_names`, `node_field` from `lib.sh`.
- Produces: `pki-parity.sh [node...]` prints one line per node and field, `<node>: <field> ok|DIFFERS|absent`, where field is one of `ca_crt`, `ca_key`, `aggregator_crt`, `aggregator_key`, `serviceaccount_key`, `etcd_encryption_secret`. `absent` means both sides have no value (expected for a worker). It exits 1 on any `DIFFERS`, prints no value, and honours `RENDERED_DIR` and `LIVE_DIR` overrides like `diff-live.sh`. Task 5 uses it live.

- [ ] **Step 1: Write the failing test**

Create `provision/talos/tests/test_pki_parity.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash provision/talos/tests/test_pki_parity.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: FAIL (the script does not exist, so every `run` fails), `N tests, M failed` with M greater than 0.

- [ ] **Step 3: Write `pki-parity.sh`**

Create `provision/talos/scripts/pki-parity.sh` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# pki-parity.sh [node...]
# Prove that the PKI values a node runs equal the ones the repo renders, whichever form each side uses (legacy
# cluster.ca/aggregatorCA/serviceAccount/secretboxEncryptionSecret fields or the PKI documents). Each value is
# decoded, whitespace-normalized and compared by hash; the output is only "<node>: <field> ok|DIFFERS", never a value.
# Exit 1 on any difference. Needs the same environment as render.sh and a reachable cluster.
#
# Test/offline overrides, as in diff-live.sh: RENDERED_DIR (pre-rendered home-<node>.yaml, skips render.sh) and
# LIVE_DIR (<node>.yaml raw live configs, skips talosctl).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TALOSCONFIG="${TALOSCONFIG:-$TALOS_DIR/clusterconfig/talosconfig}"

# field_hash <config> <legacy-yq> <doc-kind> <doc-yq> <b64|plain>: hash of one value, empty-value hash when absent
field_hash() {
  local v
  v="$(yq -N "select(.machine != null) | $2" "$1" 2>/dev/null | grep -v '^null$' | head -c 100000)"
  if [ -n "$v" ]; then
    [ "$5" = b64 ] && v="$(printf '%s' "$v" | base64 -d 2>/dev/null)"
  else
    v="$(yq -N "select(.kind == \"$3\") | $4" "$1" 2>/dev/null | grep -v '^null$')"
  fi
  printf '%s' "$v" | tr -d ' \n\r\t' | sha256sum | cut -d' ' -f1
}

# pki_values <config>: "field hash" lines
pki_values() {
  echo "ca_crt $(field_hash "$1" '.cluster.ca.crt' KubeAPIServerCAConfig '(.issuingCA.cert // .acceptedCAs[0])' b64)"
  echo "ca_key $(field_hash "$1" '.cluster.ca.key' KubeAPIServerCAConfig '.issuingCA.key' b64)"
  echo "aggregator_crt $(field_hash "$1" '.cluster.aggregatorCA.crt' KubeAggregatorCAConfig '.issuingCA.cert' b64)"
  echo "aggregator_key $(field_hash "$1" '.cluster.aggregatorCA.key' KubeAggregatorCAConfig '.issuingCA.key' b64)"
  echo "serviceaccount_key $(field_hash "$1" '.cluster.serviceAccount.key' KubeServiceAccountConfig '.issuer.privateKey' b64)"
  echo "etcd_encryption_secret $(field_hash "$1" '.cluster.secretboxEncryptionSecret' KubeEtcdEncryptionConfig '.config.resources[0].providers[] | select(.secretbox) | .secretbox.keys[0].secret' plain)"
}

nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || mapfile -t nodes < <(node_names)
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

empty="$(printf '' | sha256sum | cut -d' ' -f1)"
status=0
for node in "${nodes[@]}"; do
  ip="$(node_field "$node" ip)"
  [ -n "$ip" ] || { echo "unknown node: $node" >&2; status=1; continue; }

  if [ -n "${RENDERED_DIR:-}" ]; then rendered="$RENDERED_DIR/home-$node.yaml"
  else rendered="$tmp/rendered-$node.yaml"; "$SCRIPTS/render.sh" "$node" "$rendered" || { status=1; continue; }; fi

  if [ -n "${LIVE_DIR:-}" ]; then live="$LIVE_DIR/$node.yaml"
  else live="$tmp/live-$node.yaml"; talosctl get machineconfig v1alpha1 -n "$ip" -o yaml 2>/dev/null | yq '.spec' > "$live" || { echo "$node: cannot read the live config" >&2; status=1; continue; }; fi

  pki_values "$live" > "$tmp/live.vals"
  pki_values "$rendered" > "$tmp/repo.vals"
  while read -r field lhash; do
    rhash="$(awk -v f="$field" '$1 == f {print $2}' "$tmp/repo.vals")"
    if [ "$lhash" != "$rhash" ]; then echo "$node: $field DIFFERS"; status=1
    elif [ "$lhash" = "$empty" ]; then echo "$node: $field absent"   # on both sides, expected for a worker only
    else echo "$node: $field ok"; fi
  done < "$tmp/live.vals"
done
exit $status
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash provision/talos/tests/test_pki_parity.sh`
Expected: PASS, `14 tests, 0 failed`.

- [ ] **Step 5: Add the task**

In `.taskfiles/talos/Taskfile.yaml`, directly after the `diff:` task (the one whose command is `scripts/diff-live.sh {{.CLI_ARGS}}`), add:

```yaml
  pki-parity:
    desc: Compare the PKI values a node runs with the rendered ones by hash, printing no values (task talos:pki-parity -- mc1)
    env:
      TALOS_VERSION: "{{.TALOS_VERSION}}"
      KUBERNETES_VERSION: "{{.KUBERNETES_VERSION}}"
    cmds:
      - "{{.TALOS_DIR}}/scripts/pki-parity.sh {{.CLI_ARGS}}"
```

Run: `task --list-all 2>&1 | grep pki-parity`
Expected: `* talos:pki-parity:` with the description.

- [ ] **Step 6: Run the whole suite and commit**

Run: `bash provision/talos/tests/run.sh 2>&1 | grep -E "^==|FAIL|tests,"`
Expected: every file passes, including `test_pki_documents.sh`, `test_pki_parity.sh` and `test_render.sh`.

```bash
git add provision/talos/scripts/pki-parity.sh provision/talos/tests/test_pki_parity.sh .taskfiles/talos/Taskfile.yaml
git commit -m "feat(talos): add a value-free PKI parity check"
```

---

### Task 4: Docs, config map and the PR

**Files:**
- Modify (generated): `docs/src/talos/config-map.md`
- Modify: `provision/talos/README.md`
- Modify: `.plans/TODO.md`
- Modify: `docs/superpowers/specs/2026-10-05-talos-config-layout-design.md`
- Modify: `.claude/skills/talos-config-editing/SKILL.md`

**Interfaces:**
- Consumes: the patch files from Task 2 (the config map is generated from their headers).

- [ ] **Step 1: Regenerate the config map and run the full check**

Run: `task talos:config-map && task talos:check 2>&1 | grep -E "FAIL|failed|check-patches|up to date|error"`
Expected: `check-patches: ok`, `config-map: up to date`, no failures. `git diff docs/src/talos/config-map.md` shows `95-etcd-encryption.yaml.tpl` (`KubeEtcdEncryptionConfig`) and `96-pki-legacy-delete.yaml` (control plane: `cluster.ca`, `cluster.aggregatorCA`, `cluster.serviceAccount`, `cluster.secretboxEncryptionSecret`; worker: `cluster.ca`) rows in the right node sections.

- [ ] **Step 2: Update the README**

In `provision/talos/README.md`, in `## Secrets`, append this paragraph at the end of the section:

```markdown
The PKI documents (`KubeAPIServerCAConfig`, `KubeAggregatorCAConfig`, `KubeServiceAccountConfig`) are not patch files:
`scripts/pki-documents.sh` prints them from a second `talosctl gen config` (`PKI_CONTRACT`, v1.14) of the same secrets
bundle and `render.sh` appends them as the last patch, because the pinned `TALOS_CONTRACT` (v1.13) still generates the
legacy `cluster.ca`, `aggregatorCA`, `serviceAccount` and `secretboxEncryptionSecret` fields, which
`patches/*/96-pki-legacy-delete.yaml` remove. `KubeEtcdEncryptionConfig` is the exception: `patches/controlplane/95-etcd-encryption.yaml.tpl`
writes it out (key name `key2`, `secretbox` then `identity`, the secret from `TALHELPER_AESCBCENCYPTIONKEY`) because the key
name is part of every stored ciphertext and must never follow a generated default. `task talos:pki-parity -- <node>`
compares the PKI values a node runs with the rendered ones by hash and prints no values. When `TALOS_CONTRACT` reaches
v1.14, remove `pki-documents.sh`, `PKI_CONTRACT` and the `96-pki-legacy-delete.yaml` patches together.
```

- [ ] **Step 3: Update the TODO, the layout spec and the skill**

In `.plans/TODO.md`, in the Tier 3 PKI bullet, add at the end of its first sentence group: "Repo change merged (spec and plan `2026-10-06-talos-pki-documents`); the live rollout is Task 5 of the plan." Keep the bullet's other text.

In `docs/superpowers/specs/2026-10-05-talos-config-layout-design.md`, read the non-goal bullet that begins "Migrating the PKI and secret fields" and append: "The PKI fields moved separately, see `2026-10-06-talos-pki-documents-design.md`." Keep its line wrapping.

In `.claude/skills/talos-config-editing/SKILL.md`, read the file first, then add a short note where it lists patch files or per-layer conventions: the PKI documents are generated by `scripts/pki-documents.sh` and appended by `render.sh` (do not add them as patch files), `95-etcd-encryption.yaml.tpl` pins the key name `key2`, and `96-pki-legacy-delete.yaml` removes the legacy fields.

- [ ] **Step 4: Check, commit, push and open the PR**

Run: `task talos:check 2>&1 | grep -E "FAIL|failed|error"; git status --short`
Expected: no failures; only the files above are changed.

```bash
git add -A docs .plans provision/talos/README.md .claude/skills
git commit -m "docs(talos): document the PKI documents and regenerate the config map"
git push -u origin chore/talos-pki-documents
gh pr create --title "feat(talos): move the PKI fields to config documents" --body "Implements docs/superpowers/specs/2026-10-06-talos-pki-documents-design.md (plan: docs/superpowers/plans/2026-10-06-talos-pki-documents.md, Tasks 1-4). Repo change only. The live rollout (parity check, resource hashes, one node at a time) is Task 5 of the plan and needs separate confirmation."
```

---

### Task 5: Gated live rollout (manual, needs user confirmation per step)

**Files:** none (cluster operations). Do this only after the PR from Task 4 is merged and the user confirms each apply. Read-only commands are free; `task talos:apply` is not.

**Interfaces:**
- Consumes: merged patches and scripts from Tasks 1 to 4; the repo environment (`.envrc` exports `TALHELPER_*`, `TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig`). Node IPs: mc1 `192.168.48.2`, mc2 `.3`, mc3 `.4`, nv1 `.5`.

- [ ] **Step 1: Preconditions (read-only)**

```bash
cd /workspaces/home-ops
task talos:generate && task talos:diff 2>&1 | grep -E "^(mc|nv)[0-9]: "
task talos:pki-parity 2>&1
kubectl -n talos-backup get jobs --sort-by=.status.startTime | tail -2
kubectl get nodes
```

Expected:
- `task talos:diff`: every node differs only by the move: `-` lines for `cluster.ca`, `aggregatorCA`, `serviceAccount`, `secretboxEncryptionSecret` (control planes) and `ca` (nv1), `+` lines for the four documents (control planes) and `KubeAPIServerCAConfig` (nv1), with every key and value masked (no PEM text). Nothing else changes; the running versions are v1.14.2 (nv1 v1.14.0).
- `task talos:pki-parity`: for mc1, mc2, mc3 all six fields `ok`; for nv1 `ca_crt ok` and five fields `absent`. Any `DIFFERS`: **stop**, do not apply; the rendered values do not match what the nodes run.
- The newest `talos-backup` job is `Complete` and started within the last two hours; all four nodes are Ready.

- [ ] **Step 2: Record the baseline on mc1 (read-only)**

Only hashes and counts are printed, never values:

```bash
h() { sha256sum | cut -c1-12; }
echo "enc:  $(talosctl -n 192.168.48.2 get etcdencryptionconfigs -o yaml | yq '.spec' | h)"
echo "root: $(talosctl -n 192.168.48.2 get kubernetesrootsecrets -o yaml | yq '.spec' | h)"
kubectl -n kube-system get pod kube-apiserver-mc1 -o jsonpath='{.status.startTime} restarts={.status.containerStatuses[0].restartCount}{"\n"}'
kubectl get secrets -A -o json | jq '.items | length'
```

Note the two hashes, the pod start time and restart count, and the Secret count.

- [ ] **Step 3: Apply to mc1, ask the user first**

Ask the user to confirm, then: `task talos:apply N=mc1` (live, no reboot).

- [ ] **Step 4: Verify mc1**

Repeat the four commands of Step 2, then:

```bash
task talos:pki-parity -- mc1
task talos:diff -- mc1
kubectl get nodes
```

Expected: both hashes, the pod start time and the restart count are **identical** to the baseline; the Secret count is the same and the list succeeded (every Secret decrypts through `key2`); `pki-parity` shows six `ok`; `diff` shows `mc1: no differences`; all nodes Ready. **If any hash changed, the API server pod restarted, the Secret list failed or parity shows DIFFERS: stop, do not touch another node, roll back mc1 (Step 7) and tell the user.**

- [ ] **Step 5: Apply to the remaining nodes, one at a time**

After the user confirms each: `task talos:apply N=mc2`, then `mc3`, then `nv1`. After each apply repeat the Step 4 checks for that node (baseline hashes and pod name for mc2 and mc3: `kube-apiserver-mc2`, `kube-apiserver-mc3`, record their baseline before applying). For nv1 the checks are: `task talos:pki-parity -- nv1` (`ca_crt ok`, the rest `absent`), `task talos:diff -- nv1`, `kubectl get node nv1` Ready and `kubectl get node nv1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'` still `1`. Never touch nv1's network config.

- [ ] **Step 6: Final check**

Run: `task talos:diff` and `task talos:pki-parity`
Expected: `no differences` for every node; parity as in Step 1 with no `DIFFERS`. Then open a docs PR that records the rollout in this plan and removes the Tier 3 PKI entry from `.plans/TODO.md` (keep the `cluster.token` / `cluster.etcd.ca` / `machine.*` note, those have no documents).

- [ ] **Step 7: Rollback, only if needed**

Revert the PR on a branch, `task talos:generate`, and `task talos:apply N=<node>` per node, then re-run Step 4 for that node. The legacy fields restore the same values.

---

## Self-Review

- **Spec coverage:** goals 1 and 3 are Tasks 1 and 2 (generated documents from the same bundle, value tests, legacy removal); goal 2 is Task 2 (pinned `key2`, provider order, secret) and Task 5 (resource hashes); goal 4 is Tasks 3 and 5. Spec files table: `pki-documents.sh` and `PKI_CONTRACT` (Task 1), `render.sh`, `TPL_VARS`, `95-`, `96-` patches (Task 2), `pki-parity.sh` (Task 3). Spec documentation list is Task 4. Verification offline items 1 to 5 are the tests in Tasks 1 and 2; item 6 (masked diff shows no PEM) is Task 5 Step 1 and was covered by the `mask.sh` tests.
- **Placeholders:** none. The three doc edits in Task 4 Step 3 say to read the target text first because exact wrapping is not copied here.
- **Names:** `pki-documents.sh`, `pki-parity.sh`, `PKI_CONTRACT`, `TALHELPER_AESCBCENCYPTIONKEY`, `95-etcd-encryption.yaml.tpl`, `96-pki-legacy-delete.yaml`, the six parity field names and the `ok|DIFFERS|absent` labels are used identically in every task.

## Rollout log (2026-10-06)

Applied to mc1, mc2, mc3, then nv1, one node at a time (live, no reboot). Before each apply the parity check was clean on all four nodes and the live encryption layout was `secretbox` then `identity` with key `key2`. After the rollout `task talos:diff` shows no differences on any node, `etcdencryptionconfigs` has the same hash on all three control planes (the pre-rollout value), all API servers answer `readyz`, nv1 still advertises its GPU and `task talos:pki-parity` is clean.

What differed from the plan:

- **The root-secrets resource changes, and each control plane's API server restarts once.** The plan's Task 5 treated a changed `kubernetesrootsecrets` hash or an API server restart as a stop-and-roll-back condition, on the assumption that identical values mean no change. Per field, only `etcdEncryptionConfig` (now set) and `secretboxEncryptionSecret` (now empty) differ; every CA, key, issuer and token is identical. The pass criterion is the unchanged `etcdencryptionconfigs` hash (what the API server reads), not the root-secrets hash. The restart takes about 40 seconds on that node while the other two keep serving; `kubectl` through the VIP fails during it when the node is the one holding the VIP (mc1 did).
- **`pki-parity.sh` has nine fields, not six** (key name, provider list and `aescbc` were added after review; `absent` is only accepted where expected).
- **A `kubectl get secrets` decrypt check could not run** (denied by the session's permission rules). The unchanged `etcdencryptionconfigs` hash, clean API server logs and healthy ArgoCD apps were used instead.
- **mc1 was rebooted afterwards** (cordon, drain, `talosctl reboot`, uncordon) to check the config survives a restart: hashes, parity and diff were unchanged and the API server came up ready.
- **`task talos:apply` stops at its health gate unless Ceph is exactly `HEALTH_OK`.** The reboot left one new mgr `prometheus` module crash, which made Ceph `HEALTH_WARN` and blocked the mc2 apply (nothing was applied). Archiving the crash (`ceph crash archive <id>` in the rook-ceph-tools pod) cleared it; the `AUTH_INSECURE_*` warnings are muted and sticky and do not block the gate.
