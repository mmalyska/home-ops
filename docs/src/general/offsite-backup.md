# Offsite backup of the QNAP

Status: **proposed** (2026-11-24). The owner has not picked a provider yet. This page holds the comparison and the
plan, so the choice can be made and checked before the family's photos are imported into Nextcloud. Nothing here
changes the cluster: the copy is set up on the QNAP.

## Why

- The QNAP TS-251D holds the **only copy** of the family's files (Nextcloud data on an NFS export) and the media
  library. Phones keep their originals until the user frees space, so tell the family not to use "free up space" until
  the first offsite copy has finished (see [Nextcloud](../k8s/nextcloud.md)).
- It also hosts the S3 target for the cluster backups (VolSync restic repositories and CNPG backups, the `s3` traffic
  in the audits). Losing the QNAP loses the family's files and the cluster's backups together. The live data of the
  apps is on Ceph and survives.
- The QNAP has two pools, a 500 GB system pool and a 4 TB data pool, both RAID 1. RAID 1 covers one failed disk and
  nothing else: not deletion, ransomware, a controller or firmware fault, theft or a fire.

## What to copy

Measured on 2026-11-23 from the QNAP metrics in Prometheus (`node_volume_size_bytes`, `node_volume_avail_bytes`):

| Volume      | Size    | Used   |
| ----------- | ------- | ------ |
| OneDrive    | 1029 GB | 405 GB |
| Media       | 531 GB  | 171 GB |
| K8S         | 260 GB  | 66 GB  |
| Multimedia  | 158 GB  | 97 GB  |
| DataVol1    | 150 GB  | 46 GB  |
| Backups     | 99 GB   | 54 GB  |
| **Total**   | 2227 GB | 836 GB |

The family's library (about 400 GB, plus 10-20 % previews, versions and trash) is not imported yet, so it comes on top:
about **1.3 TB** soon. The owner's rule is "the more the better", so the plan is to copy everything, including the
replaceable `Media` volume (about 171 GB, roughly $1 a month more). Size the budget for **1.5-2 TB**.

Link speed (owner, 2026-11-24): 1 Gbit/s down, 300 Mbit/s up. The first upload of about 1.3 TB takes about 10 hours at
full speed, so plan for one or two days. A full restore at 1 Gbit/s takes about 3 hours at full speed (the provider is
usually the limit).

## Options

Prices as published on 2026-11-23, excluding tax; check them again before buying. The monthly cost at the sizes above:

| Option                                | 1.5 TB / month        | 2 TB / month          | Egress for a restore                  | Catches                                                                                                  |
| ------------------------------------- | --------------------- | --------------------- | ------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Backblaze B2 ($6.95/TB)               | $10.4 (about $125/yr) | $13.9 (about $167/yr) | free up to 3x the stored data         | API calls A, B and C free; no minimum duration; the EU region is chosen **when the account is created** |
| Wasabi ($7.99/TB)                     | $12.0 (about $144/yr) | $16.0 (about $192/yr) | free while monthly egress is at most the stored data | 1 TB minimum charge; **90-day minimum retention** (early deletes are billed for the rest); EU regions: Amsterdam, Frankfurt, Paris, Milan, UK |
| Hetzner Storage Box BX21 (5 TB, flat) | EUR 10.90 flat        | EUR 10.90 flat        | unlimited traffic                     | not S3: rsync, SFTP, SMB, WebDAV; support in QNAP Hybrid Backup Sync is **not confirmed**                |
| Hetzner Object Storage                | EUR 8.9-10.8          | EUR 11.4-15.2         | 1 TB included, about EUR 1 per TB after | S3-compatible, API calls free; the price of extra storage differs between sources                        |
| Cloudflare R2 ($15/TB)                | $22.5                 | $30                   | free                                  | the most expensive                                                                                       |
| AWS S3 Glacier Deep Archive           | about $1.5-2 (US price) | about $2 (US price) | 12-48 h plus retrieval and egress fees | 180-day minimum; poor fit for a versioned sync; not recommended                                          |
| A relative's NAS or mini PC           | one-off hardware      | one-off hardware      | free                                  | needs a VPN and someone to look after it                                                                 |
| Rotated external disks                | one-off, 2 disks      | one-off, 2 disks      | free                                  | only as fresh as the last rotation                                                                       |

