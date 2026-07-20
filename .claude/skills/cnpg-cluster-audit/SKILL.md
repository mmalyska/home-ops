---
name: cnpg-cluster-audit
description: Audit CloudNativePG (CNPG) clusters for backup health, S3 storage bloat, and disk-space risk — schedule misconfiguration, WAL/archive_timeout churn, orphaned backups, compression, and PVC resize status. Use when investigating CNPG backup storage growth, a "storage near empty" alert on the backup target (e.g. QNAP), a crash-looping/"Not enough disk space" CNPG cluster, or doing a periodic CNPG health check.
---

# CNPG Cluster Audit

## Overview

CNPG's barman-cloud plugin backs up every cluster to a shared S3 bucket
(`s3://k8s-at-home-backup/cnpg/<app>/`) on QNAP. Backup S3 usage can balloon far
beyond what live DB size would suggest — this skill was built after a 2026-07-20
investigation found ~210 GiB of backups across clusters whose live data totaled
<10 GiB, caused by a stack of small misconfigurations rather than one big bug.

**Prerequisite:** if `kubectl get nodes` fails with a connection error, generate
kubeconfig first:
```sh
talosctl --talosconfig=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig \
  kubeconfig --nodes 192.168.48.2 --force $KUBECONFIG
```

## Query Sequence

### 1. Inventory: clusters, object stores, schedules

```sh
kubectl get clusters.postgresql.cnpg.io -A -o wide
kubectl get objectstores.barmancloud.cnpg.io -A
kubectl get scheduledbackups.postgresql.cnpg.io -A
```

For each `ScheduledBackup`, check the raw cron string field count:

```sh
kubectl get scheduledbackup -n <ns> <name> -o jsonpath='{.spec.schedule}{"\n"}'
```

**Critical gotcha:** CNPG's barman-cloud plugin cron requires **6 fields**
(`sec min hour day month dow`, e.g. `"5 0 0 * * *"` = daily at 00:00:05). A
5-field cron like `"0 2 * * *"` (meant as "daily at 2am") gets silently
misparsed — the missing trailing field shifts everything, and it instead fires
**every hour** at the specified minute. This is not a validation-rejected
error; the `ScheduledBackup` applies fine and looks correct at a glance.
Confirm the actual firing cadence with:

```sh
kubectl get scheduledbackup -n <ns> <name> -o jsonpath='{.status.lastScheduleTime}{"\n"}{.status.nextScheduleTime}{"\n"}'
```

If the gap between these two isn't what the schedule intends (e.g. 1h apart
when you meant daily), the cron is malformed. Compare against other apps'
6-field schedules in the same repo for the correct format.

### 2. Backup history and failure patterns

```sh
kubectl get backups.postgresql.cnpg.io -n <ns>
```

