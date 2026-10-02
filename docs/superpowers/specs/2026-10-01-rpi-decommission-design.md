# RPi Decommission — Home Assistant Stack In-Cluster Design

**Date:** 2026-10-01
**Status:** Draft — awaiting review

## Goal

Decommission the Raspberry Pi (`192.168.50.9`, HAOS) and run everything it hosts in the cluster: Home Assistant, AdGuard Home (DNS + ad-blocking), MQTT, Zigbee2MQTT, the Matter server and Music Assistant. The Zigbee/Thread coordinator is already the network-attached SLZB-MR4U, so no radio hardware has to move.

## Context & Decisions

- **MQTT broker:** reuse the existing, currently disabled `cluster/apps/home-automation/rabbitmq` app (RabbitMQ + `rabbitmq_mqtt`, chosen over Mosquitto/VerneMQ in `2026-07-06-rabbitmq-operator-design.md`). It gains a `zigbee2mqtt` user.
- **DNS / ad-blocking:** two AdGuard Home instances in the cluster, both blocking, both handed out by DHCP. UniFi is **not** handed to clients as a secondary: clients do not reliably prefer the primary (systemd-resolved sticks, Windows/macOS/Android race or pick fastest), so a non-filtering secondary would leak ads and, if it lacked internal records, return NXDOMAIN for them. UniFi (UCG-Max `192.168.48.254`) is used only as an upstream for the local zone and reverse lookups, and as the resolver for Talos nodes.
- **Full-cluster outage:** accepted risk (user decision); no external last-resort DNS.
- **Home Assistant network:** HA and the Matter server each get a Multus macvlan interface (`net1`) on VLAN 48 with a static IP, instead of `hostNetwork`. UniFi's mDNS reflector (already enabled across VLANs) delivers Chromecast/Matter mDNS to that segment. VLAN 48 and 50 are in one allow-all firewall zone and VLAN 48 has IPv6 enabled.
- **Music Assistant (found later, not in the original inventory):** the RPi also runs the Music Assistant add-on. Its docs state that without host networking "player discovery and any players that need direct network access (AirPlay, Chromecast, DLNA, Sonos, and similar) will not work", and that port restrictions are unsupported. A plain bridge/pod network is therefore unsuitable; it gets its own macvlan interface (`net1`, `192.168.48.62`) on VLAN 48, which gives it a real LAN address with no port restrictions, the same as HA and the Matter server. Ports: 8095 (web/API) and 8097 (stream server). Its published/stream IP must be set to the `net1` address, otherwise players are handed the unreachable pod IP.
- **Known gap:** SSDP/UPnP, DHCP-broadcast discovery and MAC-based ARP presence do not cross VLANs. Only QNAP remains on VLAN 50 and UPnP is disabled in UniFi. Mitigation: UniFi integration for presence, IP-based setup (with DHCP reservations) for other devices; a tagged-VLAN macvlan is the fallback if something specific needs it.
- **Recorder history:** start fresh on the CNPG Postgres cluster already defined in the HA app. The RPi's SQLite file is not restored; keep it as an archive.
- **Sequencing:** phased, each phase leaving the RPi functional (see below). Every addon (MQTT, Z2M, Matter server, AdGuard) is migrated and tested against the RPi's still-running HA **before** HA itself moves, so the final cutover only moves HA.

## Findings that shape the design

