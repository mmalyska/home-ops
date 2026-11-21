# Tasks: home-assistant-ceph-block

App directory: `cluster/apps/home-automation/home-assistant/` (below: `APP/`). Namespace: `ha-home-assistant`.
Each merge deploys and needs fresh owner consent, with the impact stated. Commands in `consent-gated` blocks change
the cluster. Run them only after the owner approves that exact command in the current session.

Render check for every PR:

```sh
cd APP && helm dependency build >/dev/null && helm template home-assistant . -f values.yaml > /tmp/ha.yaml
task lint:manifests -- home-assistant   # read the output, the task always exits 0
.agents/bin/check-plans
```

## T1. PR 1: stop Home Assistant

- [x] In `APP/values.yaml`, set `replicas: 0` on `controllers.main`, and add `replicas: 0` to `controllers.addons`.
      Add the comment `# 0 during the ceph-block migration (.plans/home-assistant-ceph-block)`.
- [x] Render. The StatefulSet `home-assistant-main` and the Deployment `home-assistant-addons` have `replicas: 0`.
      Nothing else changes.
- [x] Open the PR. Ask the owner to merge it at about hh:45 UTC before a 6-hour mark (hh+1 is one of 00, 06, 12, 18).
      Impact: Home Assistant and code-server are down until T4.
- [x] After the merge, both pods are gone: `kubectl -n ha-home-assistant get pods`.

**Done when:** no `home-assistant-main-0` or `home-assistant-addons-*` pod is running.

## T2. Final backup

- [x] Wait for the scheduled run at the 6-hour mark. Check that it started after T1's merge time:
      `kubectl -n ha-home-assistant get replicationsource home-assistant -o jsonpath='{.status.lastSyncTime} {.status.latestMoverStatus.result}'`
- [x] Record the time and result in the Status section of `plan.md`.

**Done when:** `lastSyncTime` is later than T1's merge and the result is `Successful`. If the run fails, stop and
report it. Do not start T3.

## T3. PR 2: migrate (replicas stay 0)

Edit `APP/`:

- [x] Delete `templates/pvc.yaml`. Leave the old claim alone: `prune: false` keeps it in the cluster as the rollback
      copy.
- [x] Sidecar: move the `codeserver` container block from `controllers.addons.containers` to
      `controllers.main.containers`, and delete `controllers.addons`. Under `service.codeserver`, set
      `controller: main`. The route `addons` already uses `identifier: codeserver` and needs no change.
- [x] `persistence.config.existingClaim: home-assistant`.
- [x] `volsync:` block:

  ```yaml
  volsync:
    nameOverride: home-assistant # PVC, ReplicationSource and restic repo name; keeps the existing repo
    pvc:
      accessMode: ReadWriteOnce
      capacity: 5Gi
      storageClass: ceph-block
      volumeSnapshotClass: csi-ceph-blockpool
    volsync:
      # moverSecurityContext and backup: unchanged
      restore:
        # one-off restore into the new ceph-block PVC; set back to false in T4
        enabled: true
        bootstrap: false
  ```

- [x] Render and check:
  - PVC `home-assistant`: `ceph-block`, ReadWriteOnce, 5Gi, no `dataSourceRef`, sync wave -1.
  - ReplicationDestination `home-assistant-bootstrap`: `trigger.manual: restore-once`,
    `destinationPVC: home-assistant`, `repository: home-assistant-volsync`, mover running as UID 0.
  - ReplicationSource `home-assistant`: `sourcePVC: home-assistant`, `ceph-block`, `csi-ceph-blockpool`,
    ReadWriteOnce, schedule `0 */6 * * *`.
  - StatefulSet `home-assistant-main` has the containers `main` and `codeserver`, still at replicas 0, and mounts the
    claim `home-assistant` at `/config`. No `home-assistant-addons` Deployment remains.
  - No PVC `home-assistant-config` in the output.
- [ ] Open the PR. Ask the owner to merge it at least 15 minutes away from a `:00` mark.
- [ ] After the merge, watch the restore:
      `kubectl -n ha-home-assistant get replicationdestination home-assistant-bootstrap -o jsonpath='{.status.lastSyncTime} {.status.latestMoverStatus.result}'`.
      Then read the mover's logs: the pod is `volsync-dst-home-assistant-bootstrap-*`
      (`kubectl -n ha-home-assistant get pods`). Look for restic's restored file count and size (the snapshot holds
      about 28 MiB).