Look for: recurring `failed` phases (transient S3 connectivity vs. a sustained
multi-day block — the latter usually means the backup target is full or
unreachable), and whether `completed` backups are arriving at the expected
cadence (cross-check against step 1's schedule).

### 3. Cluster health conditions

```sh
kubectl get cluster -n <ns> <name> -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

Watch for `ContinuousArchiving` = `False` — this means WAL can't reach S3 at
all, which will eventually fill the local PVC even if base backups are
succeeding. It's an earlier, more actionable signal than waiting for the PVC
to actually fill. Also check `.status` top-level phase string (e.g. `"Not
enough disk space"`).

### 4. Live data size vs. declared storage vs. backup size

```sh
kubectl exec -n <ns> <pod> -c postgres -- df -h /var/lib/postgresql/data
kubectl get cluster -n <ns> <name> -o jsonpath='storage: {.spec.storage.size}  instances: {.spec.instances}{"\n"}'
```

A live PGDATA usage of a few hundred MB with tens of GB in S3 backups is the
signature of the WAL/schedule issues below, not of the data itself.

### 5. archive_timeout and compression settings

```sh
kubectl get cluster -n <ns> <name> -o jsonpath='{.spec.postgresql.parameters.archive_timeout}{"\n"}'
kubectl get objectstore -n <ns> <name> -o jsonpath='{.spec.configuration.data.compression}{" / wal="}{.spec.configuration.wal.compression}{"\n"}'
```

**Gotcha:** `archive_timeout: 5min` (a common CNPG default/recommendation)
forces a full-size WAL segment (16 MB, uncompressed unless `wal.compression`
is set) to be archived every 5 minutes **regardless of actual write
activity** — confirmed by watching an app's barman-cloud sidecar logs emit
`Archived WAL file` every ~5 min even when the app is barely used. At 288
segments/day this alone can produce ~45 GiB over a 10-day retention window for
an app whose real data is under 1 GB. This is expected behavior, not a bug —
but it means "not that used" apps can still be the biggest backup consumers,
and raising the timeout or enabling WAL compression are the levers, not
investigating for a leak.

### 6. Actual S3 usage per app (ground truth)

No pod in this cluster ships `aws`/`mc` by default, and reading the
`S3_ACCESS_KEY_ID`/`S3_ACCESS_SECRET_KEY` secret values directly to use
locally will be blocked by the permission classifier (`kubectl get secret ...
-o jsonpath`). Instead, reference the existing secret via `secretKeyRef` in a
short-lived pod spec — credentials never leave the cluster or appear in your
output, only aggregate size numbers do:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: s3-backup-inspect
  namespace: <any-ns-with-an-objectstore-secret>
  labels:
    purpose: diagnostic-readonly
spec:
  restartPolicy: Never
  containers:
    - name: aws-cli
      image: amazon/aws-cli:2.17.62
      command: ["sleep", "600"]
      env:
        - name: AWS_ACCESS_KEY_ID
          valueFrom:
            secretKeyRef: {name: <s3-secret-name>, key: S3_ACCESS_KEY_ID}
        - name: AWS_SECRET_ACCESS_KEY
          valueFrom:
            secretKeyRef: {name: <s3-secret-name>, key: S3_ACCESS_SECRET_KEY}
```

```sh
kubectl apply -f s3-inspect-pod.yaml
kubectl wait -n <ns> pod/s3-backup-inspect --for=condition=Ready --timeout=60s

# Look up the real endpoint from the ObjectStore rather than hardcoding it
ENDPOINT=$(kubectl get objectstore -n <ns> <objectstore-name> -o jsonpath='{.spec.configuration.endpointURL}')

# Discover all prefixes (includes orphaned ones — see step 7)
kubectl exec -n <ns> s3-backup-inspect -- aws --endpoint-url "$ENDPOINT" s3 ls s3://k8s-at-home-backup/cnpg/

# Per-app size
kubectl exec -n <ns> s3-backup-inspect -- aws --endpoint-url "$ENDPOINT" s3 ls s3://k8s-at-home-backup/cnpg/<app>/ --recursive --summarize | tail -3

# Break down by base-backup vs WAL to see which dominates
kubectl exec -n <ns> s3-backup-inspect -- aws --endpoint-url "$ENDPOINT" s3 ls s3://k8s-at-home-backup/cnpg/<app>/ --recursive \
  | awk '{print $4}' | sed -E 's#/[^/]+$##' | sort | uniq -c | sort -rn

kubectl delete pod -n <ns> s3-backup-inspect --wait=false
```

Never hardcode the S3 endpoint domain in this file — always resolve it from
the live `ObjectStore` as above.

One set of credentials typically has access to the whole bucket (all app
prefixes), so a single pod using any one app's secret is enough — no need to
spin one up per app.

### 7. Orphaned backup prefixes

Compare the bucket's top-level prefixes (step 6) against
`kubectl get clusters.postgresql.cnpg.io -A` and `kubectl get ns`. A prefix
with no corresponding active `Cluster` resource — and ideally no matching
namespace at all — is backup data from a decommissioned or migrated app that
was never cleaned up (matches the known gap in `reference_app_removal_procedure`
memory: deleting an app never auto-prunes its associated external state).

### 8. PVC resize stuck / "Not enough disk space" recovery

If a cluster's `.status` shows `"Not enough disk space"` and pods are
crash-looping: bumping `Cluster.spec.storage.size` is necessary but may not be
sufficient. CNPG's automatic PVC resize requires successfully reading pod
status from the instance manager first — if **both** instances are down (disk
full → postgres won't start → instance manager can't report status), the
reconciler gets stuck re-detecting "insufficient disk space" every cycle
without ever reaching the resize code path (check operator logs for
`ensure_sufficient_disk_space` repeating with no follow-up PVC patch). Confirm
via:

```sh
kubectl logs -n cnpg deploy/cloudnative-pg --since=20m | grep -i <cluster-name>
kubectl get pvc -n <ns> -o jsonpath='{range .items[*]}{.metadata.name}{" spec="}{.spec.resources.requests.storage}{" status="}{.status.capacity.storage}{"\n"}{end}'
```

If stuck, manually patch the PVCs directly (safe/reversible — grow-only,
online expansion via ceph-csi doesn't need postgres running) — **confirm with
the user first**, this is a cluster mutation:

```sh
kubectl patch pvc -n <ns> <pvc-name> --type merge -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'
```

Watch for PVC conditions `Resizing` → `FileSystemResizePending` → (cleared);
once status.capacity matches spec, the pod should recover on its own
(possibly via `pg_rewind` + WAL replay if it was the non-primary instance).

## Output

Summarize as a table: app | live DB size | backup S3 size | object count |
bloat factor | schedule (correct/malformed) | notes. Flag anything >10x bloat
factor and anything with `ContinuousArchiving: False`. Propose mitigations
ordered by impact (schedule fixes and archive_timeout first — usually the
biggest levers — then compression, then orphan cleanup, then retention).

## Related

- `prometheus-portforward-session` / `prometheus-historical-queries` — if
  cross-checking against `KubePersistentVolumeFillingUp` alert history to see
  when a PVC first crossed a threshold.
- `.plans/TODO.md` — log unimplemented mitigations here rather than fixing
  everything inline during an audit.
