# tuppr: Talos and Kubernetes upgrades

[tuppr](https://github.com/home-operations/tuppr) (`home-operations/tuppr`, app `cluster/apps/system/tuppr`, namespace
`tuppr`) rolls out Talos and Kubernetes upgrades from git. Merging a Renovate PR that bumps the version is the approval:
tuppr upgrades one node at a time behind a health gate. The design is in
`.archive/.plans/superpowers/specs/2026-10-12-tuppr-design.md`.

## What it runs

| Resource            | Name         | Does                                                          |
| ------------------- | ------------ | ------------------------------------------------------------- |
| `TalosUpgrade`      | `cluster`    | mc1, mc2, mc3 and nv1, one at a time, to `spec.talos.version` |
| `KubernetesUpgrade` | `kubernetes` | the Kubernetes version, to `spec.kubernetes.version`          |

Both live in `cluster/apps/system/tuppr/templates/` and carry the same health gate and the same maintenance window
(Sunday 07:00 for 4h, Europe/Warsaw). Only one upgrade runs at a time across the cluster; the two kinds never overlap.

The behaviour described here that is not marked "to be confirmed" comes from reading tuppr 0.5.7's source and docs, not
from a run in this cluster.

**State:** both CRs are unsuspended in git. `TalosUpgrade/cluster` was unsuspended on 2026-10-12 and ran as a no-op at
the running version (see "The first run" below). `KubernetesUpgrade/kubernetes` ran the first real upgrade on
2026-10-12, Kubernetes 1.35.9 to 1.36.5 (see "The first real upgrade" below). The first real Talos upgrade, v1.14.2 to
v1.14.4 on all four nodes, ran on 2026-10-21 (see "The first real Talos upgrade" below); it covered the installer
pre-pull, the drain, the node reboots and the nv1 image swap. The Talos health gate itself was not tested with a
blocking Job (the Kubernetes run tested it). The chart's `PrometheusRule` is on again (`values.yaml`);
`TupprUpgradeBlocked` (reason `Waiting.*` or `Suspended`, for 30m, warning, routed to Discord) fires if a CR is
suspended again, which is intended. Anything below marked "to be confirmed on the first run" is expected behaviour taken
from tuppr's source, not observed here.

## How a run goes

- **Order:** the node that runs the tuppr controller first, then by name (mc1, mc2, mc3), nv1 last (the controller cannot
  schedule on nv1).
- **Pre-pull:** at the start of a run, before anything is cordoned, tuppr checks the installer image of every pending
  node (for nv1 the alias tag `ghcr.io/mmalyska/custom-installer-jp7:v<talos>`) and pre-pulls it. A missing image holds the
  whole run: it parks as `Pending` with reason `PrePullFailed` and a 1 to 5 minute backoff, so mc1 to mc3 are held too and
  nothing is cordoned. `WaitingForImage` is the per-batch registry check.
- **Drain:** with `policy.waitForVolumeDetach: true` tuppr drains the node itself: cordon, evict respecting PDBs, wait
  for the pods to terminate, then up to 2 minutes best-effort for CSI volume detach. The upgrade Job then runs with
  talosctl's own drain disabled. The drain timeout is hardcoded to 10 minutes (the CR's `drainTimeout` is not used and
  was removed).
- **Drain failure is safe:** when eviction fails (for example a PDB answers 429) tuppr uncordons the node and requeues
  after 1 minute. It does not reboot. A CNPG primary's PDB may stall a node this way; the usual cause is an unhealthy
  replica (see "A node never converges"). To be confirmed on the first run.
- **After the upgrade:** tuppr patches the live install image of the node (`NO_REBOOT`) and checks that the node reports
  exactly the target version.
- **Window:** the maintenance window is checked at the start and between batches, before the health gate, so a node may
  start up to about 1h after the window closes (the gate wait). A node whose upgrade already started always finishes.
  If the window closes between nodes the run parks as `MaintenanceWindow` and is expected to resume in the next window
  (to be confirmed on the first run). Mixed versions for up to a week are expected then (nv1 is last).