- [ ] Check that the snapshot it restored is the one T2 made: the restic snapshot time in the mover log.

**Done when:** the destination reports `Successful`, the restored size matches the backup (about 28 MiB), and the
snapshot is T2's.

## T4. PR 3: start on ceph-block

- [ ] In `APP/values.yaml`, set `controllers.main.replicas: 1` and remove the migration comment. Set
      `volsync.volsync.restore.enabled: false`, and put back the comment
      `# existing data: never render the restore-once ReplicationDestination`.
- [ ] Render. The StatefulSet is at replicas 1. No ReplicationDestination remains (with `prune: false`, the live one
      stays as an orphan, and T6 handles it).
- [ ] Open the PR. Ask the owner to merge it. Impact: Home Assistant starts on the new volume.
- [ ] Check:
  - `home-assistant-main-0` shows 2/2 Ready. `kubectl -n ha-home-assistant exec home-assistant-main-0 -c main -- du -sh /config`
    shows about 28 MiB.
  - The Home Assistant UI loads with the existing users, integrations and entities. code-server opens `/config`.
  - The logs contain no onboarding or "new installation" messages:
    `kubectl -n ha-home-assistant logs home-assistant-main-0 -c main --since=10m`.

**Done when:** all three checks pass. If they fail: revert PR 2 and PR 3 (owner consent), then check that Home
Assistant runs on `home-assistant-config` again.

## T5. Watch for 48 hours

- [ ] After the next `:00` mark, check that the ReplicationSource ran on RBD (`Successful`, with a new `lastSyncTime`).
- [ ] After 48 hours, query the active mgr's memory at 5-minute steps over the window (port-forward
      `svc/prometheus-stack-kube-prom-prometheus` in `monitoring`). Query:
      `max by (pod) (container_memory_working_set_bytes{namespace="rook-ceph",pod=~"rook-ceph-mgr.*",container="mgr"})`,
      with `ceph_mgr_status` to find the active daemon. Count the jumps of more than 10 MiB at `:00`–`:05` past 00, 06,
      12 and 18 UTC.
- [ ] Record the result in `plan.md`.

**Done when:** no such jumps. If they continue, the CephFS link is wrong. Record that, keep the migration (it is
harmless) and reopen the investigation.

## T6. Clean up (each step consent-gated)

- [ ] After the first good RBD backup (T5), delete the CephFS cache PVC so that VolSync recreates it on `ceph-block`:

  ```sh consent-gated
  kubectl -n ha-home-assistant delete pvc volsync-src-home-assistant-cache
  ```

  At the next run, the recreated cache is `ceph-block`.

- [ ] Delete the orphaned `addons` Deployment (at 0 replicas since T1, out of git since T3):

  ```sh consent-gated
  kubectl -n ha-home-assistant delete deployment home-assistant-addons
  ```

- [ ] Delete the orphaned ReplicationDestination left from T3:

  ```sh consent-gated
  kubectl -n ha-home-assistant delete replicationdestination home-assistant-bootstrap
  ```

- [ ] At least 7 days after T4, with Home Assistant healthy and at least one good RBD backup, delete the old claim.
      This is DESTRUCTIVE: show the owner the backup evidence first.

  ```sh consent-gated
  kubectl -n ha-home-assistant delete pvc home-assistant-config
  ```

- [ ] Docs PR:
  - Update the mgr comment in `cluster/apps/core/rook-ceph/cluster/values.yaml` with the T5 finding (the cause and
    the date it stopped).
  - Add a note to the `cluster-reference` skill (in `.agents/skills/`, then run `.agents/bin/sync-skills`): VolSync
    on CephFS clones through the mgr `volumes` module and grows the mgr. Use `ceph-block` for volumes that are
    backed up.
- [ ] Archive the plan ("Archive after Ship" in `.plans/README.md`).

**Done when:** no CephFS PVC remains in `ha-home-assistant`, the docs are merged and the plan is archived.
