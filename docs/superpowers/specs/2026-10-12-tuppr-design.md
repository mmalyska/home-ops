# tuppr (Talos and Kubernetes upgrade controller) — Design

**Status:** approved in conversation 2026-10-12, spec awaiting review. Tracked in `.plans/TODO.md`.

## Context

Talos and Kubernetes upgrades are run by hand today: `task talos:upgrade N=<node>` per node (gated on `wait_for_health`, with a
check that the node booted the expected version) and `task talos:upgrade:k8s`. This spec installs
[tuppr](https://github.com/home-operations/tuppr) (`home-operations/tuppr`, AGPL-3.0, chart 0.5.7 at the time of writing) so
that a merged Renovate PR rolls the upgrade out, one node at a time, behind a health gate.

Phase 2 of `2026-10-05-talos-config-layout-design.md` sketched this. Two decisions changed since: **nv1 is in scope** (the sketch
excluded it), and the health gate also covers running backups.

### Goal and success

- mc1, mc2, mc3 and nv1 are upgraded to the Talos version in git, one at a time, and Kubernetes to the version in git.
- Nothing starts while Ceph, a CNPG cluster, a CNPG backup, a VolSync sync or any Job is not healthy or idle.
- The first rollout is explicitly approved; afterwards merging a Renovate bump is the approval.
- `task talos:diff` shows no drift after a run. `task talos:upgrade` stays as the manual fallback.

### What tuppr does (verified in its docs and source, 2026-10-12)

- `TalosUpgrade` (many allowed, queued) and `KubernetesUpgrade` (exactly one). One upgrade at a time across the whole
  cluster; the two kinds never overlap.
- Health checks are CEL expressions on live objects, run before each node. An empty name or namespace lists every object, and
  every object must pass.
- It upgrades to **exactly** the version in the CR. It does not enforce Talos's one-minor-at-a-time path.
- Image resolution: the node's current install image with the tag swapped for the target version (a Factory schematic is
  kept). It checks that the registry serves the image, and pre-pulls it, before anything is cordoned; a missing image parks
  the run as `WaitingForImage`.
- After a node upgrade it patches the **live** machine config's install image (`ApplyConfiguration`, `NO_REBOOT`).
- Verification compares the version the node reports with the target version **exactly**. The per-node
  `tuppr.home-operations.com/version` annotation is used verbatim as the image tag *and* in that comparison, so it cannot
  carry nv1's compound tag.
- `tuppr.home-operations.com/suspend`, `reset`, maintenance windows, Alertmanager silences (a short renewed lease) and a
  per-CR `nodeSelector` exist. Pre-hooks suppress the inter-batch health checks.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| nv1 | Plain alias tag `ghcr.io/mmalyska/custom-installer:v<talos>` pushed next to the compound tag | tuppr swaps the tag for the plain version, so the alias makes nv1 an ordinary node. The compound tag stays the audit trail |
| First rollout | CRs committed with `tuppr.home-operations.com/suspend: "true"`; a PR removing it is the go | Declarative, visible in git, no fight with ArgoCD `selfHeal` |
| Autonomy afterwards | A second PR removes the annotation for good | The user's call: gated first, then fully automatic |
| Health gate | CEL checks, no pre-hooks | Pre-hooks would suppress the inter-batch checks |
| Namespace | `tuppr` | Repo convention (namespace = app name); the Talos API access document must list the same name |
| Ceph `noout` | Not handled by tuppr | Rook already handles node reboots; keeps the gate simple |

## Design

### 1. The app: `cluster/apps/system/tuppr/`

- `app-config.yaml`: `enabled: "true"`, `namespace: tuppr`, `syncPolicy.enabled: true`, `selfHeal: true`, `prune: false`.
  The CRDs come with the chart; the CRs use a later `syncWave` (or `SkipDryRunOnMissingResource`) so they do not apply
  before the CRDs exist.
- `Chart.yaml`: dependency `tuppr` from `oci://ghcr.io/home-operations/charts`, pinned version (Renovate-tracked).
- `values.yaml`: ServiceMonitor, PrometheusRule and dashboards on; `silences.enabled: true` with
  `alertmanager.address: http://prometheus-stack-kube-prom-alertmanager.monitoring:9093`; the controller tolerates the
  control-plane taint (the chart default).
- `templates/`: `TalosUpgrade/cluster` and `KubernetesUpgrade/kubernetes`. They live in git so the `renovate:` comments are
  readable by Renovate.

### 2. Talos API access

`provision/talos/patches/controlplane/40-talos-api-access.yaml` (`KubeTalosAPIAccessConfig`) gains `os:admin` and
`tuppr` under `allowedRoles` and `allowedKubernetesNamespaces`. Live apply, no reboot. The header lines are updated. The
`os:admin` role is granted to the `tuppr` namespace only, and the namespace is not shared with another app.

**Verify on the cluster (plan task):** the document is control-plane only here. tuppr's docs say to apply the setting to
every node; confirm that the upgrade Job reaches nv1 through the control plane's `apid` and that nv1 needs no copy.

### 3. Upgrade plans

- `TalosUpgrade/cluster`, no `nodeSelector`, so mc1, mc2, mc3 and nv1, one at a time (`parallelism: 1`).
  **Verify (plan task):** the node order tuppr uses. If it can put nv1 before a control plane, split into two plans
  (control plane first, nv1 second; plans queue).
- `policy`: `waitForVolumeDetach: true` (Ceph RBD), `timeout: 30m`, `drainTimeout` raised so the CNPG primary switchover fits.
  `prePull` stays on.
