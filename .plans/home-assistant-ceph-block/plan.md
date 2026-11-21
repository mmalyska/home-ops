---
status: in-progress
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: a77473b173a158d5295154f3a57f822849b41519
branch: fix/home-assistant-ceph-block
worktree: .worktrees/fix/home-assistant-ceph-block
pr: "#6396, #6397, #6398, #6399"
started: 2026-11-21
updated: 2026-11-21
---

# Move Home Assistant config from CephFS to ceph-block

## Goal

Stop the active Ceph mgr from growing about 110 MiB/day and getting OOM-killed. To do that, move the Home Assistant
config volume and its VolSync backup off CephFS (`ceph-filesystem`) onto RBD (`ceph-block`), and run code-server as a
sidecar in the Home Assistant pod.

## Context

On 2026-11-21 at 12:00:20 UTC, the `mgr` container of `rook-ceph-mgr-b` was OOM-killed at its 1610M limit, and two
alerts fired: "Container was OOM-killed" and "Container is close to its memory limit". The comment in
`cluster/apps/core/rook-ceph/cluster/values.yaml` already records a slow leak, about 100 MiB/day, with steps at the
6-hourly VolSync times.

Evidence from 4 days of Prometheus data (`container_memory_working_set_bytes`, `ceph_mgr_status`), collected
2026-11-21:

- The active mgr steps up 20 to 34 MiB at 00:02, 06:02, 12:02 and 18:02 UTC, every day, and creeps about 1 MiB/h in
  between. The standby mgr stays flat at about 148 MiB.
- The `0 */6 * * *` VolSync batch runs at those times. That batch is Home Assistant, bookorbit, matter-server,
  music-assistant, zigbee2mqtt and hermes.
- Of the 27 ReplicationSources, `ha-home-assistant/home-assistant` is the only one on CephFS
  (`ceph-filesystem` / `csi-ceph-filesystem`). The RBD-only batches cause no steps: three at `17 */6` and ten at
  `:10` to `:45 */12`.
- The OOM kill at 12:00:20 fell inside the Home Assistant backup, which started at about 12:00:00 and ran 41 s.
- Backing up from a CephFS snapshot means a subvolume snapshot plus a full clone, and both run inside the mgr
  `volumes` module. RBD snapshots do not go through the mgr.

Upstream issues ruled out:

