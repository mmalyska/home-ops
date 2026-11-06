# Ceph and disk write load

Why the cluster's disks wear, how to measure it, and what was changed in October 2026.
The full investigation is archived in `.archive/TODO.md` (history; check the live state first).

**Short version:** the SATA Ceph OSD disks received about 0.3 to 0.4 MB/s each, every client write lands on all three of them (3 replicas on 3 OSDs),
and the SSDs add about 2x write amplification inside. After the cuts below the pool's client writes are mostly the downloads (sabnzbd) and a long tail of small writers.

## Hardware and what is at stake

| Disk | Where | Metric | State (2026-10-29) |
|---|---|---|---|
| NVMe system disk | mc1 to mc3 (etcd, `/var/lib/rook` mons) | `percentage_used` | 4 / 4 / 4 %, about 0.6 MB/s written |
| SATA SSD (Crucial MX500) | mc1 to mc3, raw Ceph OSD | `Percent_Lifetime_Remain` (raw value is the used percentage) | 71 / 68 / 76 % used, about +0.14 % a day |

The SATA disks are the problem: mc3 would reach 95 % used in about 130 days at the observed pace. The replacement is an open item in `.plans/TODO.md`.

## How to measure

- **Per workload:** `container_fs_writes_bytes_total`, always with `container!=""`. The series also exists at pod level, so an unfiltered sum is exactly 2x.
- **Pool:** `ceph_osd_op_w_in_bytes` and the pool client writes agree within a few percent. Each OSD disk gets the whole stream.
- **Per RBD image is not available:** `ceph_rbd_*` metrics are not exported, so the per-pod series above is the only per-workload view.
- **Disk truth:** SMART `Total_LBAs_Written` (SATA), `Host_Program_Page_Count` and `FTL_Program_Page_Count` (FTL divided by host is the write amplification), and `percentage_used` (NVMe). Cross-check `node_disk_written_bytes_total`: a node reboot resets the counter inside a long window and under-reports (the 7-day average read 0.117 MB/s against the true 0.34).
- Prometheus here keeps 30 days (10 days earlier), so older comparisons need the values recorded in the TODO history.

## Where the bytes went, and what was done

| Writer | Finding | Change |
|---|---|---|
| Ceph mons (NVMe) | About two thirds of the control plane disks' writes, from RocksDB compaction after each paxos trim | `mon_compact_on_trim=false` in the Rook `configOverride`: about 20 to 25 % less. All three mons also fell to about 0.12 MB/s for an unexplained reason on the same day |
| Prometheus | WAL 49 %, compaction about 35 %; cAdvisor scraped every 10 s was 42 % of all samples | cAdvisor to 60 s and two unused histograms dropped (PRs #5869, #5870): 0.084 to 0.044 MB/s |
| Loki | WAL checkpoints were 98 % of its writes, sized by stream churn, not ingest | `checkpoint_duration` 30m (PR #5867): 0.047 to 0.019 MB/s |
| PostgreSQL (CNPG) | pgaudit lines, about 270 MB a day of logs | `pgaudit.log: none` in `pgsql-cnpg` 1.6.0 |
| MongoDB (anytype) | Probe connection lines, 141 MB a day of logs | Dropped in Alloy |
| Ceph mon logs | DEBUG audit lines | Dropped in Alloy (PR #5846); Envoy access logs were turned off too |
| sabnzbd | A third of all pool writes on download days (up to 113 GB a day) | Left on Ceph on purpose, see below |
| SSD firmware | No TRIM ever reached the OSD disks | BlueStore discard on, see below |

The first rule of the pass: the log cuts change Loki's input, not the disk writes of the apps, so measure the writer you changed.

## Tried and rejected

- **Ceph audit log level on a mon:** `mon_cluster_log_level=info` cut the logged lines by 55 % but not the paxos commit rate (1.26 a second), so audit entries do not drive the commits. The trigger is still unknown.
- **sabnzbd incomplete folder on the QNAP:** benchmarked on mc3 with direct I/O, writes top out near 17 MB/s against download peaks of 60 MB/s. Buffered runs were OOM-killed at 512Mi and 2Gi because the page cache fills faster than the share drains. An `emptyDir` on the node NVMe is untried and would pin the pod to a node.
- **Prometheus and Loki on local NVMe volumes:** the data would be tied to one node and the pods could not move.
- **Raising the Rook exporter and mgr scrape interval to 60 s:** Rook also moves the mgr module's `mgr/prometheus/scrape_interval` to 60, which produced partial scrapes and zero pool counters (a false `rate()` spike of 5,797 MB/s). Reverted.
- **Prometheus `--storage.tsdb.max-block-duration=18h`:** hidden flag, a restart and about 40 blocks to query, for at most about 1 % of the pool.

## BlueStore discard on the OSD disks

On Ceph 20 `bdev_async_discard = true` is a deprecated alias for `bdev_async_discard_threads = 1` and does nothing on its own. The master switch is `bdev_enable_discard`, default false. Both are set in `cluster/apps/core/rook-ceph/cluster/values.yaml` and can be changed at runtime with `ceph tell osd.N config set`, no restart.
A value from `ceph.conf` beats the central config DB, so use `ceph tell`, not `ceph config set`. Rook only rewrites the ConfigMap; the OSDs read it at their next start.

The cost, accepted by the owner on 2026-10-29: Ceph write latency about 25 to 35 % higher (about 6 to 8 ms), `sda` busy 5.5 % against 3 %. Revert per OSD with `bdev_enable_discard false` and `bdev_async_discard_threads 0`, and remove both lines from the file.
The two-week wear comparison against the 2026-10-29 baseline is due 2026-11-12; add its result here.

## Gotchas met on the way

- **ArgoCD cannot remove a field held by its own `Update` manager when the app has `ApplyOutOfSyncOnly=true`.** The app shows Synced while the live object keeps the field. Remove it with `kubectl patch ... --type json` and keep the file in git consistent. See the `dev-workflow` skill.
- **Rook resets Ceph settings it owns** (the mgr scrape interval), so a revert in values may need a matching `ceph config set`.
- **Talos `FilesystemTrimConfig` and `FilesystemScrubConfig` only reach mounted XFS volumes on the NVMe**, never the raw OSD disks.
