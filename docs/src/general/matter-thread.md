# Matter over Thread

The Thread border router (SLZB-MR4U running OTBR, VLAN 50) is **not** managed in
this repo. The production Home Assistant (HAOS on the RPi) is being migrated into
the cluster; the Matter server already runs in the cluster (see below). This page records the network
configuration that makes commissioning Matter devices work from a phone on the
Trusted VLAN, so it can be redone after a reset or rebuild.

## Symptom this fixes

Commissioning from an Android phone on Trusted (`192.168.10.0/24`) with the
border router on Servers (VLAN 50): BLE pairing works, the Thread credentials
upload to the device, then the app fails at the **connection test**.

## Why it fails by default

- **The Thread prefixes are not routable from Trusted.** After BLE
  provisioning the phone must reach the device at an address in the **OMR
  prefix** (a `fd..::/64` that OTBR generates). OTBR only advertises the route
  to it as an RA Route Information Option on the VLAN 50 link. The UCG-Max
  ignores RIOs sent by hosts, so it has no route and traffic from Trusted is
  dropped.
- The **mesh-local prefix** (`fd80:c04a:5687:ffff::/64`) is never routed off
  the mesh. Don't try to route it.
- **mDNS does not cross VLANs.** The phone finds the border router and, later,
  the device (advertised via SRP and OTBR's mDNS proxy on VLAN 50) by
  multicast DNS.
- **Inter-VLAN firewall** must allow Trusted to reach the OMR prefix.

## Configuration (UniFi, UCG-Max)

1. **Static IPv6 route** to the OMR prefix, next hop the SLZB's address on
   VLAN 50.
    - Destination: the OMR prefix (see below; currently `fd90:8cd6:41bc:1::/64`)
    - Next hop: the SLZB's `fd80:c04a:5687:50:…` address, or its link-local
      (`fe80::…`) on the VLAN 50 interface if the UI accepts it.
2. **Firewall policy**: allow Trusted to the OMR prefix (it sits behind the
   VLAN 50 interface after the static route), including return traffic.
3. **mDNS**: enable the mDNS reflector/proxy between Trusted and Servers.

## Finding the OMR prefix

The SLZB OS has no `ot-ctl` console, and the OMR prefix is not part of the
Thread dataset shown in its UI. Capture OTBR's own Router Advertisements from
any host on VLAN 50 (for example the HA host) and read the Route Information
Option:

```sh
tcpdump -i <iface> -vv -n 'icmp6 and ip6[40]==134 and not ether src <gateway-mac>'
```

A capture looks like `route info option (24) ... fd90:8cd6:41bc:1::/64`. The
sender's link-local address is the OTBR's, and it advertises router lifetime 0
(border router, not a default router). Exclude the UCG-Max's own RAs with its
MAC.

## Gotchas

- **Re-forming or resetting the Thread network changes the OMR prefix.**
  Update the static route and firewall policy afterwards.
- The OMR prefix is persisted across ordinary OTBR reboots.
- Stale, deprecated ULA prefixes from earlier network layouts may show up in
  RAs and `ip -6 addr` (preferred lifetime 0). They are harmless leftovers.
- If pairing fails again, capture on the HA host while pairing:
  `tcpdump -i <iface> -n 'udp port 5353 or net <omr-prefix>'`. No mDNS from the
  phone means the reflector; mDNS but no traffic to the OMR prefix means the
  route or firewall.
- Never commit the Thread network key or PSKc from the SLZB UI.

## Matter server in the cluster

The Matter server runs in the cluster (`cluster/apps/home-automation/matter-server`, namespace `ha-matter-server`) with its own VLAN 48 address `192.168.48.61` (Multus macvlan `net1`, see `network.md`). It is the matter.js server (`ghcr.io/matter-js/matterjs-server`, pinned to the version the Home Assistant addon bundled, 1.4.0). The Home Assistant Matter integration connects to `ws://192.168.48.61:5580/ws` (the WebSocket is unauthenticated and reachable from the LAN).

- **Start-up arguments matter:** the server must run with `--fabricid 2 --vendorid 4939` (hex `134b`), exactly as the HA addon passes them. Together they select the stored fabric `server-2-134b`. Without them it defaults to fabric 1 and vendor `0xfff1`, ignores the restored data and silently creates a new, empty fabric (log: `Using new server ID format: server-1-fff1`, `Found 0 nodes`).
- **Reaching the Thread devices from VLAN 48:** the server uses IPv6 to the devices' OMR addresses, which works through the UniFi static route described above. If the Thread network is re-formed and the OMR prefix changes, update that route first.
- **Data and backup:** the fabric data lives on the Ceph PVC at `/data` (matter.js storage: `server-2-134b`, `certificates`, `vendors`, `config`, `ota`). It was restored from a Home Assistant partial backup of the addon (stale `matter.lock`/`matter.pid` files removed). Never run two Matter servers on the same fabric or storage.
- **Verified 2026-10-02:** all three Thread nodes connect (the sleepy sensor in about 15 seconds) and reconnect after a pod restart.
