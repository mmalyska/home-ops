# Talos PKI Documents (`KubeAPIServerCAConfig` and friends) — Design

## Context

Talos 1.12+ deprecates the v1alpha1 PKI fields in favour of four documents. The
legacy fields keep working and no removal date exists in 1.12 to 1.14, so this is
cleanup. It is the second and last slice of Tier 3 in `.plans/TODO.md`; the
first (`DiscoveryIdentityConfig` / `DiscoveryServiceConfig`) is done and applied
(`2026-10-05-talos-discovery-documents-design.md`).

Read the layered layout spec first (`2026-10-05-talos-config-layout-design.md`)
and the discovery spec: patch files in `provision/talos/patches/`, one document
per file, `.yaml.tpl` for files with variables, `$patch: delete` for fields the
generated base adds. The research behind this spec is recorded in the Tier 3
entry of `.plans/TODO.md` (2026-10-06).

### Current state (verified 2026-10-06)

- `secrets.yaml.tpl` builds the secrets bundle from `TALHELPER_*` variables.
  `render.sh` runs `talosctl gen config` with `TALOS_CONTRACT=v1.13`, so the base
  carries the legacy fields `cluster.ca`, `cluster.aggregatorCA`,
  `cluster.serviceAccount` and `cluster.secretboxEncryptionSecret` (control
  planes) and `cluster.ca` with an empty key (workers).
- The four documents and what replaces what (`talosctl docs --config`, Talos
  v1.14.2):
  - `cluster.ca` -> `KubeAPIServerCAConfig`: `issuingCA` (`cert`, `key`) on
    control planes, `acceptedCAs` only on workers.
  - `cluster.aggregatorCA` -> `KubeAggregatorCAConfig`: `issuingCA` on control
    planes.
  - `cluster.serviceAccount` -> `KubeServiceAccountConfig`: `issuer.privateKey`
    and `issuer.issuerURL`. The earlier TODO list missed this field.
  - `cluster.secretboxEncryptionSecret` -> `KubeEtcdEncryptionConfig`: the whole
    EncryptionConfiguration (`config`), including the key name.
