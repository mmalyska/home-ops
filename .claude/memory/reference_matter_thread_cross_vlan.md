---
name: matter-thread-cross-vlan
description: "Prod HA + SLZB-MR4U OTBR are not in repo; phone on Trusted needs UniFi static route to OMR prefix, firewall allow and mDNS reflector to commission Matter over Thread"
metadata:
  node_type: memory
  type: reference
  originSessionId: bc83211a-525c-4df8-8132-82ebf4e80d6a
  modified: 2026-09-29T12:51:35.080Z
---

Production Home Assistant (RPi, VLAN 50) and the SLZB-MR4U OTBR are NOT managed in this repo; `cluster/apps/home-automation` is a test instance only.

Commissioning from a phone on Trusted (VLAN untagged, 192.168.10.0/24) needs: UniFi static IPv6 route to the OTBR's OMR prefix via the SLZB on VLAN 50, a firewall allow Trusted -> OMR prefix, and the mDNS reflector. Fixed and verified working 2026-09-29. Full runbook: docs/src/general/matter-thread.md.

**Why:** the gateway ignores RIOs from hosts, and mDNS does not cross VLANs. SLZB OS has no `ot-ctl`; find the OMR prefix by tcpdump of OTBR RAs on VLAN 50.

**How to apply:** if Matter pairing fails again, or the Thread network is re-formed (OMR prefix changes), check the static route/firewall first. Never commit the Thread network key/PSKc.
