## How to recover from backup

1. Create PVC
  ```yml
  kind: PersistentVolumeClaim
  apiVersion: v1
  metadata:
  name: datavol
  spec:
  accessModes:
      - ReadWriteOnce
  resources:
      requests:
      storage: 3Gi
  ```

2. Enable restore
  ```yml
  apiVersion: volsync.backube/v1alpha1
  kind: ReplicationDestination
  metadata:
    name: datavol-dest
  spec:
    trigger:
      manual: restore-once
    restic:
      repository: restic-repo
      # Use an existing PVC, don't provision a new one
      destinationPVC: datavol
      copyMethod: Direct
  ```
