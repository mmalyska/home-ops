# How to recover from backup

1. Create PVC

```yml
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  name: jellyfin-config
  namespace: jellyfin
spec:
accessModes:
  - ReadWriteOnce
resources:
  requests:
  storage: 3Gi
```

2. Enable restore

```yml
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: jellyfin-dest
  namespace: jellyfin
spec:
  trigger:
    manual: restore-once
  restic:
    repository: jellyfin-restic-secret
    destinationPVC: jellyfin-config
    copyMethod: Direct
    moverSecurityContext:
      runAsUser: 1001
      runAsGroup: 1001
      fsGroup: 1001
```

# A backup stopped: VolumeSnapshot stuck in deletion

The alert `VolSyncVolumeOutOfSync` (one hour out of sync) is the sign. It happened on 2026-10-26 (`music-assistant`,
11 days without a backup) and 2026-11-02 (`coder-mmalyska-devops`).

Cause: VolSync snapshots the PVC, then waits for the snapshot to be deleted before the next run ("snap is being deleted
-- need to wait" in the `volsync` pod log, every minute). The ceph-csi provisioner adds the finalizer
`provisioner.storage.kubernetes.io/volumesnapshot-as-source-protection` while it clones the snapshot and removes it
afterwards. When the removal races with another update of the VolumeSnapshot it logs `Failed to remove snapshot
finalizer ... the object has been modified` (a warning, about 9 seconds after the snapshot is created) and does not
retry, so the finalizer stays. This happened 12 times in 30 days. Ten snapshots were cleaned up anyway; two were not.
Why those two differ is not known.

Check:

```sh
kubectl get volumesnapshot -A -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | "\(.metadata.namespace)/\(.metadata.name) since \(.metadata.deletionTimestamp)"'
kubectl -n <namespace> get volumesnapshotcontent | grep <snapshot-name>   # the content is already gone in this case
```

Fix, only when the snapshot has a `deletionTimestamp` older than an hour, its only finalizer is the provisioner one and
no PVC uses it. It changes the cluster, so ask the owner first:

```sh consent-gated
kubectl -n <namespace> patch volumesnapshot <snapshot-name> --type=merge -p '{"metadata":{"finalizers":null}}'
```

VolSync then starts a new sync on its own. The same stuck snapshot keeps the tuppr "VolSync idle" health check waiting
(it times out after 1 hour), so clear it before a Talos upgrade run.
