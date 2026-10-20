# tuppr (Talos and Kubernetes upgrade controller) — Design

**Status:** implemented 2026-10-12 (plan `.plans/superpowers/plans/2026-10-12-tuppr.md`); first run was a verified no-op,
the first real upgrade through tuppr is pending. Tracked in `.plans/TODO.md`.

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
  kept). At the start of a run it checks that the registry serves the image of every pending node, and pre-pulls it, before
  anything is cordoned; a missing image parks the whole run as `Pending` / `PrePullFailed` (1 to 5 minute backoff), and
  `WaitingForImage` is the per-batch registry check.
- After a node upgrade it patches the **live** machine config's install image (`ApplyConfiguration`, `NO_REBOOT`).
- Verification compares the version the node reports with the target version **exactly**. The per-node
  `tuppr.home-operations.com/version` annotation is used verbatim as the image tag *and* in that comparison, so it cannot
  carry nv1's compound tag.
- `tuppr.home-operations.com/suspend`, `reset`, maintenance windows, Alertmanager silences (a short renewed lease) and a
  per-CR `nodeSelector` exist. Pre-hooks suppress the inter-batch health checks.

## Decisions

| Decision | Choice | Why |
| --- | --- | --- |
| nv1 | Git holds the alias tag `ghcr.io/mmalyska/custom-installer-jp7:${TALOS_VERSION}` (a `.yaml.tpl`), pushed by the fork next to the compound tag | tuppr patches nv1's live install image to the alias tag, so a compound tag in git would leave `task talos:diff` dirty; the alias makes nv1 an ordinary node. The kernel and nvgpu part stay in the fork's release notes |
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
- `values.yaml`: ServiceMonitor and dashboards on; PrometheusRule **off** until the `KubernetesUpgrade` is unsuspended
  (the chart rule `TupprUpgradeBlocked` fires for every suspended CR); `silences.enabled: true` with
  `alertmanager.address: http://prometheus-stack-kube-prom-alertmanager.monitoring:9093`; the controller tolerates the
  control-plane taint (the chart default).
- `templates/`: `TalosUpgrade/cluster` and `KubernetesUpgrade/kubernetes`. They live in git so the `renovate:` comments are
  readable by Renovate.

### 2. Talos API access

`provision/talos/patches/controlplane/40-talos-api-access.yaml` (`KubeTalosAPIAccessConfig`) gains `os:admin` and
`tuppr` under `allowedRoles` and `allowedKubernetesNamespaces`. Live apply, no reboot. The header lines are updated.
`KubeTalosAPIAccessConfig` is one document with one roles list and one namespaces list; `talos-backup` only gains
`os:admin` if its Talos ServiceAccount's roles change (today it requests `os:etcd:backup` only). Secret
`tuppr/tuppr-talosconfig` holds an `os:admin` Talos credential and tuppr's ClusterRole can read every Secret and create
Jobs, so any principal that can read Secrets in the `tuppr` namespace (or all Secrets) reaches full Talos control of the
control planes.

**Verify on the cluster (plan task):** the document is control-plane only here. tuppr's docs say to apply the setting to
every node; confirm that the upgrade Job reaches nv1 through the control plane's `apid` and that nv1 needs no copy.

### 3. Upgrade plans

- `TalosUpgrade/cluster`, no `nodeSelector`, so mc1, mc2, mc3 and nv1, one at a time (`parallelism: 1`).
  tuppr sorts nodes by name and puts the node running its own controller first, so nv1 is always last (the controller
  cannot schedule on nv1: it tolerates only control-plane and critical-addon taints). One plan is enough.
- `policy`: `waitForVolumeDetach: true` (Ceph RBD), `timeout: 30m`. `drainTimeout` was removed: it is dead config together
  with `waitForVolumeDetach`; tuppr's drain timeout is hardcoded to 10 minutes. `prePull` stays on.
