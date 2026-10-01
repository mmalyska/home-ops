# RPi Decommission — Home Assistant Stack In-Cluster Design

**Date:** 2026-10-01
**Status:** Draft — awaiting review

## Goal

Decommission the Raspberry Pi (`192.168.50.9`, HAOS) and run everything it hosts in the cluster: Home Assistant, AdGuard Home (DNS + ad-blocking), MQTT, Zigbee2MQTT and the Matter server. The Zigbee/Thread coordinator is already the network-attached SLZB-MR4U, so no radio hardware has to move.

## Context & Decisions

- **MQTT broker:** reuse the existing, currently disabled `cluster/apps/home-automation/rabbitmq` app (RabbitMQ + `rabbitmq_mqtt`, chosen over Mosquitto/VerneMQ in `2026-07-06-rabbitmq-operator-design.md`). It gains a `zigbee2mqtt` user.
- **DNS / ad-blocking:** two AdGuard Home instances in the cluster, both blocking, both handed out by DHCP. UniFi is **not** handed to clients as a secondary: clients do not reliably prefer the primary (systemd-resolved sticks, Windows/macOS/Android race or pick fastest), so a non-filtering secondary would leak ads and, if it lacked internal records, return NXDOMAIN for them. UniFi (UCG-Max `192.168.48.254`) is used only as an upstream for the local zone and reverse lookups, and as the resolver for Talos nodes.
- **Full-cluster outage:** accepted risk (user decision); no external last-resort DNS.
- **Home Assistant network:** HA and the Matter server each get a Multus macvlan interface (`net1`) on VLAN 48 with a static IP, instead of `hostNetwork`. UniFi's mDNS reflector (already enabled across VLANs) delivers Chromecast/Matter mDNS to that segment. VLAN 48 and 50 are in one allow-all firewall zone and VLAN 48 has IPv6 enabled.
- **Known gap:** SSDP/UPnP, DHCP-broadcast discovery and MAC-based ARP presence do not cross VLANs. Only QNAP remains on VLAN 50 and UPnP is disabled in UniFi. Mitigation: UniFi integration for presence, IP-based setup (with DHCP reservations) for other devices; a tagged-VLAN macvlan is the fallback if something specific needs it.
- **Recorder history:** start fresh on the CNPG Postgres cluster already defined in the HA app. The RPi's SQLite file is not restored; keep it as an archive.
- **Sequencing:** phased, each phase leaving the RPi functional (see below).

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

### Phase 1 — Zigbee2MQTT standalone

- New app `home-automation/zigbee2mqtt`: app-template StatefulSet, image `koenkk/zigbee2mqtt`, Ceph PVC at `/app/data`, frontend at `z2m.<domain>` on `envoy-internal`.
- Config restored into the PVC from the RPi addon export: `configuration.yaml`, `database.db`, `coordinator_backup.json`. Same network key and PAN ID, so no device re-pairs. Nothing from these files is committed.
- Adapter: `serial.port: tcp://<slzb-ip>:6638` with the adapter type taken from the existing config; both verified in the SLZB UI.
- MQTT credentials via ExternalSecret → env (`ZIGBEE2MQTT_CONFIG_MQTT_*`). `base_topic` and `homeassistant: true` unchanged.
- Cutover within the phase: stop the RPi's Z2M **and** Mosquitto addons (exactly one Z2M may own the coordinator), repoint the RPi HA MQTT integration to `mqtt.<domain>`, start cluster Z2M. Z2M republishes discovery; entities keep their IDs.
- **Done when:** all Zigbee devices are visible in the RPi's HA, a state-change round trip works, and the device survives a Z2M pod restart.

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

- Cilium: set `cni.exclusive: false`; deploy Multus; create a macvlan NetworkAttachmentDefinition on `eth0` (VLAN 48) with static IPAM from a reserved block outside the `.20–.50` pool (for example `.60–.69`), plus routes so replies to LAN/VLAN 50 leave via `net1`. HA and the Matter server are pinned to `mc1`–`mc3`.
- Add `python-matter-server` as a new app; HA connects over a websocket on the cluster network. Verify IPv6 reachability from `net1` to the Thread OMR prefix; the existing UniFi static route and firewall allow should apply, and the OMR prefix is re-checked rather than assumed (it changes only if the Thread network is re-formed).
- HA restore from the HAOS backup: extract `homeassistant.tar.gz` into the config PVC and the Matter server addon data into the Matter PVC (**the Matter fabric credentials live there; without them every Matter device must be recommissioned**). The SQLite recorder DB is excluded.
- Stripped/rewired: `hassio` integration and supervisor-only entities; MQTT → `mqtt.<domain>`; Matter → new websocket URL; AdGuard integration (if any) → new instances. Edits via `.storage/core.config_entries` or UI reconfigure.
- Recorder: `recorder: db_url: !env_var ...` from `home-assistant-secret` (CNPG credentials); no secret in git. HACS/`custom_components` ride along with the config.
- **Dry-run:** restore into the test instance on a scratch hostname with automations, MQTT and Matter entries disabled so two HAs never drive the same devices; checks boot, integration load and Postgres.

### Phase 4 — Cutover and decommission

1. Take a fresh HAOS backup, stop the RPi's HA.
2. Restore it (config + Matter data) and start the cluster HA with `net1`.
3. Repoint `hass-proxy`'s backend to the in-cluster HA, keeping both gateways (preserves external access and the companion app URL).
4. Power off the RPi; keep the SD card/backup for a retention window.
5. After the window: remove `hass-proxy`/`agh-proxy`, update docs.

## Verification

- Phase checks are the "done when" items above.
- HA after cutover: entity count versus the old instance, automations fire, Chromecast discovery works, Matter devices respond, companion app works via `hass.<domain>`.
- Rendering: `helm template` / `kubectl kustomize` plus `task lint:all` on every manifest change before commit.

## Risks

1. **Matter fabric data restore** — failure means recommissioning every Matter device.
2. **Cilium `cni.exclusive: false` + Multus** — touches CNI on every node; roll out and verify before depending on it.
3. **IPv6 / OMR route from `net1`** — verify Thread reachability before cutover.
4. **Talos nameserver switch** — must land before the RPi goes away.
5. **External access via `hass.<domain>`** — must be unchanged after the backend swap.
6. **Discovery gap** (SSDP/DHCP/ARP) — mitigated as described above.
7. **RPi-side exports** (Z2M config, `AdGuardHome.yaml`, HAOS backup) are done by the user; secrets in them are never committed or pasted into the repo.

## Delivery

One PR per phase from branches off `main` (this design on `chore/ha-rpi-decommission`). Docs updated alongside: `docs/src/general/network.md` (IP allocation, DNS flow) and `hardware.md`. Cluster mutations (Talos apply, `kubectl patch`, ArgoCD sync) each wait for explicit user confirmation.
