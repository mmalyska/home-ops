# WoW WotLK AzerothCore — Single Player

AzerothCore 3.3.5a private server with mods:
- **mod-solocraft** — dungeon difficulty scaling for solo play
- **mod-ah-bot** — auction house bot (buyer + seller)
- **mod-individual-progression** — per-player progression stages

## Client Setup

1. WoW version required: **3.3.5a (build 12340)**
2. Edit `Data/enUS/realmlist.wtf`:
   ```
   set realmlist wow.mmalyska.cloud
   ```
   Or use `192.168.48.29` directly.
3. External access: connect to home router VPN first, then launch WoW.

## First-Time Setup (after ArgoCD sync)

After the first sync, the db-import PostSync job runs automatically. Once it completes, worldserver and authserver will be healthy. Then run these steps:

**1. Fix realmlist entry** (so clients connect to the correct IP):
```bash
kubectl exec -n wow statefulset/mysql -- mysql -u root -p$MYSQL_ROOT_PASSWORD acore_auth \
  -e "UPDATE realmlist SET address='192.168.48.29' WHERE id=1;"
```

**2. Create admin account** (via worldserver console):
```bash
kubectl attach -it -n wow deploy/wow-worldserver -c worldserver
# At the AC> prompt:
.account create admin <password>
.account set gmlevel admin 3 -1
# Detach: Ctrl+P Ctrl+Q
```

**3. Set up AHBot** (requires an in-game character):
1. Create the ahbot account: `account create ahbot ahbot`
2. Log in as `ahbot`, create a character named `Auctioneer`, enter the world once, then log out.
3. Get the character GUID:
   ```bash
   kubectl exec -n wow statefulset/mysql -- mysql -u root -p$MYSQL_ROOT_PASSWORD \
     -e "SELECT guid FROM acore_characters.characters WHERE name='Auctioneer';"
   ```
4. Edit `mod_ahbot.conf` (inside worldserver pod at `/azerothcore/env/dist/etc/modules/`):
   ```
   AuctionHouseBot.Account = <account_id>
   AuctionHouseBot.Guid = <character_guid>
   ```
5. Restart worldserver: `kubectl rollout restart -n wow deploy/wow-worldserver`

## Day-to-Day Operations

| Task | Command |
|------|---------|
| Stop worldserver | `kubectl scale -n wow deploy/wow-worldserver --replicas=0` |
| Start worldserver | `kubectl scale -n wow deploy/wow-worldserver --replicas=1` |
| Worldserver console | `kubectl attach -it -n wow deploy/wow-worldserver -c worldserver` (detach: Ctrl+P Ctrl+Q) |
| DB admin UI | `https://wow-adminer.mmalyska.cloud` (internal network only) |
| View worldserver logs | `kubectl logs -n wow deploy/wow-worldserver -f` |
| View worldserver errors | `kubectl exec -n wow deploy/wow-worldserver -c worldserver -- cat /azerothcore/env/dist/logs/Errors.log` |

For help interpreting errors, see the [AzerothCore Common Errors wiki](https://www.azerothcore.org/wiki/common-errors).

### Account Management via SOAP

SOAP is enabled on port 7878. Use `ADMIN:password` credentials (username must match what was set via the console).

```bash
# Helper function — put in ~/.bashrc  (set WOW_ADMIN_PASS before using)
wow-cmd() {
  curl -s -u "ADMIN:${WOW_ADMIN_PASS}" \
    -H 'Content-Type: text/xml; charset=utf-8' \
    -H 'SOAPAction: "urn:AC#executeCommand"' \
    -d "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP-ENV:Envelope xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:ns1=\"urn:AC\"><SOAP-ENV:Body><ns1:executeCommand><command>$1</command></ns1:executeCommand></SOAP-ENV:Body></SOAP-ENV:Envelope>" \
    http://192.168.48.29:7878/ | grep -oP '(?<=<result>).*(?=</result>)' | sed 's/&#xD;//g'
}

# Usage examples
wow-cmd ".server info"
wow-cmd ".account create myplayer mypassword"
wow-cmd ".account set gmlevel myplayer 3 -1"
wow-cmd ".account list"

# AHBot runtime toggle (no restart needed)
wow-cmd ".ahbotoptions buyer 1"   # enable buyer
wow-cmd ".ahbotoptions buyer 0"   # disable buyer (saves ~500m CPU when idle)
wow-cmd ".ahbotoptions seller 1"  # enable seller
wow-cmd ".ahbotoptions seller 0"  # disable seller
```

## Module Configuration

Config files are at `/azerothcore/env/dist/etc/modules/` inside the worldserver pod. Edit then restart.

- **mod-solocraft** (`mod_solocraft.conf`) — `SoloCraft.Enable`, difficulty multipliers per dungeon size
- **mod-ah-bot** (`mod_ahbot.conf`) — enable buyer/seller, item quotas by rarity, AHBot account/GUID
- **mod-individual-progression** (`mod_individual_progression.conf`) — progression stage settings

After editing configs, restart: `kubectl rollout restart -n wow deploy/wow-worldserver`

## Updates

1. Update the Dockerfile in `mmalyska/containers` (bump module clone SHAs or base image tag)
2. Rebuild images — CI publishes new digests to `ghcr.io/mmalyska/`
3. Update `tag:` + `sha256:` in `values.yaml` for the affected image(s)
4. Commit + merge → ArgoCD syncs automatically

## Backup

Volsync backs up the MySQL PVC (`wow-mysql`) every 12h to Restic (S3).

```bash
# Check backup status
kubectl get replicationsource -n wow

# Trigger immediate backup
kubectl annotate replicationsource -n wow wow-mysql volsync.backube/trigger-immediate=true
```

## Disaster Recovery

**Full rebuild:**
1. Bitwarden secrets already exist — ExternalSecret restores `wow-mysql-secret` and `wow-restic-secret` automatically
2. Sync ArgoCD app — MySQL PVC is new/empty, worldserver client-data re-downloads on pod start
3. Restore MySQL from Restic:
   ```yaml
   apiVersion: volsync.backube/v1alpha1
   kind: ReplicationDestination
   metadata:
     name: wow-mysql-restore
     namespace: wow
   spec:
     trigger:
       manual: restore-once
     restic:
       copyMethod: Snapshot
       destinationPVC: wow-mysql
       repository: wow-restic-secret
       accessModes: [ReadWriteOnce]
       storageClassName: ceph-block
       capacity: 10Gi
   ```
4. Once restore completes, delete the `ReplicationDestination` and sync ArgoCD to start services.