- `KubernetesUpgrade/kubernetes`: same health checks. `task talos:upgrade:k8s` stays the manual route.
- Both CRs: annotation `tuppr.home-operations.com/suspend: "true"` until the first-run PR.
- `maintenance.windows`: one weekly window clear of the backup schedules, for example Sunday 07:00 for 4h (ends 11:00, clear of the 12:00 syncs) in the cluster's
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
- Two Renovate groups: Talos moves the `TalosUpgrade` version and `TALOS_VERSION`, Kubernetes moves the
  `KubernetesUpgrade` version and `KUBERNETES_VERSION` (both in `.taskfiles/talos/Taskfile.yaml`), each in one PR. nv1's installer image in git is the alias tag
  `ghcr.io/mmalyska/custom-installer-jp7:${TALOS_VERSION}` (a `.yaml.tpl`, like the control-plane document), because tuppr
  patches nv1's live install image to the alias tag and a compound tag in git would leave `task talos:diff` dirty. The alias
  is a tag that the fork re-points for a Talos version; the kernel and nvgpu part stay in the fork's release notes.
- Why drift is transient: the PR changes the rendered install image in git, then tuppr patches the live install image to the
  same value. Between the merge and the end of the run `task talos:diff` shows the difference; do not `task talos:apply`
  during a run. After the run the diff must be clean (success criterion).
- A bump merged before nv1's installer exists is safe: the run-start pre-pull parks the whole run as `Pending` /
  `PrePullFailed` before anything is cordoned (mc1 to mc3 are held too). A PR that moves
  the kernel or nvgpu part is built first, in the fork, and its alias tag re-pointed.

### 6. nv1 prerequisite (outside this repo)

`mmalyska/talos-jetson-orin`, branch `pr/jetpack7-r39` (head of upstream draft PR `schwankner/talos-jetson-orin#65`): each JetPack
line has its own repository (`custom-installer` for r36, `custom-installer-jp7` for r39), and the release workflow also pushes
`custom-installer-jp7:v<talos>` for the same image (a second tag, same digest). The new package must be made public after the first publish and stay public (nv1 pulls anonymously, see `node/nv1/20-install-image.yaml.tpl`).
**Follow-up:** offer the alias-tag change upstream to `schwankner/talos-jetson-orin`.

### 7. Observability, rollback, emergency stop

- Chart dashboard and ServiceMonitor; the chart PrometheusRule is off until the `KubernetesUpgrade` is unsuspended. A tuppr
  Alertmanager silence for `CephMonDown|CephOSDDown|KubeNodeUnreachable|TargetDown`, `maxDuration: 2h`; confirm in the
  plan that it does not mask the cluster's own alerts (the Ceph alert job-scoping caveat applies). The silence is capped
  at 2h, so the last node (nv1) of a long run can reboot after it lapsed and `KubeNodeUnreachable` / `TargetDown` may
  fire; accepted.
- Stop: set the suspend annotation (ignored if set while a run waits on the health gate and the gate then passes), or
  scale the controller to 0 (while it is down the webhook rejects CR edits). Retry a failed run with the `reset` annotation.
- A failed or stuck node is handled with the existing procedures in `cluster-reference` (stale UKI on nv1, CNPG PDB drain).

## Rollout order

1. Alias tag exists in the fork (nv1 prerequisite): the run-start pre-pull holds every node without it.
2. Talos API access document live first (the controller mounts the Secret Talos creates from it; the webhook is
   `failurePolicy: Fail`), then PR 1: app, values, CRs **suspended**. Verify: render, lint, controller up, webhook, metrics.
3. Evaluate the gate expressions read-only against live objects.
4. PR 2: remove `suspend` from `TalosUpgrade`. First run is a no-op at the current version (it proves only the Talos API
   access), then a patch bump (the first real exercise of the health gate).
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
| `os:admin` for a namespace | Secret `tuppr/tuppr-talosconfig` holds an `os:admin` Talos credential and tuppr's ClusterRole can read every Secret and create Jobs: any principal that can read Secrets in `tuppr` (or all Secrets) reaches full Talos control of the control planes. `talos-backup` only gains `os:admin` if its ServiceAccount's roles change; RBAC reviewed in the chart |
| AGPL-3.0 | Used unmodified as a service; no change to the repo's licence |
