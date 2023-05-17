## How to recover from backup

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