- `provision/talos/templates/controlplane.yaml` sets `machine.network.nameservers` to `192.168.50.9` (RPi AdGuard). Must change to `192.168.48.254` before the RPi is retired or AdGuard moves in-cluster, otherwise nodes depend on their own DNS.
- `cluster/apps/default/hass-proxy` publishes `hass.<domain>` on **both** `envoy-external` and `envoy-internal` (backend: RPi); `agh-proxy` publishes `agh.<domain>` on `envoy-internal`. Cutover swaps backends; hostnames and external access are preserved.
- `cluster/apps/system/adguard-dns` is only external-dns (webhook provider) writing to the RPi's AdGuard via `ADGUARD_URL`; no AdGuard server exists in-cluster.
- Free Cilium LB IPs: `.24`, `.25`, `.26`, `.31–.50` (`.22` Jellyfin, `.23` Minecraft, `.27–.30` taken).
- Cilium has no `cni.exclusive` setting (default `true`), which removes other CNI configs; Multus requires `cni.exclusive: false`.
- `mc1`–`mc3` use NIC `eth0`; `nv1` uses `enP8p1s0`. macvlan attachments name the parent, so HA and Matter are pinned to `mc1`–`mc3`.
- The existing HA test app (`ha-home-assistant`, `enabled: "false"`) already has an app-template StatefulSet, code-server sidecar, CNPG recorder DB and an `envoy-internal` route at `dom.<domain>`.

## Phases

Each phase can be stopped after, and phases 0–2 can be reverted by pointing HA, Z2M or DNS back at the RPi. Phase 3 stays reversible until the hostname flips in phase 4.

### Phase 0 — MQTT broker

- Enable `home-automation/rabbitmq` (`ha-rabbitmq`); add a `zigbee2mqtt` user to the `rabbitmq-definitions` ExternalSecret (credentials from Bitwarden).
- Expose 1883 as `LoadBalancer` at `192.168.48.26`; publish `mqtt.<domain>` via external-dns. In-cluster consumers use the ClusterIP service.
- Any device that hardcodes the RPi's Mosquitto IP is repointed to `mqtt.<domain>`.
- **Done when:** an MQTT client on the RPi publishes and subscribes through `mqtt.<domain>`.

### Phase 1 — Zigbee2MQTT, Matter server and Music Assistant

