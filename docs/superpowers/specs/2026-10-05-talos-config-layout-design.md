# Talos Config Layout and Automated Upgrades — Design

## Context

Talos 1.14 deprecates most of the legacy `v1alpha1` machine config in favour
of multi-document configuration (1.12 deprecated the network fields, 1.13 added
more, 1.14 most of the rest). The old fields keep working and no removal date
is published, but they are the only way our config is written today, and the
way we generate it was not built for documents.

The 1.13 → 1.14 rollout (2026-10-04/05) also showed that our upgrade routine
is a manual runbook (gate, drain, reboot, verify, uncordon, per node) and that
the stored config drifted unnoticed (mc1 still carried a `v1.13.8` install
image after the upgrade).

This spec covers two phases. **Phase 1** (this spec, in detail) reorganises the
Talos config into a readable layered layout with a new render pipeline.
**Phase 2** (outlined here, its own spec later) moves Talos and Kubernetes
upgrades to an in-cluster controller driven by Renovate PRs.

### Current state (verified 2026-10-05)

- `.taskfiles/talos/Taskfile.yaml` `generate`, per node:
  `envsubst < templates/{controlplane,worker}.yaml` →
  `talosctl machineconfig patch --patch @nodes/<node>.yaml` → append
  `templates/extension-nut-client.yaml` (`envsubst`, all nodes) and
  `templates/ethernet-rings.yaml` (`cat`, control plane only) →
  `clusterconfig/home-<node>.yaml` (gitignored).
- `templates/controlplane.yaml` and `worker.yaml` are hand-written full
  `v1alpha1` bases with the PKI and tokens inlined through `${TALHELPER_*}`
  variables. The names are inherited from talhelper, which we do not use
  (talhelper is archived; see Alternatives).
- Secrets come from Bitwarden Secrets Manager: `.envrc` runs
  `bws secret list … -o env` and exports the result.
- Only two non-`v1alpha1` documents exist: `EthernetConfig` and
  `ExtensionServiceConfig`.
- `TALOS_VERSION` and `KUBERNETES_VERSION` live in the Taskfile and are bumped
  by Renovate (`github-releases siderolabs/talos`, `docker
  ghcr.io/siderolabs/kubelet`, held at `<=1.35`). `talos:upgrade` takes the
  image from the generated config and now fails if the node boots another
  version.
- nv1 is a worker with a custom (non-Factory) installer image
  (`ghcr.io/schwankner/custom-installer:<talos>-<kernel>-nvgpu<ver>-…`); its
  tag is bumped by hand.
- All CI runs on `ubuntu-latest`; no runner can reach the node network.

## Goals

1. A reader can see **what is configured, why, on which nodes, and what
   applying it costs** (reboot or not), straight from the repo.
2. New and deprecated-field-replacing documents drop in as files, without
   editing Taskfile shell.
3. Bitwarden stays the only source of secrets; nothing encrypted in git.
4. The restructure changes **nothing on the nodes** (proven, not assumed).
5. Talos and Kubernetes upgrades roll out automatically after a Renovate PR is
   merged, with our Ceph and CNPG gates preserved.
6. nv1 keeps working with its custom installer image.

## Non-goals

- Automatic config apply from CI. Config apply stays a manual
  `task talos:apply`. A self-hosted runner in the cluster can be killed
  mid-upgrade; a VPN for GitHub's public runners opens a path into the LAN.
- The nv1 boot-entry problem (stale `LoaderEntryDefault` on the Jetson UEFI).
- Adopting TOPF or talstomize now. The layout is the model both use, so a later
  switch is cheap.
- Migrating the PKI, secret and discovery fields (tier 3 in
  `.plans/TODO.md`) until upstream publishes a removal timeline.

## Phase 1 design

### 1. Layout

```text
provision/talos/
  README.md                   pipeline overview (see section 5)
  nodes.yaml                  node index: name, ip, type (unchanged)
  patches/
    all/            10-time.yaml   20-sysctls.yaml   30-udev.yaml  ...
    controlplane/   10-etcd-metrics.yaml   20-apiserver.yaml.tpl  30-vip.yaml ...
    worker/
    node/<name>/    nv1: 10-install-image.yaml   20-kernel-modules.yaml   30-cri.yaml
  clusterconfig/              rendered output, gitignored (path unchanged)
```

- **Merge order:** `all/`, then the role directory (`controlplane/` or
  `worker/`), then `node/<name>/`; lexicographic within a directory. Later
  files win, as with `talosctl gen config --config-patch`.
