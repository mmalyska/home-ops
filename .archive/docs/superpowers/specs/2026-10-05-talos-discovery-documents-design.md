# Talos Discovery Documents (`DiscoveryIdentityConfig`, `DiscoveryServiceConfig`) — Design

## Context

Talos 1.12+ deprecates the v1alpha1 fields `cluster.id`, `cluster.secret` and
`cluster.discovery` in favour of two documents. The legacy fields keep working
and no removal date exists in 1.12–1.14, so this is cleanup. It is the first
slice of Tier 3 in `.plans/TODO.md`; the PKI and secret fields
(`cluster.ca`, `aggregatorCA`, `secretboxEncryptionSecret`) are deliberately
**out of scope** and get their own spec later.

Read the layered layout spec first (`2026-10-05-talos-config-layout-design.md`):
patch files in `provision/talos/patches/`, one document per file, `.yaml.tpl`
for files with variables, `$patch: delete` for blocks the generated base adds.
The Tier 2 specs (`2026-10-05-talos-apiserver-documents-design.md`,
`2026-10-05-talos-install-document-design.md`) are the model for this one.

### Current state (verified 2026-10-05)

- `provision/talos/secrets.yaml.tpl` sets `cluster.id: ${TALHELPER_CLUSTERNAME}`
  and `cluster.secret: ${TALHELPER_CLUSTERSECRET}`. `talosctl gen config`
  (`TALOS_CONTRACT=v1.13`) writes them into the base config as v1alpha1
  `cluster.id` / `cluster.secret`.
- `patches/all/90-discovery.yaml` sets `cluster.discovery`: `enabled: true`,
  Kubernetes registry disabled, `service: {}` (the default endpoint).
- `talosctl docs --config` (Talos v1.14.2) gives the new schemas:
  - `DiscoveryIdentityConfig`: `clusterID`, `clusterSecret`.
  - `DiscoveryServiceConfig`: `name`, `endpoint`.
- The new documents and the v1alpha1 fields are mutually exclusive, so each
  must move in one step.

## Goals

1. Discovery identity and service are configured only through the two
   documents; the v1alpha1 fields are gone from the rendered config.
2. The cluster id and secret values do not change, so the discovery group and
   node membership are untouched.
3. `task talos:diff` shows only the move, nothing else.

## Non-goals

- `cluster.ca`, `aggregatorCA`, `secretboxEncryptionSecret` (PKI and etcd
  encryption); a separate spec.
- Changing the discovery endpoint, or running a private discovery service.
- Changing `TALOS_CONTRACT` (it would change many other generated fields at
  once and hide this diff).
- Changing `secrets.yaml.tpl`: the secrets bundle still needs both values.

## Design

All files are under `provision/talos/patches/all/`.

| File | Action | Content |
|---|---|---|
| `90-discovery.yaml` | replace with `90-discovery-service.yaml` | `DiscoveryServiceConfig`: `name: primary`, `endpoint: https://discovery.talos.dev/` (the default `service: {}` used today) |
| `91-discovery-identity.yaml.tpl` | new | `DiscoveryIdentityConfig`: `clusterID: ${TALHELPER_CLUSTERNAME}`, `clusterSecret: ${TALHELPER_CLUSTERSECRET}` |
| `92-discovery-legacy-delete.yaml` | new | `$patch: delete` for `cluster.id`, `cluster.secret`, `cluster.discovery` (same pattern as the other `*-legacy-delete.yaml` files) |

Each file carries the standard header (What / Why / Nodes / Apply). Apply is
`live`: no reboot.

`scripts/lib.sh`: add `${TALHELPER_CLUSTERNAME}` and `${TALHELPER_CLUSTERSECRET}`
to `TPL_VARS`. `render.sh` already fails when a variable used by a `.tpl` patch
is unset, so an empty value cannot slip through.

Kubernetes registry: it stays off because no Kubernetes registry document is
declared. To confirm in implementation (not assumed): on 1.14 the rendered
config, with the documents present, shows only the service registry; the
default for "no document" must not turn the Kubernetes registry on.

### Secrets handling

`clusterID` and `clusterSecret` end up in the rendered config, which is
gitignored. `scripts/mask.sh` must mask both in `task talos:diff` output.
`mask.sh` is line-based; both are single-line scalars, so this holds, but the
test must prove it for the new keys.

## Verification

No cluster change until the user confirms each step.

1. `task talos:generate`, then `task talos:diff`: the diff shows removal of
   `cluster.id`, `cluster.secret`, `cluster.discovery` and addition of the two
   documents, with identical (masked) values. Nothing else changes.
2. Extend the tests: `tests/test_render.sh` (new env vars exported, the new
   documents present, the v1alpha1 fields absent), `tests/test_check_patches.sh`
   and the `mask.sh` test (new keys masked). Run `task talos:check`.
3. Apply one node at a time with the usual gate (live, no reboot). After each:
   `talosctl get affiliates` and `talosctl get members` list all four nodes;
   `talosctl get discoveredmembers` is unchanged.
4. Rollback: revert the PR and re-apply; the legacy fields restore the same
   values.

## Risks

- **Typo or wrong variable in the identity patch** changes the discovery group
  and splits node membership. Mitigated by the unset-variable check and the
  diff in step 1, which must show identical masked values (compare the
  unmasked rendered values locally against the live config by hash).
- **Kubernetes registry default** (above): verified before applying.
- **Mixed state during a rolling apply:** a node with the new documents and a
  node with the old fields share the same id and secret, so they keep seeing
  each other.

## Documentation

- `.plans/TODO.md`: mark discovery done in the Tier 3 entry; PKI and
  encryption secret remain.
- `provision/talos/README.md`: patch list and the secrets section.
- `2026-10-05-talos-config-layout-design.md`: the tier 3 non-goal wording
  (discovery is done separately).
- `docs/` MkDocs page generated from patch headers: regenerate.
