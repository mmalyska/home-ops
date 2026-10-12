# tuppr: Talos and Kubernetes upgrades

[tuppr](https://github.com/home-operations/tuppr) (`home-operations/tuppr`, app `cluster/apps/system/tuppr`, namespace
`tuppr`) rolls out Talos and Kubernetes upgrades from git. Merging a Renovate PR that bumps the version is the approval:
tuppr upgrades one node at a time behind a health gate. The design is in
`docs/superpowers/specs/2026-10-12-tuppr-design.md`.

## What it runs

| Resource            | Name         | Does                                                          |
| ------------------- | ------------ | ------------------------------------------------------------- |
| `TalosUpgrade`      | `cluster`    | mc1, mc2, mc3 and nv1, one at a time, to `spec.talos.version` |
| `KubernetesUpgrade` | `kubernetes` | the Kubernetes version, to `spec.kubernetes.version`          |

Both live in `cluster/apps/system/tuppr/templates/` and carry the same health gate and the same maintenance window
(Sunday 07:00 for 4h, Europe/Warsaw). Only one upgrade runs at a time across the cluster; the two kinds never overlap.

**State until the first run:** both CRs are committed with `tuppr.home-operations.com/suspend: "true"`, so nothing
starts. The first run has not happened yet. Anything below marked "to be confirmed on the first run" is expected
behaviour taken from tuppr's source, not observed here.

## How a run goes

- **Order:** the node that runs the tuppr controller first, then by name (mc1, mc2, mc3), nv1 last (the controller cannot
  schedule on nv1).
- **Pre-pull:** before anything is cordoned tuppr checks that the installer image of every node exists (for nv1 the
  alias tag `ghcr.io/mmalyska/custom-installer:v<talos>`) and pre-pulls it. A missing image parks the run as
  `WaitingForImage`; nothing is cordoned.
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
  If the window closes between nodes the run parks as `MaintenanceWindow` and resumes in the next window. Mixed
  versions for up to a week are expected then (nv1 is last).
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
`selfHeal` puts it back; the live removal is only for testing):

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

Emergency stop (the controller stops; the node being upgraded is not touched by this):

```sh
kubectl scale deployment tuppr -n tuppr --replicas=0
```

ArgoCD `selfHeal` scales it back up; for a longer stop set the suspend annotations in git or disable the app's sync.

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

Kubernetes is held at `<=1.35` in `.github/renovate/allowedVersions.json5`.

## nv1 and the alias tag

nv1 runs our own Jetson installer. tuppr uses the node's install image with the tag swapped to the target version and
patches the live config to it, so git holds the plain alias tag `ghcr.io/mmalyska/custom-installer:v<talos>`
(`provision/talos/patches/node/nv1/20-install-image.yaml.tpl`), not the compound `v<talos>-<kernel>-nvgpu...` tag.
The fork `mmalyska/talos-jetson-orin` pushes that alias tag (same digest as the compound tag) next to the compound
tag, and it must stay public. The kernel and nvgpu part stay in the fork's release notes. A change of the kernel or
nvgpu part is built in the fork first and its alias re-pointed.

**Prerequisite, not done yet:** the fork does not push the alias tag yet. On 2026-10-12 the public tag list of
`ghcr.io/mmalyska/custom-installer` has only compound tags (latest `v1.14.2-6.18.54-nvgpu39.2.1-jp7`) and no plain
`v1.14.2`. Until the fork workflow is changed and the alias for the current version is backfilled, an nv1 upgrade parks
as `WaitingForImage`. mc1 to mc3 do not need it. Verify before the first run:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $(curl -s 'https://ghcr.io/token?scope=repository:mmalyska/custom-installer:pull' | jq -r .token)" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  https://ghcr.io/v2/mmalyska/custom-installer/manifests/v1.14.2   # 200 = alias exists
```

Upstreaming the alias tag change to `schwankner/talos-jetson-orin` is tracked in `.plans/TODO.md`.

## Talos API access

The upgrade Job and talosctl reach Talos through the `KubeTalosAPIAccessConfig` in
`provision/talos/patches/controlplane/40-talos-api-access.yaml`, which lists `os:admin` and the `tuppr` namespace. The
document has one roles list and one namespaces list, so `talos-backup` also gets `os:admin`. Whether nv1 needs a copy of
the document (the upgrade Job reaches it through the control plane's `apid`) is to be confirmed on the first run.

## When things go wrong

- **`WaitingForImage`:** the installer image of some node is not served by the registry. Check the tag (for nv1 the
  alias tag, see above). The run resumes by itself once the image exists; nothing was cordoned.
- **`MaintenanceWindow`:** parked between nodes; it resumes at the next window. Remove the window from the CR only in
  git.
- **`Failed`:** terminal. Read the controller logs and the node state, fix the cause, then annotate with `reset` (or
  edit the spec).
- **A node never converges (drain stalls):** a CNPG primary's PDB usually means an unhealthy replica. Fix the replica
  first, do not force the drain; `kubectl uncordon <node>` restores evicted Ceph pods and Ceph recovers on its own
  (see `cluster-reference`). tuppr uncordons itself after a failed drain and retries after 1 minute.
- **nv1 reports the old version after the upgrade:** the Jetson UEFI booted a stale UKI. Do not re-run the upgrade; use
  the fix in `provision/talos/README.md` ("nv1 boots the wrong UKI after an upgrade").
- **Do not `task talos:apply` while a `TalosUpgrade` is running:** tuppr changes the live install image during the run
  and `task talos:diff` differs from git until it ends. After a run `task talos:diff` must be clean.

## Manual fallback

`task talos:upgrade N=<node>`, `task talos:upgrade:all` and `task talos:upgrade:k8s` remain; suspend the matching CR
first so tuppr and the task never upgrade at the same time.