The Hetzner Storage Box BX11 (1 TB, EUR 3.20) no longer fits the size.

## QNAP side

- **Hybrid Backup Sync (HBS 3)** lists Backblaze B2, Wasabi and Amazon S3 among its clouds, and rsync, WebDAV, CIFS/SMB,
  FTP and RTRR for remote servers. **QuDedup** (block-level deduplication and encryption at the source) needs an x86
  NAS; the TS-251D is x86. It is not confirmed which provider and protocol combinations can use QuDedup and its
  encryption, so test it.
- **Snapshots** need a thick or thin volume in a storage pool; a static volume does not support them. The volumes show
  as EXT4 in the metrics, but thick and thin volumes use EXT4 too, so the file system says nothing. Check the volume
  type in Storage & Snapshots.
- A QNAP that is hit by ransomware can usually also write to the remote copy with the credentials HBS holds. Keep
  versions on the provider side and give the HBS key as few rights as the provider allows. Whether B2 can stop deletes
  with that key (for example Object Lock) was not checked.

## Recommendation

1. **Backblaze B2 in the EU Central region (Amsterdam), through HBS with client-side encryption and versioning.** About
   $10-14 a month for 1.5-2 TB. It is a first-class HBS target, has no minimum duration, and a restore is free up to 3x
   the stored data. The region is set per account when it is created and cannot be changed, so create the account in
   the EU region. Backblaze is a US company, so the region does not change the legal jurisdiction; the client-side
   encryption is what keeps the photos private.
2. **Optional second copy** on a Hetzner Storage Box BX21 (EUR 10.90 flat, 5 TB, unlimited traffic), which suits "the
   more the better". Trial a BX11 first (EUR 3.20, no contract, cancellation is immediate) to test HBS over rsync or
   WebDAV and its encryption.
3. Add QNAP snapshots on the data shares once the volume type allows them, and keep the existing restic and CNPG
   backups in the QNAP S3 as they are (they would be among the data copied offsite).

## Before the first import

- [ ] Check the volume type and turn on snapshots on the Nextcloud share.
- [ ] Create the B2 account in the EU Central region, a bucket, and an application key limited to that bucket.
- [ ] Create the HBS job with client-side encryption, versioning and a schedule; keep the encryption password in the
      password manager and **store it outside the QNAP**. Without it the copy cannot be restored.
- [ ] Run the first upload, then restore a small folder and a large file to another place and compare them.
- [ ] Only then tell the family that "free up space" on the phones is safe.
- [ ] Optional: trial the Hetzner Storage Box.
- [ ] Add an alert or a monthly reminder that the last HBS job succeeded (the QNAP exporter in Prometheus does not
      report HBS jobs).

## Sources

[Backblaze B2 pricing](https://www.backblaze.com/cloud-storage/pricing),
[B2 transaction pricing](https://www.backblaze.com/cloud-storage/transaction-pricing),
[B2 EU region FAQ](https://help.backblaze.com/hc/en-us/articles/360034360834-EU-Region-FAQ),
[B2 data regions](https://www.backblaze.com/docs/cloud-storage-data-regions),
[Wasabi pricing FAQ](https://wasabi.com/pricing/faq),
[Wasabi storage regions](https://wasabi.com/company/storage-regions),
[Hetzner Storage Box](https://www.hetzner.com/storage-box),
[Hetzner Object Storage](https://www.hetzner.com/storage/object-storage/overview/),
[Cloudflare R2 pricing](https://developers.cloudflare.com/r2/pricing),
[AWS S3 pricing](https://aws.amazon.com/s3/pricing/),
[QNAP Hybrid Backup Sync](https://www.qnap.com/solution/hbs3),
[QNAP QuDedup](https://www.qnap.com/en/solution/hbs-qudedup),
[QNAP thick, thin and static volumes](https://docs.qnap.com/operating-system/qts/5.1.x/en-us/thick-thin-and-static-volumes-18CF56F8.html).