- Legacy and document fields are mutually exclusive: leaving one legacy field next
  to its document fails `talosctl validate` ("... is already set in v1alpha1
  config").
- Same bundle, same values: a v1.14-contract render of the throwaway bundle gives
  CA, aggregator CA and worker CA values equal to the v1.13 legacy fields after
  decoding and whitespace normalizing. A merge of the documents onto the v1.13
  base with the legacy fields deleted passes `talosctl validate --mode metal` for
  both roles.
- The live etcd encryption config is key name `key2`, a `secretbox` provider and
  an `identity: {}` fallback (`talosctl get etcdencryptionconfigs`). The document
  Talos 1.14 generates has `key2` but no `identity` fallback.
- The live API server's service account issuer equals the control plane endpoint
  (`/.well-known/openid-configuration`), which is the document's default.
- `scripts/mask.sh` now masks block scalars and PEM bodies (PR #5524); a diff of
  the legacy fields against the documents shows no PEM text.
- Still legacy even in a fresh 1.14 config, no documents exist: `cluster.token`,
  `cluster.etcd.ca`, `machine.type`, `machine.token`, `machine.ca`,
  `machine.certSANs`, `machine.features.diskQuotaSupport`.

## Goals

1. The four PKI legacy fields are gone from every rendered config; the four
   documents carry the same values, so nothing the cluster runs changes.
2. The etcd encryption key name and provider order stay exactly as live
   (`key2`, `secretbox` then `identity`), so existing Secrets stay readable.
3. The values come from the same secrets bundle as today (one source of truth),
   not from a second copy of the secrets.
4. The rollout proves "identical" with resource hashes, node by node, and
   `task talos:diff` ends with no differences.

## Non-goals

- Rotating any CA, key or encryption secret, and using `acceptedCAs` for
  rotation. This is a like-for-like move.
- `cluster.token`, `cluster.etcd.ca` and the `machine.*` fields above (no
  documents).
- Changing `TALOS_CONTRACT` for the whole render. The 1.14 contract would change
  many other generated fields and hide this diff.
- Changing `secrets.yaml.tpl` or the Bitwarden variables.

## Decisions

1. **CA, aggregator CA and service account key come from a second `gen config`
   render** with `PKI_CONTRACT=v1.14` and the same secrets bundle, selecting the
   three kinds with `yq`. Rejected: templating the PEM keys through `TALHELPER_*`
   and `envsubst` (multi-line values, indentation, and a second copy of the
   secrets in the patch variables).
2. **The etcd encryption document is a static `.yaml.tpl` patch**, with the key
   name `key2`, the `secretbox` provider and the `identity: {}` fallback written
   out, and the secret from `${TALHELPER_AESCBCENCYPTIONKEY}` (the same variable
   `secrets.yaml.tpl` maps to `secretboxencryptionsecret`). Rejected: taking it
   from the generated render. The key name is part of every stored ciphertext; if
   a later Talos version changes its generated default name, a generated document
   would silently make existing Secrets unreadable. The name must be pinned in the
   repo, and a test asserts it.
3. **Legacy removal is static delete patches**, one per role layer, like the
   other `*-legacy-delete.yaml` files.
4. **A small tested script produces the generated documents**
   (`scripts/pki-documents.sh`), and `render.sh` appends its output as one extra
   patch after the file patches. When `TALOS_CONTRACT` reaches v1.14 the base
   carries the documents itself and the script, the delete patches and
   `PKI_CONTRACT` are removed together.

## Design

### Files

| File | Action | Content |
|---|---|---|
| `provision/talos/scripts/pki-documents.sh` | new | `pki-documents.sh <controlplane\|worker> <secrets-file>`: runs `talosctl gen config` with `--talos-version "$PKI_CONTRACT"` into a temp dir, prints only the `KubeAPIServerCAConfig` (both roles) and, for control planes, `KubeAggregatorCAConfig` and `KubeServiceAccountConfig` documents. Never `KubeEtcdEncryptionConfig` (decision 2). Cleans up its temp dir; exits non-zero when `gen config` fails or a document is missing. |
| `provision/talos/scripts/lib.sh` | modify | `PKI_CONTRACT="${PKI_CONTRACT:-v1.14}"` next to `TALOS_CONTRACT`, with a comment saying it is removed at the contract bump. `${TALHELPER_AESCBCENCYPTIONKEY}` added to `TPL_VARS`. |
| `provision/talos/scripts/render.sh` | modify | After the file patches are collected, run `pki-documents.sh "$type" "$work/secrets.yaml"` and append its output as the last `--patch`. A failing script fails the render. |
| `provision/talos/patches/controlplane/95-etcd-encryption.yaml.tpl` | new | `KubeEtcdEncryptionConfig` with `config.resources[0].providers: [secretbox keys [name: key2, secret: ${TALHELPER_AESCBCENCYPTIONKEY}], identity: {}]`, `resources: [secrets]`. |
| `provision/talos/patches/controlplane/96-pki-legacy-delete.yaml` | new | `$patch: delete` for `cluster.ca`, `cluster.aggregatorCA`, `cluster.serviceAccount`, `cluster.secretboxEncryptionSecret`. |
| `provision/talos/patches/worker/96-pki-legacy-delete.yaml` | new | `$patch: delete` for `cluster.ca`. |
| `provision/talos/scripts/pki-parity.sh` | new | `pki-parity.sh <node>`: compares the PKI values the node runs with the rendered documents by hash, prints only `ok`/`DIFFERS` per field and never a value (see Verification). Test overrides like `diff-live.sh` (`RENDERED_DIR`, `LIVE_DIR`). |

Each patch file carries the standard header (What / Why / Nodes / Apply); Apply
is `live`. File numbers 95/96 are after the existing control-plane files (last is
`90-ethernet-rings.yaml`) and the worker layer's files (the last is `30-node-taints.yaml`). The
generated patch is not a file, so `explain.sh` and the config map list the
static ones only; the Why of `96-pki-legacy-delete.yaml` names the generated
source so the map is not misleading.

### Data flow

`secrets.yaml.tpl` (envsubst from `TALHELPER_*`) -> bundle in a temp dir ->
(a) v1.13 `gen config` base with the legacy fields, (b) `pki-documents.sh` v1.14
render of the same bundle, reduced to the three kinds. The encryption secret
reaches its document through the existing variable, so the bundle and the patch
read the same value.

### Mutual exclusion and order

The delete patches remove the legacy fields from the base; the documents are
added by patches. The two are different keys, so the order between them does not
matter. Tests prove no legacy field is left (validate fails if one is).

## Verification

No cluster change until the user confirms each step.

**Offline (CI, no secrets):** tests in `tests/test_render.sh`, a new
`tests/test_pki_documents.sh` and `tests/test_pki_parity.sh`, using a throwaway
bundle:

1. Each role renders the right set: control planes have the four documents and no
   `cluster.ca`/`aggregatorCA`/`serviceAccount`/`secretboxEncryptionSecret`;
   workers have `KubeAPIServerCAConfig` with `acceptedCAs` only and no
   `cluster.ca`. Every node validates in `--mode metal`.
2. Values equal the legacy ones: render the v1.13 base without the PKI patches
   and compare, after base64 decode and whitespace normalizing, `cluster.ca.crt`
   and `key`, `aggregatorCA`, `serviceAccount.key` against the documents
   (control plane) and `cluster.ca.crt` against `acceptedCAs[0]` (worker).
3. Etcd encryption: key name is exactly `key2`, providers are `secretbox` then
   `identity`, and the secret equals the bundle's `secretboxencryptionsecret`.
   The test fails if a renamed key or a missing `identity` is introduced.
4. The issuer URL equals `https://${TALHELPER_CLUSTERDOMAIN}:6443`.
5. Failure modes: unset or empty `TALHELPER_AESCBCENCYPTIONKEY` fails the render;
   `pki-documents.sh` failing fails the render; no temp dir with secrets is left
   behind (existing leak test pattern).
6. Masking: a masked `task talos:diff` of the legacy render against the new one
   shows no PEM or secret text.

**Live, one node at a time (mc1 first, then mc2, mc3, nv1):**

1. Preconditions, read-only: all four nodes healthy; a recent etcd backup exists
   (`talos-backup`); `pki-parity.sh <node>` prints `ok` for every field on all
   four nodes; `task talos:diff` shows only the move.
2. Before the first apply, on mc1 record hashes (not values) of the resources
   that carry the effective values: `etcdencryptionconfigs`, the Kubernetes root
   secrets, and the kube-apiserver static pod start time.
3. `task talos:apply N=mc1` (live; the health step now uses explicit node lists).
   After it: the same resource hashes are unchanged, the API server pod did not
   restart, `kubectl get nodes` is Ready, an existing Secret can still be read
   (decrypts through `key2`), and `task talos:diff -- mc1` shows no differences.
   **If any hash changed or the API server restarted, stop and roll back mc1**
   (revert, `task talos:generate`, `task talos:apply N=mc1`), then rewrite this
   spec; do not continue to the other nodes.
4. Repeat for mc2, mc3, then nv1 (worker: only `acceptedCAs`; check it still
   joins and the GPU is still advertised).
5. Final: `task talos:diff` shows no differences on all four nodes.

**Rollback:** revert the PR and re-apply per node. The legacy fields restore the
same values, so nothing else changes.

## Risks

- **Encryption config drift** (key name or `identity` fallback) makes the API
  server fail to read existing Secrets. Mitigated by decision 2, test 3, the
  etcd backup and the resource-hash comparison on the first node.
- **A value that is not actually identical** (whitespace or encoding in a PEM)
  would restart control plane components. Mitigated by test 2 and `pki-parity.sh`
  before applying, and by the one-node-first gate.
- **Secret leakage in diffs or logs:** covered by the block-aware `mask.sh`, test
  6, and `pki-parity.sh` printing no values.
- **Upstream renames a generated default** (for example the issuer URL form):
  the offline value tests run against the pinned Talos version and fail in CI on a
  version bump, before a render reaches a node.
- **Mixed state during the rollout:** all nodes share the same values, so a node
  with the new documents and a node with the old fields keep working together.
  The control plane is never applied in parallel.

## Documentation

- `.plans/TODO.md`: mark the PKI slice done and drop the Tier 3 entry once
  applied.
- `provision/talos/README.md`: the pipeline overview and the Secrets section
  (second render, the pinned encryption document, `pki-parity.sh`).
- `docs/src/talos/config-map.md`: regenerate (`task talos:config-map`).
- `2026-10-05-talos-config-layout-design.md`: the remaining tier 3 non-goal
  wording.
- The `talos-config-editing` skill: mention the generated PKI patch and the
  pinned encryption document.
