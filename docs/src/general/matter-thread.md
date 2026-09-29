# Matter over Thread

The production Home Assistant (HAOS on the RPi, VLAN 50) and the Thread border
router (SLZB-MR4U running OTBR, VLAN 50) are **not** managed in this repo. The
`home-automation` apps here are a test instance. This page records the network
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