- [Ceph #59580](https://tracker.ceph.com/issues/59580), the `restful` module leak, was fixed in 19.2.0.
- [Ceph #68989](https://tracker.ceph.com/issues/68989), the `prometheus` module leak, was fixed for Tentacle in
  20.2.2.
- The cluster runs 20.2.4. No report of a leak in the `volumes` module was found.

The current setup:

- `home-assistant-config` is a 10Gi CephFS ReadWriteMany volume holding 28 MiB. The recorder database is on CNPG,
  which uses `ceph-block`, and is not affected.
- Two pods mount the volume: `main`, a StatefulSet with 1 replica, and `addons`, a separate code-server Deployment.
  ReadWriteMany is needed today only because of `addons`.
- `templates/pvc.yaml` creates the PVC. The local `volsync` chart uses it through `pvc.existingClaim`, with
  `restore.enabled: false`.
- `app-config.yaml` has `prune: false`, so removing a resource from git leaves it in the cluster.
- `ai/litellm-chatgpt` also uses `ceph-filesystem`. It has no VolSync backup, so it makes no snapshots and is out of
  scope.

## Decisions

- **D1, code-server as a sidecar** (owner's choice, 2026-11-21). Move the `codeserver` container into the `main`
  controller and delete the `addons` controller. A shared pod guarantees a shared node for the ReadWriteOnce volume.
  Rejected: required pod affinity between the two controllers, which can block a rollout while the volume detaches.
  Accepted cost: a code-server image update restarts Home Assistant.
- **D2, a new PVC under a new name.** The storage class of a PVC cannot be changed in place. The chart creates the new
  PVC, `home-assistant`, from `volsync.nameOverride`, because `pvc.existingClaim` is removed. The ReplicationSource
  name and restic repository (`home-assistant-volsync`) stay the same, so history and retention carry on. The old
  claim stays in the cluster as the rollback copy (`prune: false`).
- **D3, restore with the chart's restore-once ReplicationDestination**, with `restore.enabled: true` and
  `bootstrap: false`, while both controllers are at `replicas: 0`. Rejected: `bootstrap: true`, the volume populator.
  It deadlocked once in this repo (commit 8d0f2034, a fresh app without a backup), and no restore of real data has
  used it here since. A plain PVC and a restore you can watch, with the pod held at zero, is easier to check. Once
  the restore is verified, `restore.enabled` goes back to `false`, so that a recreated destination can never restore
  over live data.
- **D4, the final backup comes from the schedule.** Merge PR 1, which stops Home Assistant, shortly before a 6-hour
  mark. The scheduled `0 */6` run then takes a backup with nothing writing to the volume. A manual trigger is not
  used: ArgoCD selfHeal reverts a hand edit of `spec.trigger`, and the hand edit is itself a runtime mutation.
- **D5, size 5Gi, RBD ReadWriteOnce, snapshot class `csi-ceph-blockpool`.** 28 MiB is used, and RBD is thin. This
  matches the chart default and the other apps.

- **D6, privileged movers in `ha-home-assistant`** (owner's choice, 2026-11-21). VolSync starts a mover with
  `runAsUser: 0` but drops every capability unless the namespace has `volsync.backube/privileged-movers: "true"`.
  The first restore wrote all 409 files (28.121 MiB), but every `lchown` failed ("operation not permitted"), so restic
  exited with "Fatal: There were 626 errors" and the Job kept retrying. Backups only read files, so they never hit
  this. The annotation is set through `managedNamespaceMetadata` in `app-config.yaml`, as `hermes-agent` already
  does. Rejected: a manual `chown -R 568:568` (assumes one owner, several consent steps) and leaving the files
  root-owned (relies on `fsGroup`; anything that calls chmod or chown would fail).

## Rollout

Each merge deploys within seconds through the ArgoCD webhook, and each needs fresh consent with an impact statement.

1. **PR 1, stop:** `replicas: 0` on `main` and `addons`. Merge at about hh:45 before a 6-hour mark (UTC). Home
   Assistant is down from here until PR 4.
2. **Final backup:** the scheduled run at the next `:00` backs up the stopped volume. Check its `lastSyncTime`.
3. **PR 2, migrate:** sidecar, new `ceph-block` PVC, VolSync on RBD, restore enabled, replicas still 0. Merge away
   from a `:00` mark. Check that the restore has finished.
4. **PR 3, privileged movers** (added 2026-11-21 after the first restore failed): annotate the namespace with
   `volsync.backube/privileged-movers: "true"`, then re-run the restore. See D6.
5. **PR 4, start:** `replicas: 1` and `restore.enabled: false`. Home Assistant and code-server start on RBD.
6. **Watch for 48 h:** no mgr step at the 6-hour marks, and Home Assistant healthy.
7. **Clean up (consent-gated):** delete the CephFS VolSync cache PVC after the first good RBD backup. Delete the old
   `home-assistant-config` claim after 7 days. Update the comment and docs.

Expected downtime was planned at 15 to 30 minutes, between PR 1 and PR 4. The failed restore made it longer.

**Rollback:** revert PR 2 and PR 4. Home Assistant goes back to the untouched `home-assistant-config` claim. Anything
written to the new volume after the cutover is lost.

## Success criteria

- Home Assistant and code-server run in one pod on `home-assistant` (`ceph-block`, ReadWriteOnce), with the
  restored configuration (same entities, integrations and users).
- The `home-assistant` ReplicationSource completes on `ceph-block` / `csi-ceph-blockpool`.
- For 48 h after PR 4, no 5-minute jump of more than 10 MiB in the active mgr's memory at `:00`–`:05` past 00, 06,
  12 or 18 UTC.
- No CephFS PVC is left in `ha-home-assistant` after cleanup.

## Out of scope

- The remaining ~1 MiB/h creep. Investigate it separately if it is still there after the steps stop.
- `ai/litellm-chatgpt` on CephFS.
- Changing the mgr memory limit. Revisit only after the 48 h check.

## Status

2026-11-21: plan approved (code-server as a sidecar).

- PR 1 (#6396) was merged at 15:21 UTC, earlier than the hh:45 window. Home Assistant is stopped. The last scheduled
  backup (12:00) came before the stop, so the owner chose a manual backup.
- T2: manual trigger `final-cephfs-2026-11-21`, run at 15:28:43 UTC, `Successful`: restic snapshot `1dda3d60`,
  409 files, 28.121 MiB. ArgoCD stayed Synced (its diff ignores a field that git does not manage). The `manual`
  field must be removed before PR 2 merges, or VolSync keeps ignoring the schedule.
- PR 2 (#6397) was merged at 15:30:29 UTC. The restore copied the data but failed on `lchown` (D6). PR 3 adds the
  annotation.
- PR 3 (#6398) was merged at 15:45:16 UTC, and the annotation was live at 15:46:29. With owner consent, the failing
  Job was deleted. VolSync recreated it, and it restored snapshot `1dda3d60` at 15:46:46 UTC, `Successful`, with 0
  errors (no `lchown` failures).
- PR 4 is prepared: `replicas: 1`, `restore.enabled: false`.
- PR 2 was prepared first. app-template renamed the single-controller StatefulSet, and `forceRename` keeps its old name
  (added to T3).
