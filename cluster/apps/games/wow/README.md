# WoW WotLK AzerothCore — Single Player

AzerothCore 3.3.5a private server with mods:
- **mod-solocraft** — dungeon/raid difficulty scaling for solo play
- **mod-ah-bot** — auction house bot (buyer + seller)
- **mod-transmog** — transmogrification: change item appearance at the Transmogrifier NPC
- **mod-solo-lfg** — allows queuing into group dungeons alone via the LFG dungeon finder

> **Bots (planned)**: npc-bots via `trickerer/AzerothCore-wotlk-with-NPCBots` will be added in a future update. Requires switching the worldserver build base to that pre-patched AC fork.

## Client Setup

1. WoW version required: **3.3.5a (build 12340)**
2. Edit `Data/enUS/realmlist.wtf`:
   ```
   set realmlist wow.<private-domain>
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
3. Get the account ID and character GUID:
   ```bash
   kubectl exec -n wow statefulset/mysql -- mysql -u root -p$MYSQL_ROOT_PASSWORD \
     -e "SELECT id FROM acore_auth.account WHERE username='ahbot';"
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
| DB admin UI | `https://wow-adminer.<private-domain>` (internal network only) |
| View worldserver logs | `kubectl logs -n wow deploy/wow-worldserver -f` |
| View worldserver errors | `kubectl exec -n wow deploy/wow-worldserver -c worldserver -- cat /azerothcore/env/dist/logs/Errors.log` |

For help interpreting errors, see the [AzerothCore Common Errors wiki](https://www.azerothcore.org/wiki/common-errors).

### Account Management via SOAP

SOAP is enabled on port 7878. Use `admin:password` credentials (username must match what was set via the console).

```bash
# Helper function — put in ~/.bashrc  (set WOW_ADMIN_PASS before using)
wow-cmd() {
  curl -s -u "admin:${WOW_ADMIN_PASS}" \
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
- **mod-transmog** (`mod_transmog.conf`) — `Transmogrification.Enable`, cost settings; Transmogrifier NPC must be manually spawned (see below)
- **mod-solo-lfg** (`SoloLfg.conf`) — `SoloLFG.Enable`; no other config needed

After editing configs, restart: `kubectl rollout restart -n wow deploy/wow-worldserver`

### Spawning the Transmogrifier NPC (mod-transmog)

The module provides NPC templates (`Warpweaver` entry 190010, `Ethereal Warpweaver` entry 190011) but does not auto-spawn them. Spawn once after the first deploy:

1. Connect in-game as a GM account.
2. Navigate to where you want the NPC (e.g. Orgrimmar or Stormwind).
3. In the worldserver console or via SOAP, run:
   ```
   .npc add 190010
   ```
4. The NPC is now spawned at your character's location and persists across restarts.

To spawn in both cities, teleport to each and repeat. To find or move an existing spawn:
```
.npc near          # list nearby NPCs with GUIDs
.npc move <guid>   # move NPC to your current position
```

## Updates

1. Update the Dockerfile in `mmalyska/containers` (bump module clone SHAs or base image tag)
2. Rebuild images — CI publishes new digests to `ghcr.io/mmalyska/`
3. Update `tag:` + `sha256:` in `values.yaml` for the affected image(s)
4. Commit + merge → ArgoCD syncs automatically

## Backup

A CronJob (`mysql-backup`) runs every 12h (`0 */12 * * *`) in the `wow` namespace:
1. An init container (`mysql:8.4`) dumps all three databases (`acore_auth`, `acore_characters`, `acore_world`) via `mysqldump --single-transaction` into a shared `emptyDir`
2. The main container (`restic/restic:0.18.1`) uploads that directory to the shared S3 Restic repo at `$REPOSITORY_TEMPLATE/wow-mysql`

Credentials come from `wow-restic-secret` (ExternalSecret backed by Bitwarden). Retention: 6 daily, 4 weekly, 2 monthly snapshots.

```bash
# Check backup job history
kubectl get jobs -n wow

# Check logs of the most recent backup
kubectl logs -n wow -l job-name=mysql-backup --tail=50
```

## Disaster Recovery

**Full rebuild:**
1. Bitwarden secrets already exist — ExternalSecret restores `wow-mysql-secret` and `wow-restic-secret` automatically
2. Sync ArgoCD app — MySQL StatefulSet starts with empty PVC; worldserver client-data re-downloads on pod start
3. Restore MySQL from Restic:

```bash
# List available snapshots
kubectl run restic-restore -n wow --rm -it --image=restic/restic:0.18.1 \
  --env-from=secret/wow-restic-secret -- snapshots

# Restore dump files from a snapshot to /tmp/restore
kubectl run restic-restore -n wow --rm -it --image=restic/restic:0.18.1 \
  --env-from=secret/wow-restic-secret \
  -- restore <snapshot-id> --target /tmp/restore

# Import each database (run inside mysql-0 pod, after copying files in)
kubectl exec -n wow mysql-0 -- sh -c \
  'gunzip -c /tmp/acore_auth.sql.gz | mysql -u root -p"$MYSQL_ROOT_PASSWORD" acore_auth'
kubectl exec -n wow mysql-0 -- sh -c \
  'gunzip -c /tmp/acore_characters.sql.gz | mysql -u root -p"$MYSQL_ROOT_PASSWORD" acore_characters'
kubectl exec -n wow mysql-0 -- sh -c \
  'gunzip -c /tmp/acore_world.sql.gz | mysql -u root -p"$MYSQL_ROOT_PASSWORD" acore_world'
```

Each database is a separate `.sql.gz` file and can be restored independently.