- **One document per file**, named for what it configures (this also satisfies
  Talos's rule that one patch file may not modify the same document twice).
  Patches are strategic-merge patches; JSON patches are not used (deprecated
  since Talos 1.12 and incompatible with multi-document configs).
- **Base config:** `talosctl gen config` with the secrets bundle replaces the
  hand-written `controlplane.yaml`/`worker.yaml`. The base carries only what
  Talos generates; everything we configure is in `patches/`.
- **Config contract pin:** `gen config` is pinned to the Talos contract
  version that reproduces what the nodes run today (value chosen during the
  parity step). A 1.14 contract would emit new defaults (workload isolation,
  filesystem trim, `UnattendedInstallConfig`, …) that change behaviour.
- **Deprecated fields** are not copied as-is into the layout where avoidable:
  each becomes its own small document file in the right layer (Phase 1c).
  During parity (Phase 1a) they are reproduced with their current legacy shape.

### 2. Secrets

- Source of truth: Bitwarden Secrets Manager, loaded through `.envrc` (`bws`),
  exactly as today.
- At render time the Talos secrets bundle is generated from the environment
  into a temp file (the current `templates/talosctl-secrets.yaml` mechanism),
  passed to `talosctl gen config --with-secrets`, and deleted afterwards.
- `envsubst` runs **only on files ending in `.yaml.tpl`**, with an explicit
  variable allowlist (`envsubst '$VAR_A $VAR_B'`), never on plain `.yaml`
  files. The filename therefore shows which patches carry secrets, and a stray
  `${…}` in a comment can no longer be substituted. Today the only such patch
  is the nut-client `ExtensionServiceConfig`.
- Rendered files in `clusterconfig/` contain secrets and stay gitignored, as
  today. The `TALHELPER_*` variable names are not renamed in this phase.

### 3. Render pipeline

Per node: `gen config` base for the node's role → apply `patches/all/*`,
`patches/<role>/*`, `patches/node/<name>/*` in order with
`talosctl machineconfig patch` → write `clusterconfig/home-<node>.yaml`.
`talosconfig` generation (`generate:talosconfig`) keeps working from the same
secrets bundle. `TALOS_VERSION`/`KUBERNETES_VERSION` stay in the Taskfile for
Renovate until Phase 2 changes their role.

### 4. Parity gate (Phase 1a)

The new pipeline is built beside the old one and must prove equal output
before the Taskfile switches to it.

1. Render all four nodes with the old and the new pipeline.
2. Normalise both (document and key order sorted, comments stripped) and
   **redact** every `crt:`, `key:`, `token:`, `secret:`, `secretboxEncryptionSecret`,
   `password` and similar value. The raw `talosctl apply-config --dry-run`
   output prints the etcd CA key as unchanged context, so it is not used
   directly.
3. Compare old vs new (must be empty), and compare new vs the live config
   (`talosctl get machineconfig`) on each node.
4. Remaining differences must be listed and explained in the PR (known case:
   the stored install-image tag can lag the running version).
5. Only then does a PR switch the Taskfile. That PR applies nothing to any
   node. Every behavioural change after this point is its own PR with its own
   diff.

### 5. Readability

- **Self-describing files.** Every patch starts with a header:

  ```yaml
  # What:   Serve etcd /metrics over plain HTTP on loopback only
  # Why:    Prometheus scrapes it through kube-system/metrics-proxy
  # Nodes:  control plane
  # Apply:  reboot (etcd is not restarted on apply)
  ```

  `Apply:` is `live` (no reboot) or `reboot (reason)`. The header is the single
  source; nothing else describes the file.
- **`task talos:explain [N=<node>]`** prints, per node, every effective
  document: kind/name (or `v1alpha1` path), the source file, and the What and
  Apply lines from its header.
- **`task talos:diff`** shows repo vs live for all nodes (redacted), plus the
  running Talos version versus the expected one.
- **Generated config map** `docs/src/talos/config-map.md`: the same table for
  all nodes, rendered with a dummy secrets bundle so it contains no values. CI
  fails when it is stale.
- **`provision/talos/README.md`** documents the flow end to end: Bitwarden
  secrets → bundle → base → layers in merge order → `clusterconfig/` →
  `talos:diff` → `talos:apply` per node, with the reboot rules (apply never
  restarts etcd; `talosctl service etcd restart` is refused).

### 6. Phase 1 sub-phases

| Step | Content | Touches nodes? |
|------|---------|----------------|
| 1a | Layout, new pipeline, parity gate, Taskfile switch | No |
| 1b | `explain`, `diff`, config map, README, header convention check in CI | No |
| 1c | One PR per deprecated-field migration (tiers in `.plans/TODO.md`), each with a redacted dry-run diff; apply one node at a time through the usual gate | Yes, per PR |

## Phase 2 outline (own spec later)

- **tuppr** (`home-operations/tuppr`, AGPL-3.0) installed through ArgoCD at
  `cluster/apps/system/tuppr`, with a `TalosUpgrade` and a `KubernetesUpgrade`.
  Renovate bumps their versions; merging the PR is the approval.
- **Health gate** (CEL, evaluated before each node/batch):
  - Nodes Ready.
  - `CephCluster rook-ceph`: `status.ceph.health == "HEALTH_OK"`.
  - **Every CNPG cluster:** `postgresql.cnpg.io/v1 Cluster` with no name or
    namespace (checks all, in all namespaces):
    `status.conditions.exists(c, c.type == "Ready" && c.status == "True") &&
    status.readyInstances == object.spec.instances`. (`exists`, not `all`, so a
    missing condition fails.) Confirmed in tuppr's `checker.go`: empty
    namespace/name lists every object, all must pass, `object` and `status`
    are available.
  - Optional: a Jobs check equivalent to `kubectl wait --for=condition=Complete
    jobs`, to be tested.
- **Access:** `kubernetesTalosAPIAccess.allowedRoles` gains `os:admin` for the
  tuppr namespace only (approved), applied through the new layout.
- **nv1 is excluded** by node selector. tuppr's default is to version-swap the
  node's current install image tag; nv1's compound tag
  (`<talos>-<kernel>-nvgpu<ver>-…`) would not survive that (inferred from the
  docs, to be verified). nv1's tag gets a Renovate custom rule and its upgrade
  stays a manual `task talos:upgrade N=nv1`.
- **Minor-skip protection:** tuppr does not enforce Talos's upgrade path.
  Renovate must propose one minor per PR; the existing `separateMinorPatch`
  grouping is kept and checked.
- The install-image tag in rendered configs and the `TalosUpgrade` version
  move together in one Renovate group so the stored config does not drift.

## Alternatives considered

| Option | Verdict |
|--------|---------|
| talhelper | Archived and abandoned (maintainer points to topf/talstomize). Not used today either. |
| TOPF (PostFinance, v0.6.1) | Fits (layered dirs, Go-templated multi-doc, `bws`-style secrets provider), but pre-1.0 and its upgrade logic would be unused (tuppr covers it). A later swap is easy. |
| talstomize | Good `diff` (booted version, extensions, kernel args), env substitution fits; single maintainer. A later swap is easy. |
| Terraform `siderolabs/talos` provider | Weak fit for node-by-node disruptive operations and our gates; secrets would live in state. |
| Omni | Free for a home-lab but needs a server and a VPN link from every node, and moves the source of truth out of git. |
| In-cluster CI runner for config apply | Rejected: can be killed mid-upgrade. |
| GitHub-hosted runner over VPN | Rejected: exposes a path into the LAN to public runners. |

## Risks

| Risk | Mitigation |
|------|-----------|
| New base changes behaviour (wrong contract version) | Contract pin plus the parity gate; nothing applied by the switch PR |
| Secrets leak through diff/explain output or the generated doc | Redaction filter, dummy bundle for the doc, review of the filter in the parity PR |
| Header/convention rot | CI check that every patch has the four header lines and the config map is fresh |
| tuppr holds `os:admin` for its namespace | Namespace-scoped; only the tuppr namespace listed |
| tuppr + nv1 custom tag | nv1 excluded until verified |
| Renovate skipping Talos minors | One minor per PR, enforced by Renovate rules; reviewed on merge |

## Verification

- Phase 1a: empty redacted diff old-vs-new for all four nodes; new-vs-live
  differences listed and explained.
- Phase 1b: `task talos:explain` output reviewed for all nodes; config-map CI
  check fails on a deliberately stale file.
- Phase 1c: per PR, a redacted dry-run diff showing only the intended change,
  then apply one node at a time through the usual gate.

## Open items for the implementation plan

- Which `gen config` contract version reproduces the current configs.
- Exact variable allowlist for the one `.yaml.tpl` file.
- The CEL expression for completed Jobs (or dropping that gate).
- Renovate datasource and rules for the tuppr CRs and for nv1's custom installer
  tag.
- How the header check and config-map freshness are wired into `task lint:all`
  and CI.
