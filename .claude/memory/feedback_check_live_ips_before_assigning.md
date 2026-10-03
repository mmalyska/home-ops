---
name: Check live IPs before assigning one
description: Never trust the docs for free LB/macvlan IPs; list live services and pools first and update docs/src/general/network.md in the same PR
metadata:
  type: feedback
---

Before assigning any fixed IP on VLAN 48 (LoadBalancer `lbipam.cilium.io/ips` or a Multus macvlan address), run the checks in docs/src/general/network.md ("Check before assigning an address") and update that table in the same PR.

**Why:** on 2026-10-03 the plan reserved 192.168.48.24 for AdGuard, but `alloy-router-syslog` already had it (the docs did not list it), and the macvlan block .60-.69 sat inside `coder-pool` (.51-.70, no serviceSelector). Both were only caught by listing the live cluster.

**How to apply:** list live LB IPs and Multus annotations (commands in the doc), check both Cilium pools, grep the repo, and prefer the docs table only as a record, not as truth. Macvlan addresses are invisible to Cilium, so a clash there is silent.