- New app `home-automation/zigbee2mqtt`: app-template StatefulSet, image `koenkk/zigbee2mqtt`, Ceph PVC at `/app/data`, frontend at `z2m.<domain>` on `envoy-internal`.
- Config restored into the PVC from the RPi addon export: `configuration.yaml`, `database.db`, `coordinator_backup.json`. Same network key and PAN ID, so no device re-pairs. Nothing from these files is committed.
- Adapter: `serial.port: tcp://<slzb-ip>:6638` with the adapter type taken from the existing config; both verified in the SLZB UI.
- MQTT credentials via ExternalSecret → env (`ZIGBEE2MQTT_CONFIG_MQTT_*`). `base_topic` and `homeassistant: true` unchanged.
- Cutover within the phase: stop the RPi's Z2M **and** Mosquitto addons (exactly one Z2M may own the coordinator), repoint the RPi HA MQTT integration to `mqtt.<domain>`, start cluster Z2M. Z2M republishes discovery; entities keep their IDs.
- **Done when (Z2M):** all Zigbee devices are visible in the RPi's HA, a state-change round trip works, and the device survives a Z2M pod restart.
- **Matter server prerequisites:** Cilium `cni.exclusive: false`; deploy Multus; a macvlan NetworkAttachmentDefinition on `eth0` (VLAN 48) with static IPAM from a reserved block outside the `.20–.50` pool (`.60–.69`), plus a route so replies to LAN/VLAN 50 leave via `net1`. Matter is pinned to `mc1`–`mc3`.
- **Matter server:** `python-matter-server` is archived (8.1.2 was its last release); the RPi's addon (9.2.0) already runs the matter.js server, so the new app runs `ghcr.io/matter-js/matterjs-server` at the same version (1.4.0), a documented drop-in with the same `/data` layout and WebSocket API (data was auto-migrated by addon 9.0.0). It must be started with the addon's `--fabricid 2 --vendorid 4939` (otherwise it ignores the restored fabric and creates a new empty one). It runs unprivileged as UID 1000 (`fsGroup: 1000`), needs about twice the old server's RAM, and is placed on `net1` at `192.168.48.61` with a Ceph PVC at `/data`. Verify IPv6 reachability from `net1` to the Thread OMR prefix (the existing UniFi static route and firewall allow should apply; re-check the prefix rather than assume, it changes only if the Thread network is re-formed) and mDNS visibility before depending on it. The server docs warn that Matter's link-local multicast does not cross VLANs and that mDNS forwarders (UniFi's mDNS option) can corrupt Matter packets; the server (VLAN 48) and the border router (VLAN 50) are on different VLANs and rely on the reflector (which already worked for phone commissioning), so Thread-device operation and recovery after a pod restart are an explicit gate before the cutover is accepted, with a VLAN 50 interface as the fallback.
- **Matter cutover within the phase:** stop the RPi's Matter Server addon (two servers must never share a fabric/storage), back up its data, restore it into the Matter PVC (**the fabric credentials live there; without them every Matter device must be recommissioned**), start the cluster server, and repoint the RPi HA's Matter integration to `ws://192.168.48.61:5580/ws` (the pod's `net1` address is routable from VLAN 50; the ClusterIP is not). The RPi's addon data stays untouched as the rollback.
- **Done when (Matter):** all Matter nodes are available in the RPi's HA, a Thread and a Wi-Fi device toggle, and nodes return after a Matter pod restart.
- **Music Assistant:** new `music-assistant` app (`ghcr.io/music-assistant/server`) on `net1` at `192.168.48.62`, Ceph PVC at `/data`, web UI at `ma.<domain>` on `envoy-internal` (via the ClusterIP service on 8095), pinned to `mc1`–`mc3`. The music library lives on the QNAP and is mounted read-only over NFS at the container path the restored provider config expects (or kept as MA's SMB provider if that is what the RPi uses). Streaming providers: Spotify, YouTube Music, Tidal (credentials restored from the add-on data; re-authorization may be requested). Players are Chromecasts and an Nvidia Shield (Google Cast, mDNS), a Samsung TV QE55Q67T (AirPlay 2 over mDNS, else DLNA), all on the Trusted VLAN. The Xbox is not used for music; the mDNS reflector covers every VLAN. The Alexa Dot is not used with MA, so MA's Alexa provider (custom skill plus public HTTPS endpoints) is out of scope. The RPi add-on is stopped first, its data restored into the PVC (provider credentials and library DB live there), the "Published IP address" core setting is set to `192.168.48.62`, and the RPi HA's Music Assistant integration is repointed to `http://192.168.48.62:8095`. The MA "Home Assistant" provider is given the RPi HA URL and a long-lived token (kept out of git) and is repointed to the cluster HA at Phase 4. The firewall must allow Trusted ↔ `192.168.48.62` on all ports in both directions (players fetch streams from MA; MA connects to Chromecast on 8009 and to DLNA control URLs).
- **Done when (Music Assistant):** library and playlists are intact, playback to each Chromecast/AirPlay player in use works (including a group), the queue survives a pod restart, and the RPi's HA controls it. **DLNA is a known gap:** it discovers over SSDP, which the mDNS reflector does not forward, and MA documents no manual add by IP. Order of fallbacks: add the renderers to HA via `dlna_dmr` by URL and expose them to MA through its Home Assistant provider; otherwise a second macvlan on the Trusted VLAN (needs VLAN 10 tagged to the nodes; an explicit user decision because it puts nodes on Trusted at L2); otherwise drop DLNA for those devices.

### Phase 2 — DNS and ad-blocking

- Move Talos nameserver to `192.168.48.254` first (Talos config change; requires explicit user confirmation before apply).
- Two AdGuard Home StatefulSets (app-template), each with its own Ceph PVC, pod anti-affinity, LB IPs `192.168.48.24` (primary) and `192.168.48.25` (replica). Admin credentials via ExternalSecret.
- `adguardhome-sync` replicates primary → replica (settings, filters, rewrites, clients).
- Repoint `adguard-dns` external-dns (`ADGUARD_URL`) and `agh-proxy` to the primary.
- Upstreams: public DoH, plus conditional forwarding of the local zone and private reverse DNS to `192.168.48.254`.
- One-time import from the RPi's `AdGuardHome.yaml`: lists, rewrites (`k8s.` VIP, `qnap.`), clients; RPi-specific settings dropped.
- DHCP: shorten leases a day ahead; UniFi hands out `.24` and `.25` on all VLANs. Before RPi shutdown, check its AdGuard query log for clients still using it (static DNS settings).
- **Done when:** `dig` against both IPs from several VLANs returns correct internal records and blocklist hits; RPi AdGuard query volume is ~0.

### Phase 3 — Home Assistant restore

- HA joins the Multus macvlan network (`net1` at `192.168.48.60`), is pinned to `mc1`–`mc3`, and reaches MQTT and the Matter server by their in-cluster service names (never LB IPs, because of macvlan host isolation).
- HA restore from the HAOS backup: extract `homeassistant.tar.gz` into the config PVC. The SQLite recorder DB is excluded. (The Matter data was already migrated in Phase 1.)
- Stripped/rewired: `hassio` integration and supervisor-only entities; MQTT → in-cluster broker service; Matter → `ws://matter-server.ha-matter-server.svc.cluster.local:5580/ws`; Music Assistant → `http://music-assistant.ha-music-assistant.svc.cluster.local:8095`; AdGuard integration (if any) → new instances; `http.trusted_proxies` for the Envoy pod CIDR. Edits via `.storage/core.config_entries` or UI reconfigure.
- Recorder: `recorder: db_url: !env_var ...` from `home-assistant-secret` (CNPG credentials); no secret in git. HACS/`custom_components` ride along with the config.
- **Dry-run:** restore into the test instance on a scratch hostname with automations and the MQTT, Matter and Music Assistant entries disabled so two HAs never drive the same devices; checks boot, integration load and Postgres.

### Phase 4 — Cutover and decommission

1. Take a fresh HAOS backup, stop the RPi's HA.
2. Restore its config and start the cluster HA with `net1` (the Matter server and Z2M are already live from Phase 1).
3. Repoint `hass-proxy`'s backend to the in-cluster HA, keeping both gateways (preserves external access and the companion app URL).
4. Power off the RPi; keep the SD card/backup for a retention window.
5. After the window: remove `hass-proxy`/`agh-proxy`, update docs.

## Verification

- Phase checks are the "done when" items above.
- HA after cutover: entity count versus the old instance, automations fire, Chromecast discovery works, Matter devices respond, companion app works via `hass.<domain>`.
- Rendering: `helm template` / `kubectl kustomize` plus `task lint:all` on every manifest change before commit.

## Risks

1. **Matter fabric data restore** — failure means recommissioning every Matter device.
   Related: **Matter over a VLAN-crossing mDNS reflector** is discouraged by the matter.js docs; mitigated by the gate above.
2. **Cilium `cni.exclusive: false` + Multus** — touches CNI on every node; roll out and verify before depending on it.
3. **IPv6 / OMR route from `net1`** — verify Thread reachability before cutover.
4. **Talos nameserver switch** — must land before the RPi goes away.
5. **External access via `hass.<domain>`** — must be unchanged after the backend swap.
6. **Discovery gap** (SSDP/DHCP/ARP) — mitigated as described above.
7. **Music Assistant stream address and firewall** — MA hands players its stream URL; if its published IP is the pod IP instead of `192.168.48.62`, or the player VLAN cannot reach `.62` on all ports, playback fails while discovery looks fine.
8. **RPi-side exports** (Z2M config, `AdGuardHome.yaml`, HAOS backup) are done by the user; secrets in them are never committed or pasted into the repo.

## Delivery

One PR per phase from branches off `main` (this design on `chore/ha-rpi-decommission`). Docs updated alongside: `docs/src/general/network.md` (IP allocation, DNS flow) and `hardware.md`. Cluster mutations (Talos apply, `kubectl patch`, ArgoCD sync) each wait for explicit user confirmation.