- `KubernetesUpgrade/kubernetes`: same health checks. `task talos:upgrade:k8s` stays the manual route.
- Both CRs: annotation `tuppr.home-operations.com/suspend: "true"` until the first-run PR.
- `maintenance.windows`: one weekly window clear of the backup schedules, for example Sunday 08:00 for 4h in the cluster's
  timezone. VolSync syncs fire at 00:20-00:45, 02:00-03:00 and every 6h on the hour and last under 2 minutes; the exact slot
  is confirmed against `kubectl get replicationsources -A` when the plan is written.

### 4. Health gate (the same list on both CRs)

| Check | Object | Passes when |
| --- | --- | --- |
| Nodes | `v1/Node`, all | `status.conditions.exists(c, c.type == "Ready" && c.status == "True")` |
| Ceph | `ceph.rook.io/v1 CephCluster rook-ceph` | `status.ceph.health == "HEALTH_OK"` |
| CNPG healthy | `postgresql.cnpg.io/v1 Cluster`, all namespaces | a `Ready` condition is `True` and `status.readyInstances == object.spec.instances` |
| CNPG backup idle | `postgresql.cnpg.io/v1 Backup`, all | `status.phase` is not `started`, `running` or `finalizing` (`has()` guards a missing status) |
| VolSync idle | `volsync.backube/v1alpha1 ReplicationSource`, all | the `Synchronizing` condition is `False` |
| Jobs idle | `batch/v1 Job`, all | `!has(status.active) \|\| status.active == 0` |

Each check has a `timeout` so a run waits for a backup to finish instead of failing at once.

**Verify (plan task, read-only):** evaluate every expression against today's live objects and confirm each one passes now
and fails for a deliberately running object (a manual `Job`, or a VolSync sync during its window).

**Known weak spot:** the Jobs check is broad: any active Job in any namespace holds the run. That is the intent
("any backup"), and the window is wide enough; the check is narrowed by label only if it blocks too often.

### 5. Renovate and drift

- `renovate:` comments on `spec.talos.version` (`ghcr.io/siderolabs/talos`) and `spec.kubernetes.version`
  (`ghcr.io/siderolabs/kubelet`). `separateMajorMinor` and `separateMinorPatch` so each PR is one hop.
- One Renovate group moves, in one PR: the `TalosUpgrade` version, `TALOS_VERSION` and `KUBERNETES_VERSION` in
  `.taskfiles/talos/Taskfile.yaml`, and the nv1 compound tag in `provision/talos/patches/node/nv1/20-install-image.yaml`.
- Why drift is transient: the PR changes the rendered install image in git, then tuppr patches the live install image to the
  same value. Between the merge and the end of the run `task talos:diff` shows the difference; do not `task talos:apply`
  during a run. After the run the diff must be clean (success criterion).
- A bump merged before nv1's installer exists is safe: the pre-check parks the run as `WaitingForImage`. A PR that moves
  the compound tag's kernel or nvgpu part is built first, in the fork.

### 6. nv1 prerequisite (outside this repo)

`mmalyska/talos-jetson-orin`: the installer build workflow also pushes `custom-installer:v<talos>` for the same image
(a second tag, same digest). It must stay public (nv1 pulls anonymously, see `node/nv1/20-install-image.yaml`).
**Follow-up:** offer the alias-tag change upstream to `schwankner/talos-jetson-orin`.

### 7. Observability, rollback, emergency stop

- Chart PrometheusRule and dashboard. A tuppr Alertmanager silence for
  `CephMonDown|CephOSDDown|KubeNodeUnreachable|TargetDown`, `maxDuration: 2h`; confirm in the plan that it does not mask the
  cluster's own alerts (the Ceph alert job-scoping caveat applies).
- Stop: set the suspend annotation, or scale the controller to 0. Retry a failed run with the `reset` annotation.
- A failed or stuck node is handled with the existing procedures in `cluster-reference` (stale UKI on nv1, CNPG PDB drain).

## Rollout order

1. Alias tag exists in the fork (nv1 prerequisite). mc1-mc3 do not need it.
2. PR 1: app, values, access document, CRs **suspended**. Verify: render, lint, controller up, webhook, metrics.
3. Evaluate the gate expressions read-only against live objects.
4. PR 2: remove `suspend` from `TalosUpgrade`. First run is a no-op at the current version, then a patch bump.
5. After a clean Talos run and a clean `talos:diff`: remove `suspend` from `KubernetesUpgrade`, same procedure.
6. PR 3: no `suspend` anywhere, docs and `cluster-reference` updated; `.plans/TODO.md` entry closed.

## Out of scope

- The `TALOS_CONTRACT` v1.14 bump, and any change to the Talos config layout.
- Replacing `task talos:upgrade` / `task talos:upgrade:k8s`.
- Handling Ceph `noout` or draining policy beyond tuppr's defaults.

## Risks

| Risk | Mitigation |
| --- | --- |
| tuppr does not enforce the minor-by-minor path | Renovate groups one hop per PR; the version in git is reviewed |
| nv1 boots a stale UKI after an upgrade (Jetson UEFI) | tuppr's version check fails the node; the existing procedure in `provision/talos/README.md` applies |
| A bump merges while a backup runs | The gate waits; the window avoids the schedules |
| `os:admin` for a namespace | Only `tuppr`; the namespace holds only the controller; RBAC reviewed in the chart |
| AGPL-3.0 | Used unmodified as a service; no change to the repo's licence |