- **Silences:** tuppr holds an Alertmanager silence for `CephMonDown|CephOSDDown|KubeNodeUnreachable|TargetDown`
  (`maxDuration: 2h`, renewed as a short lease).

## Health gate

The same list on both CRs, evaluated before each node:

| Check            | Object                                            | Passes when                                                | Timeout |
| ---------------- | ------------------------------------------------- | ---------------------------------------------------------- | ------- |
| Nodes            | `v1/Node`, all                                    | a `Ready` condition is `True`                              | 10m     |
| Ceph             | `CephCluster rook-ceph`                           | `status.ceph.health` is `HEALTH_OK`                        | 30m     |
| CNPG healthy     | `postgresql.cnpg.io/v1 Cluster`, all              | `Ready` is `True` and `readyInstances == spec.instances`   | 30m     |
| CNPG backup idle | `postgresql.cnpg.io/v1 Backup`, all               | `status.phase` is not `started`, `running` or `finalizing` | 1h      |
| VolSync idle     | `volsync.backube/v1alpha1 ReplicationSource`, all | no `Synchronizing` condition that is `True`                | 1h      |
| Jobs idle        | `batch/v1 Job`, all                               | `status.active` is absent or `0`                           | 1h      |

How the gate behaves:

- Only the largest per-check `timeout` (1h) bounds the whole gate. When it elapses the run is retried every minute; it
  does not become `Failed`.
- An object without a `status` fails open for the Backup, ReplicationSource and Job checks, and fails closed (the run
  retries) for the CephCluster and CNPG Cluster checks.
- The Jobs check is broad on purpose: any active Job in any namespace holds the run. It is narrowed by label only if it
  blocks too often.

## Start, suspend, resume

First run (and afterwards): the `suspend` annotation is in git. A PR that removes it from `TalosUpgrade/cluster` is the
go for the first Talos run; remove it from `KubernetesUpgrade/kubernetes` after a clean Talos run and a clean
`task talos:diff`. A later PR removes the annotation for good so that Renovate bumps run unattended.

Temporary stop or resume without a PR, once the annotation is no longer in git (while git carries it, ArgoCD
`selfHeal` is expected to put it back, to be confirmed on the first run; the live removal is only for testing):

```sh
kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend="true"
kubectl annotate talosupgrade cluster tuppr.home-operations.com/suspend-
```

Same for `kubernetesupgrade kubernetes`.

Retry a `Failed` run (`Failed` is terminal until the `reset` annotation or an edit of the spec):

```sh
kubectl annotate talosupgrade cluster tuppr.home-operations.com/reset="$(date +%s)" --overwrite
```

The value is any new string (the annotation is a trigger); to be confirmed on the first run.

Emergency stop (from tuppr 0.5.7 source): while a run waits on the health gate (up to 1h, blocking), a suspend
annotation set during the wait is ignored if the gate then passes, because the same reconcile drains the node and creates
the Job. In that case stop the controller:

```sh
kubectl scale deployment tuppr -n tuppr --replicas=0
```

What this does to a run already past the gate is unverified: a running upgrade Job or an already-cordoned node may be
affected, and a cordoned node has to be uncordoned by hand. While the controller is down its webhook (`failurePolicy:
Fail`) rejects edits to the tuppr CRs (from tuppr 0.5.7 source), so `kubectl annotate ... suspend` fails: scale the
controller back up first, or delete the webhook configuration only with the owner's approval.

ArgoCD `selfHeal` is expected to scale it back up (to be confirmed on the first run). If it does, `--replicas=0` is
only a short stop; the durable stop is a PR that sets the suspend annotations (or disables the app).

Watch a run: `kubectl get talosupgrade,kubernetesupgrade` (phase, current node), the tuppr controller logs, and the
`TalosUpgrade` / tuppr dashboard in Grafana.

## Renovate

One Renovate group for Talos and one for Kubernetes (`.github/renovate/groups.json5`). Each moves, in one PR:

- Talos: `spec.talos.version` in `templates/talosupgrade.yaml` and `TALOS_VERSION` in `.taskfiles/talos/Taskfile.yaml`.
- Kubernetes: `spec.kubernetes.version` in `templates/kubernetesupgrade.yaml` and `KUBERNETES_VERSION` in the same
  Taskfile.

`separateMultipleMinor` and `separateMinorPatch` make every PR a single minor hop (tuppr itself does not enforce
Talos's one-minor-at-a-time path, it upgrades to exactly the version in the CR). Automerge is explicitly off for these
files: merging the PR is the approval and starts the rollout.

Kubernetes is held at `<=1.36` in `.github/renovate/allowedVersions.json5`.

## nv1 and the alias tag

nv1 runs our own Jetson installer. tuppr uses the node's install image with the tag swapped to the target version and
patches the live config to it, so git holds the plain alias tag `ghcr.io/mmalyska/custom-installer-jp7:v<talos>`
(`provision/talos/patches/node/nv1/20-install-image.yaml.tpl`), not the compound `v<talos>-<kernel>-nvgpu...` tag.
The JetPack 7 installer has its own repository `custom-installer-jp7` (the r36 line stays in `custom-installer`). The
fork `mmalyska/talos-jetson-orin` pushes that alias tag (same digest as the compound tag) next to the compound
tag, and the package must stay public. The kernel and nvgpu part stay in the fork's release notes. A change of the kernel or
nvgpu part is built in the fork first and its alias re-pointed.

**Done 2026-10-12:** the fork change lives on branch `pr/jetpack7-r39` of `mmalyska/talos-jetson-orin` (the head of the
upstream draft PR `schwankner/talos-jetson-orin#65`; the earlier fork PR #11 is superseded). It gives each JetPack line
its own repository and pushes the alias tag. The publish (run 38250608703 on commit 0193c66) succeeded and anonymous
GETs return 200: `custom-installer-jp7:v1.14.2` is the same image as `:v1.14.2-6.18.54-nvgpu39.2.1-jp7`
(`sha256:ce05b088dcb880975577d217454df6c7cdbc81af26d23376115d9a52105cfd34`), and the package is public. A retag by hand is not possible (no registry write token outside CI), so the alias
is mutable and re-pointed by each publish. The jp7 installer is a fresh build; nothing has been applied to nv1 yet, so
the first real bump installs it. If the alias is ever missing, any bump parks the whole run as `Pending` /
`PrePullFailed` (the run-start pre-pull covers every pending node, so mc1 to mc3 are held too).
Re-check before the first run, and before the nv1 install image is applied to the node:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:mmalyska/custom-installer-jp7:pull' | jq -r .token)" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  https://ghcr.io/v2/mmalyska/custom-installer-jp7/manifests/v1.14.2   # 200 = alias exists
```

A 404 means the alias tag is not published (dispatch the publish from `pr/jetpack7-r39`); a 401 or 403 means the
package exists but is not public (make it public in the package settings).

Upstreaming the alias tag change to `schwankner/talos-jetson-orin` is tracked in `.plans/TODO.md`.

## Talos API access

The upgrade Job and talosctl reach Talos through the `KubeTalosAPIAccessConfig` in
`provision/talos/patches/controlplane/40-talos-api-access.yaml`, which lists `os:admin` and the `tuppr` namespace. The
document has one roles list and one namespaces list; the `talos-backup` namespace only gains `os:admin` if its Talos
ServiceAccount's roles change (today it requests `os:etcd:backup` only).

The point to take from this: Secret `tuppr/tuppr-talosconfig` now holds an `os:admin` Talos credential, and tuppr's
ClusterRole can read every Secret cluster-wide and create Jobs. Any principal that can read Secrets in the `tuppr`
namespace (or read all Secrets) reaches full Talos control of the control planes.

Whether nv1 needs a copy of the document (the upgrade Job reaches it through a control plane's `apid`) is to be confirmed
on the first run; the no-op first run proves it (see "The first run").

**Order:** the document must be live before the PR that installs the controller is merged. The controller mounts Secret
`tuppr-talosconfig`, which Talos creates only once the document allows `tuppr` / `os:admin`, and the webhook has
`failurePolicy: Fail`. Apply from the branch checkout (`task talos:generate`, then `task talos:apply` per control plane).
nv1's install image is applied only after the alias tag check above returns 200.

## The first run

With every node already on the version in the CRs, unsuspending is a no-op: the run ends `Completed` and no
`HealthChecks` events are emitted. It proves only the Talos API access (GetNodeVersion, including nv1 through a control
plane's `apid`); with no node pending, tuppr finishes before the health gate and the image pre-pull.

**Observed 2026-10-12** (a one-off window was used so it did not wait for Sunday): the plan went `MaintenanceWindow` to
`Completed` at the moment the window opened (`completedAt` 17:00 Warsaw), with `status.completedNodes: [mc1, mc2, mc3,
nv1]` and the message "Successfully upgraded 4 nodes". That wording is misleading: `completedNodes` lists every node that
was already at the target version. No upgrade Job was created, `prePulledNodes` stayed empty, no node was cordoned, node
uptimes were unchanged (no reboot) and no events were emitted. The window is checked before anything else, so an
unsuspend outside a window parks as `MaintenanceWindow` even when there is nothing to do.

Read-only precondition:
`talosctl version` per node and `kubectl get nodes -o wide` must show the CR's version everywhere, otherwise unsuspending
is a real upgrade.

## The first real upgrade

**Observed 2026-10-12, Kubernetes 1.35.9 to 1.36.5** (a one-off window was used so it could be watched live; it has been
removed again):

- **Gate test:** a throwaway Job (`sleep 1800`, namespace `tuppr`) was created before the window opened. The window
  opened at 21:50 and tuppr emitted `HealthChecksStarted`. While the Job was active there was no `HealthChecksPassed`
  and nothing moved. The Job was deleted at 21:52:20 and `HealthChecksPassed` followed 11 seconds later, then
  `UpgradeStarted`. **No `HealthChecksFailed` event is emitted while the gate waits**: tuppr blocks inside the check
  (up to the largest per-check timeout, 1h) and the phase stays at its previous value until the wait returns. The
  signal for "the gate is holding" is `HealthChecksStarted` without a `Passed`, then `Passed` once the blocker is gone.
  Create the Job before the window opens, otherwise the first evaluation can pass before it exists.
- **Rollout:** control plane components first (kube-apiserver on mc1, mc2, mc3 in turn; one API blip of about 20 s while
  the last one restarted), then the kubelets; `Completed: Cluster successfully upgraded to v1.36.5` at 21:58, about six
  minutes after the window opened. One upgrade Job (`kubernetes-mc1-...`) ran in the `tuppr` namespace; no node rebooted.
- **Drift:** `talosctl upgrade-k8s` also writes `image: registry.k8s.io/kube-proxy:<version>` into the live
  `KubeProxyConfig` of the control planes, although kube-proxy is disabled. The repo did not carry it, so `task
talos:diff` showed that one line on mc1 to mc3. `controlplane/32-kube-proxy-disabled.yaml.tpl` now pins the image from
  `KUBERNETES_VERSION`, and the diff is clean on all four nodes.
- **During the rollout:** do not `task talos:apply` any node: the rendered configs already pin the target images.
  `task talos:diff` shows drift until the run completes.

## The first real Talos upgrade

**Observed 2026-10-21, Talos v1.14.2 to v1.14.4** (kernel 6.18.54 to 6.18.57) on mc1, mc2, mc3 and nv1, started by merging
the Renovate PR plus a one-off window (removed again). Times are UTC.

- **Start:** ArgoCD synced the new spec at 10:54. A changed spec resets the run (`Spec changed, resetting upgrade
process`), then `Pending` / `PrePulling`.
- **Pre-pull:** the nodes pull one after the other. The three control planes took 2m44s, 14s and 11s. nv1's 592 MB
  `custom-installer-jp7` installer stalled at about 440 of 540 MiB on three attempts ("no pull progress after 1m30s ...
  registry may be failing requests") while nv1 had about 125 MB `MemAvailable` with `llama-server` running; it passed on
  a later attempt without any change. The run-wide pre-pull held mc1 to mc3 for about 40 minutes in total. A pull in
  progress shows no pod: it is a Talos `ImageService/Pull` call (the node's `machined` log prints it when it ends), and
  `status.prePulledNodes` stays empty until the batch is done.
- **Order and timing:** the node hosting the controller first (mc1; the controller restarted when it rebooted and carried
  on), then mc2, mc3, nv1. Each control plane took about 5 to 7 minutes from cordon to Ready; all came back on the new
  version without help. Ceph showed `HEALTH_WARN` (one OSD down, Rook's maintenance flags) after each reboot and the gate
  waited for `HEALTH_OK` between nodes.
- **Drain:** with `waitForVolumeDetach` the drain finished within a minute or two and tuppr then waited its 2 minutes
  best-effort for CSI detach ("Volumes did not detach before timeout, proceeding with upgrade") on every node and carried
  on. No PDB stalled a drain.
- **nv1 booted the old image.** The upgrade Job succeeded in 3 minutes and the node rebooted, but came back on v1.14.2
  and kernel 6.18.54. The default entry still named `Talos-v1.14.2~4.efi`. The first guess, the Jetson UEFI dropping the installer's
  write of `LoaderEntryDefault`, did not survive testing (EFI writes persist; more likely Talos reverted after a failed
  first boot of the new image), see "nv1 and the alias tag" and `provision/talos/README.md`. tuppr then waited for the
  version; at about 12:02 it marked the run `Failed` (`node nv1 version mismatch: current=v1.14.2, target=v1.14.4`) and
  left nv1 cordoned, so `llama-server` stayed `Pending`. Fix, done at 12:13 to 12:18: renamed the stale UKI from a
  privileged pod, rebooted nv1 once (it came back on v1.14.4, kernel 6.18.57, `LoaderEntrySelected`
  `talos-v1.14.4.efi`, GPU 1, CDI on), uncordoned nv1, annotated the `TalosUpgrade` with `reset` (it went straight to
  `Completed`, "Successfully upgraded 4 nodes"), then deleted the renamed `.bak` UKI. The reset run did not redo nv1's
  post-upgrade step, so `task talos:diff` still showed one line on nv1: the live `UnattendedInstallConfig`
  `installer.image` was `custom-installer-jp7:v1.14.2` against `v1.14.4` in git. A dry run (`talosctl apply-config
--dry-run -m auto`) showed that line only and "without a reboot"; `task talos:apply N=nv1` (or the same
  `talosctl apply-config ... -m auto` on the rendered `home-nv1.yaml`) cleared it, and `task talos:diff` was then clean on
  all four nodes. `task talos:generate` needs the local `talosctl` at the target version first (`task talos:install`).
- **Cost:** the local LLM was offline from the nv1 drain (11:54) to the `llama-server` restart (about 12:24), about 30
  minutes, longer than the node's own reboot because of the stale boot entry.
- **nv1 and kexec:** nv1 has `kernel.kexec_load_disabled=1` (see "nv1 and kexec" below), which avoids the stale-UKI
  problem; the rename is only a fallback. `Failed` is terminal, so plan for the `reset` and the uncordon in the same session.

## nv1 and kexec

By default Talos reboots after an upgrade through kexec. On nv1 (Jetson Orin) the kexec load fails, and Talos answers a
failed `kexecPrepare` by reverting the boot entry to the previous UKI, so nv1 comes back on the old version while the
upgrade reports success (the 2026-10-21 incident). The revert is read from Talos's source (`revertBootloader` in
`machined`) and from the result; no log line announces it, while the failed kexec and the old UKI booting are observed.

nv1 therefore sets `kernel.kexec_load_disabled: "1"` (`provision/talos/patches/node/nv1/42-sysctl-kexec.yaml`). Talos
logs `kexec support is disabled via sysctl` and reboots through the firmware into the new entry. It is node-only, so mc1
to mc3 keep kexec. `policy.rebootMode: powercycle` on the `TalosUpgrade` would also work but applies to every node of the CR
(and was set for a few hours on 2026-10-21 before the sysctl was found).

Evidence, 2026-10-21, three same-version upgrades of nv1 with `talosctl upgrade --image .../custom-installer-jp7:v1.14.4`
and the Talos logs in Loki (`{source=~"talos-.*", node="nv1"}`); each installs another v1.14.4 UKI named
`Talos-v1.14.4~N.efi` (identical checksum), which makes the boot visible without a version change:

| Run                              | Log                                                                                                                           | Booted                                              |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `--reboot-mode powercycle`       | `kexec skipped as reboot with power cycle was requested`                                                                      | the new UKI, about 3 minutes in total               |
| default (kexec)                  | `kexec_file(Image): Could not find any suitable kernel location!`, `reboot failed: error running phase 13 in reboot sequence` | the previous UKI (`~1`) although `~2` was installed |
| default, `kexec_load_disabled=1` | `kexec support is disabled via sysctl`, `phase kexec (13/14): done`                                                           | the new UKI (`~3`), `LoaderEntrySelected` `~3`      |

EFI variable writes persisted in separate tests, so the earlier theory that the Jetson firmware drops the installer's
write was wrong (corrected on schwankner/talos-jetson-orin#69). Why the kexec load fails on this hardware is not known;
the upstream report is [siderolabs/talos#14692](https://github.com/siderolabs/talos/issues/14692) (a failed kexec should
fall back to a normal reboot instead of triggering the revert); see `.plans/TODO.md`. The sysctl cannot be set back to 0
without a reboot (a one-way switch), which is fine here.

## When things go wrong

- **`Pending` / `PrePullFailed`, or `WaitingForImage`:** the installer image of a node is not served by the registry
  (`PrePullFailed` is the run-start pre-pull of every pending node, `WaitingForImage` the per-batch check). Check the tag
  (for nv1 the alias tag, see above). The run is expected to resume by itself once the image exists (to be confirmed on
  the first run); nothing was cordoned.
- **`MaintenanceWindow`:** parked between nodes; expected to resume at the next window (to be confirmed on the first run). Remove the window from the CR only in
  git.
- **`Failed`:** terminal. Read the controller logs and the node state, fix the cause, then annotate with `reset` (or
  edit the spec).
- **A node never converges (drain stalls):** a CNPG primary's PDB usually means an unhealthy replica. Fix the replica
  first, do not force the drain; `kubectl uncordon <node>` restores evicted Ceph pods and Ceph recovers on its own
  (see `cluster-reference`). tuppr uncordons itself after a failed drain and retries after 1 minute.
- **nv1 reports the old version after the upgrade:** nv1 booted the previous UKI because kexec failed and Talos reverted the boot entry (see "nv1 and kexec"). This should not happen with `kernel.kexec_load_disabled=1` on nv1. Do not re-run the upgrade; use
  the fix in `provision/talos/README.md` ("nv1 boots the wrong UKI after an upgrade"). Seen on 2026-10-21: the run goes
  `Failed` with `node nv1 version mismatch`, nv1 stays cordoned and `llama-server` stays `Pending`. After the fix:
  `kubectl uncordon nv1`, then `kubectl annotate talosupgrade cluster tuppr.home-operations.com/reset="$(date +%s)"
--overwrite`; the run completes with nothing left to do.
- **nv1 pre-pull stalls at about 80% ("no pull progress after 1m30s"):** nv1 runs with very little free memory while
  `llama-server` is up, so a 590 MB image pull can crawl. tuppr retries by itself (a 1 to 5 minute backoff) and it passed
  on the 2026-10-21 run; if it keeps failing, pausing `llama-server` through git frees memory (see the memory note
  `reference_nv1_gpu_test_pause`).
- **Do not `task talos:apply` while a `TalosUpgrade` is running:** tuppr changes the live install image during the run
  and `task talos:diff` differs from git until it ends. After a run `task talos:diff` must be clean.

## Manual fallback

`task talos:upgrade N=<node>`, `task talos:upgrade:all` and `task talos:upgrade:k8s` remain; suspend the matching CR
first so tuppr and the task never upgrade at the same time.
