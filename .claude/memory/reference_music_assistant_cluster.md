---
name: Music Assistant in the cluster
description: MA runs on a VLAN 48 macvlan (192.168.48.62); base_url vs bind_port gotchas and the NFS library choice
metadata:
  type: reference
---

Music Assistant (cluster/apps/home-automation/music-assistant) runs in the cluster since 2026-10-03 on Multus macvlan `net1` 192.168.48.62 (own LAN IP for mDNS/Cast/AirPlay and the 8097 stream server). Library = QNAP `/music` mounted by Kubernetes at `/media/music` (Local filesystem provider), not MA's in-container NFS provider (needs SYS_ADMIN).

**Why:** MA discovers/streams to players with mDNS and random ports; a pod IP is unreachable for players, and upstream documents host networking as mandatory.

**How to apply:**
- Set the web server **base_url** to the public https URL (auto = pod IP breaks the Home Assistant OAuth callback). Never set the web server **bind_port**: Service/route target 8095, so the UI dies.
- Stream server `bind_ip` must be 192.168.48.62, otherwise players get the pod IP.
- The HA provider needs the HA URL plus a long-lived token entered in the MA UI (not in git). It was restored from the RPi still pointing at `http://192.168.50.9:8123` and logged ~7000 connect errors/day until it was repointed on 2026-10-13 (to the public https route; the in-cluster Service `home-assistant-main.ha-home-assistant.svc.cluster.local:8123` also works).
- **Never edit `/data/settings.json` while MA runs.** Provider `setup_data.url` and `token` are Fernet-encrypted with `encryption_key` from the same file, and MA rewrites the whole file from memory on shutdown, silently reverting the edit (a pod delete does this too). Change provider settings in the UI. A file edit only works with the deployment at 0 replicas, which `selfHeal` may revert.
- To read a stored value without printing secrets: `python3 -c` inside the pod, decrypt `setup_data.url` only.
- Details: docs/src/general/network.md (Music Assistant section).
