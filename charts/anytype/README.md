# anytype

Self-hosted [Anytype](https://anytype.io) sync network (`any-sync`) running on Kubernetes.

## Architecture

Four any-sync services share a single LoadBalancer IP (`192.168.48.30`) on separate ports:

| Service | TCP port | QUIC/UDP port |
|---|---|---|
| any-sync-coordinator | 1004 | 1014 |
| any-sync-consensusnode | 1006 | 1016 |
| any-sync-node | 1001 | 1011 |
| any-sync-filenode | 1005 | 1015 |

Dependencies: MongoDB 7 (replica set), Redis Stack (Bloom Filter module), QNAP QuObjects (S3-compatible file storage).

## First-time setup

### 1. Generate network configs

Clone the any-sync-tools repo and generate configs from the tool's directory (it needs `defaultTemplate.yml` present):

```bash
git clone https://github.com/anyproto/any-sync-tools.git /tmp/any-sync-tools
cd /tmp/any-sync-tools/any-sync-network
go run . create
```

When prompted:
- External host for all services: `192.168.48.30`
- Coordinator TCP/QUIC: `1004` / `1014`
- Consensus TCP/QUIC: `1006` / `1016`
- Sync node TCP/QUIC: `1001` / `1011`
- File node TCP/QUIC: `1005` / `1015`

Output lands in `./etc/`:

```
any-sync-coordinator/config.yml   any-sync-coordinator/network.yml
any-sync-consensusnode/config.yml
any-sync-node-1/config.yml
any-sync-filenode/config.yml
client.yml
```

### 2. Patch the generated configs

The tool assigns coordinator and consensusnode to the same port by default (single-host assumption). Fix the coordinator to 1004/1014 and apply K8s service URIs using this script:

```bash
python3 -m venv /tmp/venv && /tmp/venv/bin/pip install pyyaml -q

/tmp/venv/bin/python3 << 'EOF'
ETC = "./etc"  # adjust if running from a different directory
COORD_PEER = "<coordinator-peerId-from-config>"  # fill in from any-sync-coordinator/config.yml
MONGO_URI  = "mongodb://mongo-1.anytype.svc.cluster.local:27001/?replicaSet=rs0"

def fix_coord_addrs(addrs):
    return [a.replace("192.168.48.30:1006","192.168.48.30:1004")
             .replace("quic://192.168.48.30:1016","quic://192.168.48.30:1014")
            for a in addrs]

def patch_nodes(nodes):
    for n in nodes:
        if COORD_PEER in n.get("peerId",""):
            n["addresses"] = fix_coord_addrs(n["addresses"])
    return nodes

import yaml

def load(p):
    with open(p) as f: return yaml.safe_load(f)
def save(p, d):
    with open(p,"w") as f: yaml.dump(d, f, default_flow_style=False, allow_unicode=True)

p = f"{ETC}/any-sync-coordinator/config.yml"
d = load(p)
d["yamux"]["listenAddrs"] = ["0.0.0.0:1004"]  # pod binds 0.0.0.0; LB IP is in network.nodes
d["quic"]["listenAddrs"]  = ["0.0.0.0:1014"]
d["mongo"]["connect"]     = MONGO_URI
d["network"]["nodes"]     = patch_nodes(d["network"]["nodes"])
save(p, d)

for name in ["any-sync-coordinator/network.yml"]:
    p = f"{ETC}/{name}"; d = load(p); d["nodes"] = patch_nodes(d["nodes"]); save(p, d)

for name in ["any-sync-consensusnode/config.yml"]:
    p = f"{ETC}/{name}"; d = load(p)
    d["yamux"]["listenAddrs"] = ["0.0.0.0:1006"]
    d["quic"]["listenAddrs"]  = ["0.0.0.0:1016"]
    d["mongo"]["connect"] = MONGO_URI
    d["network"]["nodes"] = patch_nodes(d["network"]["nodes"])
    save(p, d)

for name in ["any-sync-node-1/config.yml"]:
    p = f"{ETC}/{name}"; d = load(p)
    d["yamux"]["listenAddrs"] = ["0.0.0.0:1001"]
    d["quic"]["listenAddrs"]  = ["0.0.0.0:1011"]
    d["network"]["nodes"] = patch_nodes(d["network"]["nodes"])
    save(p, d)

for name in ["any-sync-filenode/config.yml"]:
    p = f"{ETC}/{name}"; d = load(p)
    d["yamux"]["listenAddrs"] = ["0.0.0.0:1005"]
    d["quic"]["listenAddrs"]  = ["0.0.0.0:1015"]
    d["network"]["nodes"] = patch_nodes(d["network"]["nodes"])
    save(p, d)

for name in ["client.yml"]:
    p = f"{ETC}/{name}"; d = load(p); d["nodes"] = patch_nodes(d["nodes"]); save(p, d)

# filenode: fix Redis and S3
p = f"{ETC}/any-sync-filenode/config.yml"; d = load(p)
d["redis"]["isCluster"] = False
d["redis"]["url"]       = "redis://redis.anytype.svc.cluster.local:6379"
d["s3Store"]["endpoint"]    = "https://s3.<private-domain>"   # QNAP QuObjects endpoint
d["s3Store"]["bucket"]      = "anytype"
d["s3Store"]["indexBucket"] = "anytype"
save(p, d)
print("done")
EOF
```

### 3. Create Bitwarden secrets

In Bitwarden Secrets Manager, create one secret per file (store the **full file content** as the value):

| Secret name | File |
|---|---|
| `anytype-coordinator-config` | `etc/any-sync-coordinator/config.yml` |
| `anytype-network-config` | `etc/any-sync-coordinator/network.yml` |
| `anytype-consensus-config` | `etc/any-sync-consensusnode/config.yml` |
| `anytype-syncnode-config` | `etc/any-sync-node-1/config.yml` |
| `anytype-filenode-config` | `etc/any-sync-filenode/config.yml` |
| `anytype-aws-access-key-id` | QNAP QuObjects access key ID |
| `anytype-aws-secret-access-key` | QNAP QuObjects secret access key |

Also save `etc/client.yml` as `anytype-heart-config` for backup. Keep a local copy — you paste it into the Anytype desktop app.

### 4. Fill in UUIDs

Edit `cluster/apps/default/anytype/templates/externalsecrets.yaml` and replace each `REPLACE-WITH-UUID` with the Bitwarden secret UUID for the matching secret (UUID visible in Bitwarden SM after creation).

### 5. Pre-deploy checklist

- [ ] QNAP QuObjects bucket `anytype` created
- [ ] `192.168.48.30` is free (`ping 192.168.48.30` times out)
- [ ] Cloudflare WARP private network route `192.168.48.30/32` applied via Terraform (`provision/terraform/cloudflare/warp.tf`)
- [ ] All UUIDs filled in `externalsecrets.yaml`

### 6. Enable and deploy

```bash
# In cluster/apps/default/anytype/app-config.yaml
# Change:  enabled: "false"
# To:      enabled: "true"

git add cluster/apps/default/anytype/app-config.yaml
git commit -m "feat(anytype): enable Anytype deployment"
git push
# Open PR and merge → ArgoCD picks up the change
```

### 7. Verify

```bash
kubectl get pods -n anytype -w
# Expected startup order:
# 1. mongo-1-0 → Running (~60s for RS init)
# 2. any-sync-coordinator-* → Running
# 3. any-sync-consensusnode-*, any-sync-node-*, any-sync-filenode-* → Running

kubectl get externalsecrets -n anytype
# All five should show READY: True

kubectl get svc -n anytype
# All four LoadBalancer services show EXTERNAL-IP: 192.168.48.30
```

### 8. Connect the Anytype client

In the Anytype desktop or mobile app:

- Settings → Network → Self-hosted network
- Paste the full contents of `client.yml` (saved earlier)
- Save and restart the app

## Backup

VolSync restic backups run nightly via `cluster/apps/default/anytype/templates/volsync.yaml`:

| PVC | Schedule |
|---|---|
| `data-mongo-1-0` | 02:00 |
| `coordinator-networkstore` | 02:15 |
| `consensusnode-networkstore` | 02:30 |
| `syncnode-data` | 02:45 |
| `filenode-networkstore` | 03:00 |

Redis is excluded (reconstructed on restart). Backups go to `s3.<private-domain>` under the path defined by `VOLSYNC_RESTIC_REPOSITORY_TEMPLATE` + `/anytype`.

## Values

See `values.yaml` for all configurable options. Image tags are mirrored in
`cluster/apps/default/anytype/values.yaml` for Renovate to track.
