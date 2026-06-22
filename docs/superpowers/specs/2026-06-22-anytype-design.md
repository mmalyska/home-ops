# Anytype Self-Hosting Design

**Date:** 2026-06-22  
**Status:** Approved

## Goal

Deploy a self-hosted Anytype sync network (`any-sync`) on the home-ops Kubernetes cluster, accessible from anywhere via Cloudflare WARP private network routing.

## Context & Decisions

- **Access model:** Cloudflare WARP + private network route — supports arbitrary L4 TCP/UDP so QUIC works fine. No public HTTP ingress needed.
- **File storage:** QNAP QuObjects (S3-compatible). File blobs go to QNAP; only document/page object data is stored on-cluster.
- **Sync nodes:** 1× any-sync-node (sufficient for personal use per upstream docs).
- **Config approach:** Manual one-time config generation via `any-sync-network` tool; secrets stored in Bitwarden Secrets Manager and pulled via ExternalSecret (matches existing cluster pattern).
- **MongoDB:** Dedicated StatefulSet in the `anytype` namespace (single-node replica set mode, required by any-sync even for one instance).
- **Redis:** Dedicated `redis-stack-server` Deployment — standard Redis is not sufficient; Anytype requires the Bloom Filter module only available in `redis/redis-stack-server`.

## Architecture

```
Namespace: anytype
│
├── MongoDB StatefulSet          (single-node, replica set rs0)
│   └── PVC: ceph-block, 5Gi
│
├── redis-stack-server Deployment
│   └── PVC: ceph-block, 1Gi
│
├── any-sync-coordinator Deployment
│   └── Config: Secret → /etc/any-sync-coordinator/
│
├── any-sync-consensusnode Deployment
│   └── Config: Secret → /etc/any-sync-consensusnode/
│
├── any-sync-node Deployment
│   ├── Config: Secret → /etc/any-sync-node/
│   └── PVC: ceph-block, 10Gi  (/storage, /anyStorage, /networkStore)
│
├── any-sync-filenode Deployment
│   ├── Config: Secret → /etc/any-sync-filenode/
│   ├── AWS creds: Secret → /root/.aws/credentials
│   └── PVC: ceph-block, 2Gi  (/networkStore only; blobs go to QNAP S3)
│
└── LoadBalancer Services @ 192.168.48.29  (Cilium L2, lbipam annotation)
    ├── TCP 1001 / UDP 1011  → any-sync-node
    ├── TCP 1004 / UDP 1014  → any-sync-coordinator
    ├── TCP 1005 / UDP 1015  → any-sync-filenode
    └── TCP 1006 / UDP 1016  → any-sync-consensusnode
```

**Storage split:**
- Pages / document objects → any-sync-node → 10Gi ceph-block PVC
- Uploaded files / blobs → any-sync-filenode → QNAP QuObjects (S3); capacity limited by NAS provisioning, not cluster PVC

## Repository Structure

```
charts/anytype/                  # custom Helm chart
  Chart.yaml
  templates/
    mongodb/                     # StatefulSet, Service, replica-set init
    redis/                       # Deployment, Service
    coordinator/                 # Deployment, LoadBalancer Service
    consensusnode/               # Deployment, LoadBalancer Service
    syncnode/                    # Deployment, LoadBalancer Service
    filenode/                    # Deployment, LoadBalancer Service

cluster/apps/default/anytype/    # ArgoCD ApplicationSet entry
  app-config.yaml
  Chart.yaml                     # references charts/anytype as dependency
  values.yaml
  templates/
    externalsecrets.yaml         # one ExternalSecret per Bitwarden key
```

## Config Generation (One-Time Bootstrap)

Run locally before first deployment:

```bash
go install github.com/anyproto/any-sync-tools/any-sync-network@latest
any-sync-network create
# When prompted for external host, enter 192.168.48.29 for all services
# Ports to enter per service:
#   coordinator:    TCP 1004, QUIC 1014
#   consensusnode:  TCP 1006, QUIC 1016
#   syncnode:       TCP 1001, QUIC 1011
#   filenode:       TCP 1005, QUIC 1015
```

Augment the generated files with runtime connection strings (MongoDB URI inside `coordinator.yml` and `consensus.yml`; Redis URL and S3 endpoint/bucket inside `file_1.yml`), then upload to Bitwarden:

| BWS Key | Contents |
|---|---|
| `anytype-coordinator-config` | `coordinator.yml` (includes MongoDB URI) |
| `anytype-network-config` | `network.yml` (needed by coordinator bootstrap `confapply`) |
| `anytype-consensus-config` | `consensus.yml` (includes MongoDB URI) |
| `anytype-syncnode-config` | `sync_1.yml` |
| `anytype-filenode-config` | `file_1.yml` (includes Redis URL + S3 endpoint/bucket) |
| `anytype-aws-credentials` | `[default]\naws_access_key_id=...\naws_secret_access_key=...` |

`heart.yml` (client network config) is kept locally and pasted into the Anytype app under Settings → Network → Self-hosted.

## Secrets Management

Uses the existing `ClusterSecretStore: bitwarden` pattern. One `ExternalSecret` resource per config file, each creating a K8s Secret that is volume-mounted into the corresponding pod as a file.

## Networking

- **Internal (cluster):** MongoDB and Redis are ClusterIP only.
- **External:** Single LB IP `192.168.48.29` announced via Cilium L2.
- **Remote access:** Add `192.168.48.29/32` as a private network route in Cloudflare Zero Trust → Tunnels → Private Networks (reuse existing `cloudflared` tunnel). Devices with WARP enrolled route traffic through Cloudflare's L4 tunnel — TCP and QUIC/UDP both work.
- **No HTTP ingress:** any-sync is not HTTP; nothing routes through Envoy Gateway.

## Startup Order

Enforced via `initContainers` waiting on TCP health checks:

```
MongoDB healthy
  → any-sync-coordinator starts
      → any-sync-consensusnode starts
      → any-sync-node starts
      → any-sync-filenode starts (also waits for Redis + QNAP S3)
```

## Storage

| Component | Path(s) | PVC Size | Storage Class |
|---|---|---|---|
| MongoDB | `/data/db` | 5Gi | ceph-block |
| Redis | `/data` | 1Gi | ceph-block |
| any-sync-node | `/storage`, `/anyStorage`, `/networkStore` | 10Gi | ceph-block |
| any-sync-filenode | `/networkStore` | 2Gi | ceph-block |
| any-sync-coordinator | `/networkStore` | 1Gi | ceph-block |
| any-sync-consensusnode | `/networkStore` | 1Gi | ceph-block |

## Docker Images

| Service | Image |
|---|---|
| MongoDB | `mongo:7.0` |
| Redis | `redis/redis-stack-server:7.2.0-v6` |
| any-sync-coordinator | `ghcr.io/anyproto/any-sync-coordinator:v0.9.1` |
| any-sync-consensusnode | `ghcr.io/anyproto/any-sync-consensusnode:v0.7.2` |
| any-sync-node | `ghcr.io/anyproto/any-sync-node:v0.11.1` |
| any-sync-filenode | `ghcr.io/anyproto/any-sync-filenode:v0.11.1` |

All image tags to be pinned with SHA digests and managed by Renovate.

## Open Questions

- Exact QNAP QuObjects bucket name and endpoint URL (needed when augmenting `file_1.yml`).
- Whether `192.168.48.29` is free — verify against current cluster LB assignments before deploying.
- `ANY_SYNC_FILENODE_DEFAULT_LIMIT` — set based on available QNAP capacity.
