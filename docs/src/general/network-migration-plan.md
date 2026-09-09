# Network Migration Plan

Two phases. Phase 1 gets hardware mounted and physically verified.
Phase 2 configures UniFi and brings the office rack online.

The QNAP and Talos cluster stay powered off until Phase 2 step 2.11.
Nothing in the office rack should be plugged in before the VLANs and
the trunk port profile exist, or you will spend an evening debugging
Talos against a switch that is dropping its tags.

---

## Phase 1 — Hardware installation

### 1.1 Rack plan (garage, 6U ceiling-mounted)

Mount from the top down. The patch panel is already at the top and
stays; everything else hangs below it so you are never working above
a mounted device.

| U | Contents | Notes |
|---|---|---|
| **U6** | 24-port Cat6 patch panel | Existing, do not disturb |
| **U5** | 1U shelf 300 mm — USW-Pro-Max-16-PoE + 210 W PSU brick | Switch recessed 40-50 mm from front rail; brick behind it |
| **U4** | 1U shelf 300 mm — UCG-Max + ONT + RPi | All three side by side, 465 mm of width is plenty |
| **U3** | PDU | Check wall-wart spacing before final placement |
| **U2** | *empty* | Airflow |
| **U1** | *empty* | Airflow |

**Off-rack:** CP900EPFCLCD UPS on the garage floor, Schuko extension
run up the wall to the U3 PDU.

Do not buy the Pro Max 16 rack mount kit — it needs 400 mm rail
spacing and you have 360 mm. The shelf is the correct answer.

### 1.2 Sequence

- [ ] **Power down and strip.** Remove the RT-AX58U and everything
      loose. Keep the patch panel and its punchdowns untouched.
- [ ] **Tidy the slack.** This is the only time the rack will be
      empty. Cut and re-terminate excess, or bundle it hard to one
      side clear of the top and side vents. ~100 W is about to
      dissipate in a box on a ceiling.
- [ ] **Check the fibre bend radius** on the orange patch while you
      have access. Tight coils cause intermittent faults that look
      exactly like ISP problems.
- [ ] **Identify the "KAMERA" drop.** If there is an existing camera
      run punched down, that is a wired camera position — resolve
      whether you still want WiFi cameras before going further.
- [ ] **Mount U5 shelf**, then place switch + PSU brick.
- [ ] **Mount U4 shelf**, then place UCG-Max, ONT, RPi.
- [ ] **Mount U3 PDU.** Verify both the 210 W switch adapter and the
      UCG-Max USB-C adapter physically fit without blocking sockets.
- [ ] **Position UPS on the floor**, run Schuko extension to PDU.
      Everything in the rack goes through the UPS.

### 1.3 Cabling

- [ ] ONT → UCG-Max **WAN** port
- [ ] UCG-Max LAN → switch, using a **2.5 GbE port on both ends**
- [ ] Patch panel ports 1-6 → switch (use the 1 GbE PoE+ ports)
- [ ] RPi → switch
- [ ] Reserve one **2.5 GbE PoE++ port** for the office trunk —
      label it now
- [ ] Salon socket → U7 Pro (RTV cabinet, front edge, away from TV)
- [ ] Upper floor socket → U7 Pro
- [ ] Salon socket 2 → TL-SG105 behind TV

**Patch panel assignment — changed from the repo plan.** The repo
allocated port 7 to the server rack trunk, which assumed both racks
in the garage. With the server rack in the office, the trunk uses
the office room run instead.

| Ports | Purpose |
|---|---|
| 1-6 | Room runs — one of these is now the **office trunk** |
| 7-24 | Spare, unpunched |

All in-rack leads: 0.5 m, 28 AWG slim, low-profile boots. Colour-code
by VLAN.

### 1.4 Physical verification — do this before Phase 2

- [ ] Every patch panel port links at **1 Gbps**, not 100 Mbps. A
      marginal punchdown that negotiates 100M is the single most
      common defect in new-build wiring and it hides for years.
- [ ] iperf3 from a laptop at each wall socket.
- [ ] Rack door closes cleanly with all leads seated.
- [ ] Temperature check after 2 hours under load.

---

## Phase 2 — UniFi configuration

### 2.1 Gateway and WAN

- [ ] Adopt UCG-Max, complete UniFi OS setup, **update firmware
      before configuring anything else**.
- [ ] Configure WAN as **PPPoE** with ISP credentials.
- [ ] Set MTU. Try 1500 first (RFC 4638); fall back to 1492 if the
      session fails or you see fragmentation.
- [ ] Run a speed test **before** enabling IDS/IPS. Record the number.
- [ ] Enable IDS/IPS, test again. If throughput drops materially
      below your line rate, you have a decision to make while the
      return window is open.

### 2.2 Networks and VLANs

Existing subnets for cluster and servers are retained so Talos, the
QNAP and the RPi need no reconfiguration.

| Network | VLAN | Subnet | Gateway | DHCP pool | Purpose |
|---|---|---|---|---|---|
| Trusted | *untagged* | `192.168.10.0/24` | `.1` | `.100-.254` | PCs, phones, consoles, TVs. UniFi's edited Default network |
| IoT | 40 | `192.168.40.0/24` | `.1` | `.100-.254` | Smart home + cameras |
| Cluster | 48 | `192.168.48.0/24` | **`.254`** | *DHCP off* | Talos nodes — **existing subnet** |
| Servers | 50 | `192.168.50.0/24` | `.1` | `.100-.254` | QNAP, RPi — **existing subnet** |
| Guest | 60 | `192.168.60.0/24` | `.1` | `.100-.254` | Guest WiFi |

**VLAN ID always equals the third octet.** This is a change from the
repo plan, which had Cluster on ID 20, Servers on 30, and Guest on
ID 50 with a `192.168.60.x` subnet — an inherited mismatch that
would have misled every future reader.

**VLAN 48 breaks the "gateway is `.1`" rule on purpose.**
`192.168.48.1` is the Talos shared control-plane VIP and the target of
the `k8s.PRIVATE_DOMAIN` DNS record. The UCG-Max goes on **`.254`**
instead. DHCP is disabled on VLAN 48 entirely — every address there is
static in a Talos config or a Cilium LB pool.

> **Renumbering was NOT free — this bit us.** The original claim here
> was "Talos, the QNAP and the RPi sit on untagged access ports and
> have no VLAN ID configured, so no device reconfiguration." That is
> true of VLAN *tagging* only. It missed that the old network was one
> flat `192.168.48.0/22` segment with its gateway at `192.168.50.1`:
> the nodes' `/22` mask made the old router on-link and ARP-able.
> Splitting Cluster and Servers into separate `/24` VLANs put that
> gateway in a different broadcast domain, leaving every node with a
> default route it could not ARP for. Nodes stayed reachable from
> within VLAN 48 but could not reply to anything off-subnet.
> Fixed in `fix/talos-vlan48-routing`: node addresses `/22`→`/24`,
> default gateway `192.168.50.1`→`192.168.48.254`, NTP likewise.

Only the switch port profiles and firewall rules reference the IDs,
and both are being built from scratch here. Subnets are unchanged.

| Old ID | New ID | Network |
|---|---|---|
| 20 | **48** | Cluster |
| 30 | **50** | Servers |
| 50 | **60** | Guest |
| 10 | 10 | Trusted (unchanged) |
| 40 | 40 | IoT (unchanged) |

- [ ] Update the repo plan doc to match — the old IDs appear in its
      VLAN table, firewall table, and port assignment table

#### Address allocation convention

Apply within every subnet:

| Range | Use |
|---|---|
| `.1` | Gateway (UCG-Max) |
| `.2-.19` | Infrastructure, statically configured on the device |
| `.20-.99` | DHCP reservations |
| `.100-.254` | Dynamic pool |

#### Known static addresses (carry over unchanged)

| Host | Address | VLAN | Set where |
|---|---|---|---|
| **Cluster VIP (kube-apiserver)** | **`192.168.48.1`** | 48 | Talos config — **do not assign to the gateway** |
| mc1 | `192.168.48.2` | 48 | Talos config |
| mc2 | `192.168.48.3` | 48 | Talos config |
| mc3 | `192.168.48.4` | 48 | Talos config |
| nv1 (Jetson Orin NX) | `192.168.48.5` | 48 | Talos config |
| envoy-external | `192.168.48.20` | 48 | k8s LoadBalancer |
| envoy-internal | `192.168.48.21` | 48 | k8s LoadBalancer |
| **UCG-Max (VLAN 48 gateway)** | **`192.168.48.254`** | 48 | UniFi |
| QNAP TS-251D | `192.168.50.8` | 50 | QNAP config |
| RPi 4B (AdGuard, NUT) | `192.168.50.9` | 50 | RPi config |

`192.168.48.21` is a k8s service VIP, not a host — do not create a
DHCP reservation for it. Same for any other LoadBalancer address;
check what else your cluster hands out before defining pools, or
DHCP will eventually collide with MetalLB.

- [ ] **First action in 2.2: edit UniFi's Default network into
      Trusted** — rename it, set `192.168.10.0/24`. Do not create
      Trusted as a new network alongside Default.

  UniFi's Default network is the untagged/native LAN and cannot be
  deleted. Left at `192.168.1.0/24` it becomes a live subnet you
  never intended: anything on a port with no profile, and the UniFi
  gear itself during adoption, lands there.

  Consequence: Trusted has **no VLAN ID** — it is untagged. It is
  "VLAN 10" by convention only. That is correct, not a compromise,
  and it is what makes Trusted the native VLAN on the AP and office
  trunks. Note it in the repo so nobody hunts for a tag that does
  not exist.

  **Do this before adopting the switch and APs.** Changing the
  Default subnet after adoption renumbers the controller and every
  adopted device, forcing re-adoption and reboots.

- [ ] Confirm the LoadBalancer/MetalLB range and **exclude it from
      the VLAN 48 DHCP pool**
- [ ] Create the remaining four networks with the subnets above
- [ ] Set the DHCP pools to `.100-.254`, leaving `.2-.99` free

#### Cameras — deferred

No cameras are installed yet and the model choice is open, so
nothing is being built for them now. Two things to preserve:

- **`192.168.70.0/24` on VLAN 70 is reserved** for cameras if you
  later want them separated from IoT. Do not allocate it elsewhere.
- The default is still VLAN 40 (IoT), which needs no new network.
  Split them out only if you want cameras treated differently from
  smart plugs.

Whichever you pick, the Frigate rule is `48 → cameras, tcp/554`.

### 2.3 DHCP reservations

You have a static mapping table on Merlin. Migrate it deliberately —
this is the thing most likely to silently break services after
cutover.

- [ ] **Export from Merlin before the router comes out.** The table
      lives in `dhcp_staticlist` in nvram; `nvram get dhcp_staticlist`
      over SSH dumps it in one line. Save it to the repo.
- [ ] Keep the **same addresses**. Anything referencing them by IP —
      Frigate camera URLs, Talos configs, NFS mounts, monitoring
      targets — keeps working. Renumbering now buys nothing.
- [ ] Sort each entry into the **right VLAN**. A reservation must sit
      inside that network's subnet, so this is where the table stops
      being one flat list and becomes five.
- [ ] Add each device in UniFi and set a fixed IP.

**Three gotchas:**

**UniFi wants the client to exist first.** Historically you could
only pin an IP on a device the controller had already seen — awkward
when half your estate is powered off. Recent Network versions let you
create a client manually from a MAC address; confirm yours does
before planning around it, or you'll be doing this in two passes as
devices come online.

**No bulk import in the UI.** For a table of any size this is tedious
and error-prone. Script it against the UniFi API and keep the source
of truth in your repo — same argument as the Cloudflare ranges, and
it makes the next migration trivial.

**MAC randomisation will break phone reservations.** iOS and Android
rotate private WiFi addresses per SSID by default. Any reservation
for a handset needs "Private Wi-Fi Address" disabled on the device
itself, or the pin is meaningless.

### 2.4 Firewall — zone-based

UniFi Network 9.x+ uses zone-based policy, not a flat rule list.

**Critical default:** every network is placed in the built-in
**Internal** zone, and Internal → Internal is allowed. Create your
VLANs and leave them there and you have five subnets with zero
segmentation, silently.

#### Zones

External, Gateway and VPN are locked and need no change. Internal,
Hotspot and DMZ are editable, and **Create Zone** is available.

Two new zones only:

| Zone | Networks | Action |
|---|---|---|
| Internal | Trusted | Leave — it becomes the Trusted zone by elimination |
| **Infra** | Cluster + Servers | **Create** |
| **IoT** | IoT | **Create** |
| Hotspot | Guest | Leave — already correct |
| VPN | WireGuard | Built-in |

Cluster and Servers share **Infra** deliberately: `48 ↔ 50` stays
intra-zone Allow All, so NFS to the QNAP and AdGuard DNS need no
policy at all. That removes the rule most likely to leave the
cluster broken on first boot.

Guest in **Hotspot** is already right out of the box —
`Hotspot → Internal` defaults to Allow Return (no initiation) and
`Hotspot → External` to Allow All. Do not move it.

**Starting state is unsegmented.** Internal currently holds Trusted,
IoT, Cluster and Servers, and Internal → Internal is Allow All. Four
VLANs, zero separation, no warning. Moving IoT and the Infra pair
out is what makes the VLAN design real.

#### Policy matrix

| From ↓ / To → | Internal | Infra | IoT | Hotspot | External |
|---|---|---|---|---|---|
| **Internal** (Trusted) | — | Allow All | Allow All | Block | Allow All |
| **Infra** | Allow Return | — | **Allow All** | Block | Allow All |
| **IoT** | Allow Return | Allow Return | — | Block | **Block All** |
| **Hotspot** (Guest) | Allow Return | Allow Return | Block | — | Allow All |
| **VPN** | Allow All | Allow All | Allow All | Block | Allow All |

- `Infra → IoT` is the **Home Assistant** local control path.
- `IoT → External: Block All` is the default-deny policy.
- Use **Allow Return**, not Block All, for internal zone pairs.
  Return traffic is stateful; a hard block breaks replies to
  connections you deliberately allowed the other way.

#### Gateway-zone policies

Traffic *to* the gateway itself is a separate zone, not part of the
matrix above.

- [ ] `IoT → Gateway` udp/53 — DNS
- [ ] `IoT → Gateway` udp/123 — **NTP.** Devices with no RTC that
      cannot get time develop clock skew, TLS fails, and the
      symptoms look nothing like a network problem.
- [ ] `Hotspot → Gateway` udp/53 (verify — defaults may cover it)
- [ ] Confirm DHCP is permitted from every zone

#### Per-device IoT exceptions

Individual allow policies with a source IP, **ordered above** the
blanket `IoT → External` block. Rule ordering is explicit in the
zone UI in a way the old interface hid.

- [ ] Each exception needs a DHCP reservation first (2.3)
- [ ] Document every exception and its reason in the repo

#### Checks

- [ ] Confirm only Trusted remains in **Internal**
- [ ] Verify Home Assistant can control IoT devices — the one most
      likely to be missed
- [ ] Verify an IoT device gets correct time
- [ ] Verify Guest cannot reach anything but the internet

### 2.5 Remote access — WireGuard

Migrating from Merlin. UniFi Network has a native WireGuard server,
so no third-party container is needed.

- [ ] **Export the current Merlin config first** — server private
      key, listen port, and every peer's public key and allowed IPs.
      Do this before the AX58U is unracked.
- [ ] Create the WireGuard VPN server on the UCG-Max. Use
      **`192.168.90.0/24`** for the VPN subnet — outside every
      existing range, no ID-to-octet collision.
- [ ] Assign the VPN subnet its own zone so you can firewall it
      properly.
- [ ] Decide: reuse the existing server key so client configs keep
      working, or regenerate and reissue. Reusing is less work but
      check UniFi actually accepts an imported private key on your
      firmware version — if not, budget an evening to redistribute
      client configs.
- [ ] Forward the WireGuard UDP port. Keep the same port number if
      any client config is hard to update.
- [ ] Firewall the VPN zone deliberately. Default UniFi behaviour is
      more permissive than your Merlin rules probably were — decide
      whether VPN clients reach VLAN 48/50 or only VLAN 10.
- [ ] Test from mobile data before dismantling the old router.

**Alternative worth considering:** UniFi Teleport gives
zero-configuration client access with no port forward at all. Not a
replacement for site-to-site, but for phone-and-laptop access it
removes an open UDP port from the internet.

### 2.6 Ingress — Cloudflare

You already run **Cloudflare Tunnel** (`cloudflared` in the cluster),
and separately an IP allowlist on Merlin restricting inbound traffic
to Cloudflare ranges. Those are two different mechanisms, so the
first job is working out what the allowlist is actually protecting.

- [ ] **Audit what is port-forwarded today.** List every forward on
      the AX58U and match each against a tunnel route. Anything with
      a tunnel equivalent should be deleted, not migrated.
- [ ] For whatever genuinely needs an open port — something the
      tunnel cannot carry, non-HTTP protocols, or a service you
      have not moved yet — rebuild the allowlist:
  - [ ] Create an **IP Group** with Cloudflare's published IPv4
        ranges, plus IPv6 if any hostname is proxied on v6. A v6 gap
        is the usual way this control silently fails.
  - [ ] Create the port forward.
  - [ ] **Restrict the source to that IP Group.** In UniFi a port
        forward creates a permissive allow rule by default; skip
        this and you have published the service to the internet with
        no warning.
- [ ] Verify from outside: direct-to-IP times out, via Cloudflare
      works. Test both address families.

**Maintenance:** Cloudflare renumbers occasionally and a UniFi IP
Group is static. If any forward survives the audit, script the
group against the UniFi API from the cluster rather than relying on
a calendar reminder.

**Best outcome:** the audit finds every forward is redundant, you
delete them all, and this section disappears. No open ports, no
allowlist, no drift.

### 2.7 Switch port profiles

| Port(s) | Profile |
|---|---|
| Room drops, general | Access, VLAN 10 |
| **Office drop** | Trunk — native VLAN 10, tagged 48 + 50, 2.5 GbE |
| AP ports | Trunk — native VLAN 10, tagged **40 and 60 only** |
| Gateway uplink | 2.5 GbE |

- [ ] Do **not** tag 48 or 50 to the AP ports. No wireless client
      belongs on Cluster or Servers; tagging them puts your cluster
      subnets on the air for nothing.
- [ ] Add VLAN 70 to the AP trunks only if you split cameras off IoT
- [ ] Label the office trunk port physically as well as in UniFi
- [ ] Verify PoE draw: 2× U7 Pro ≈ 42 W against a 180 W budget

**UniFi devices themselves** (gateway, switch, APs) sit on VLAN 10 by
default. That is fine for a house this size — a separate management
VLAN adds a lockout risk that outweighs the benefit at this scale.
Decide it deliberately rather than by accident.

### 2.8 WiFi

Designed from scratch. Re-pairing devices is accepted, so nothing
here is constrained by the old Merlin configuration.

**SSID set — three for now.** Each SSID costs airtime on every band of every
AP through beacons and management frames, so this is the minimum
that delivers real separation.

- [ ] **Main** — VLAN 10, 2.4 + 5 + 6 GHz
- [ ] **IoT** — VLAN 40, **2.4 GHz only**, WPA2-PSK, PMF disabled
- [ ] **Guest** — VLAN 60, 2.4 + 5 GHz, client isolation on
- [ ] **CAM** — deferred. Add only if cameras end up wireless; give
      it its own SSID and PSK so camera credentials are not shared
      with smart plugs.

Pinning IoT to 2.4 GHz permanently solves onboarding: devices that
cannot see a 5 GHz beacon stop getting confused, and you never have
to disable a band to pair a plug again.

#### Channel plan

The EU regulatory domain allows 5 GHz channels 36-64 and 100-140,
and **everything from 100 up is DFS**. There is exactly one non-DFS
80 MHz block, which is not enough for two APs.

- [ ] **5 GHz at 40 MHz** — AP1 (salon) channel 36, AP2 (upstairs)
      channel 44. Both non-DFS. No radar events silencing an AP for
      60 seconds mid-call. 40 MHz still gives 400-600 Mbps real
      world against a 1 Gbps uplink.
- [ ] **2.4 GHz at 20 MHz** — channels 1 and 11. Never 40 MHz here.
- [ ] **6 GHz at 160 MHz** — ample spectrum, well separated. This is
      the fast lane and the reason the salon AP position matters.

#### Security

- [ ] Main: **WPA2/WPA3 transition**. Costs nothing and covers any
      old laptop or printer you forgot about.
- [ ] Verify UniFi still broadcasts 6 GHz on a transition-mode SSID.
      6 GHz mandates WPA3 — if the firmware refuses, split off a
      separate `Main-6G` SSID rather than dropping WPA2 support.
- [ ] IoT: **WPA2 only, PMF off**. Protected management frames break
      most cheap ESP32-based devices.

#### Settings

- [ ] Minimum data rate: 12 Mbps on 2.4, 24 Mbps on 5, for Main and
      Guest. Kills legacy beacon overhead and stops distant clients
      clinging. Leave IoT at default — some sensors need low rates.
- [ ] **802.11r fast roaming: Main only.** It makes walking upstairs
      mid-call seamless and it also breaks older devices. Confining
      it to Main contains the blast radius.
- [ ] 802.11k/v: on for all SSIDs. Safe, does most of the roaming work.
- [ ] Minimum RSSI **-75 dBm** on Main.
- [ ] Transmit power: **2.4 GHz low/medium, 5 GHz medium**. Max power
      on 2.4 creates an oversized cell clients cling to from the
      wrong floor — the most common self-inflicted roaming problem.
- [ ] **Disable "Auto-optimize network"** — it will undo the channel
      plan.
- [ ] mDNS/Bonjour forwarding on, if any cast target sits on IoT
      while phones are on Main.
- [ ] Client isolation on Guest.

#### Validation

- [ ] Walk the house with a WiFi analyser. Kitchen, upstairs corners,
      garage, and any planned camera position.
- [ ] Walk between APs on a call — no drop, and confirm the handover
      actually happens rather than the client clinging.

### 2.9 DNS

- [ ] AdGuard on RPi (`192.168.50.9`) as primary
- [ ] **Second AdGuard instance** once the cluster is up — a single
      DNS host is a whole-house outage waiting to happen
- [ ] Hand out both addresses via DHCP on every VLAN
- [ ] **Add the firewall rule for the second resolver.** Handing out
      an address you have blocked means clients fail over to nothing
      and DNS appears to break at random.
- [ ] **IoT and Guest use the gateway as DNS**, not AdGuard. Keeps
      their queries off your infrastructure and means a cluster or
      RPi outage cannot take guest WiFi down with it.
- [ ] AdGuard addresses are handed out on VLAN 10, 48 and 50 only.

### 2.10 Office rack

- [ ] Mount 15U rack, 3× 1U shelves, 2× PDU
- [ ] **Do not populate the fan panel**, or replace with Noctua 80 mm
- [ ] Adopt ToR switch, uplink to office wall socket, set 2.5 GbE
- [ ] Configure ToR ports: access VLAN 48 for cluster, VLAN 50 for
      QNAP, VLAN 10 for desk
- [ ] Verify the trunk carries all three VLANs before powering on
      anything else

### 2.11 Bring up storage and cluster

Only now.

- [ ] QNAP first. Confirm it gets the expected IP on VLAN 50.
- [ ] Confirm the 10 GbE card negotiates 2.5 G to the ToR switch.
- [ ] **All three M720q together, not one at a time** — staggered
      starts risk etcd quorum problems. See 2.13.
- [ ] **NUT: QNAP becomes master** for the CP1350 over USB, cluster
      nodes as network slaves. The RPi can no longer do this — it
      lives in the garage now.
- [ ] **RPi takes the CP900 over USB.** Both UPSes end up monitored,
      which is better than the repo plan where both fed one host.
- [ ] Re-point the Home Assistant NUT integration at **both**
      sources — it previously read two UPSes from one RPi.

### 2.12 Cameras — not in scope yet

Deferred until cameras are chosen. When you get there:

- Frigate as a K8s workload, **not** UniFi Protect. Recording to
  QNAP over NFS, detection via OpenVINO on the M720q Intel UHD 630
  iGPU.
- Decide VLAN 40 vs a dedicated VLAN 70 (see 2.2)
- Add `48 → cameras, tcp/554`; deny cameras → WAN
- Wired beats WiFi on every axis. Check the KAMERA drop (D1) before
  assuming wireless is the only option.
- The repo sized the iGPU detector for 2 cameras — see D11 if you
  go beyond that.

### 2.13 Power-up order and cluster verification

The QNAP and cluster are already powered off waiting on this build,
so only the power-up half of the repo's cutover procedure applies.

**Order matters:**

1. Garage rack UPS on → UCG-Max, switch, ONT come up
2. Confirm WAN, VLANs, and the office trunk carry tags correctly
3. Office rack UPS on → ToR switch
4. RPi, QNAP
5. **All three M720q together, not sequentially** — staggered starts
   risk etcd quorum problems

**Verify:**

```sh
kubectl get nodes
argocd app list
dig k8s.PRIVATE_DOMAIN @192.168.50.9
curl -I https://argocd.PRIVATE_DOMAIN
```

- [ ] All three nodes Ready
- [ ] ArgoCD apps synced
- [ ] AdGuard resolving from a trusted-VLAN device
- [ ] Internal ingress reachable
- [ ] `cloudflared` reconnected and external routes working

### 2.14 Retired gear

| Device | Action |
|---|---|
| NETGEAR GS108GE | Retire — replaced by the Pro Max 16 |
| ASUS RT-AX58U | **Keep as spare.** Merlin-capable, useful as a temporary AP if D8 says you need a third and you want to test placement before buying |
| CP550EFCLCD | Retire rather than re-battery — replaced by CP900 |

---

## Power and running cost

Revised for the new hardware.

| Device | Idle | Load |
|---|---|---|
| UCG-Max | 16W | 16W |
| USW-Pro-Max-16-PoE (base) | 25W | 25W |
| 2× U7 Pro (PoE) | 42W | 42W |
| ONT | 10W | 10W |
| RPi 4B | 5W | 7W |
| Office ToR switch | 10W | 10W |
| 3× M720q | 90W | 195W |
| QNAP TS-251D | 20W | 30W |
| **Total** | **~218W** | **~335W** |

At ~230W average and 0.80 PLN/kWh:

| | kWh/year | Cost/year |
|-|---|---|
| Garage rack (~100W) | 876 | ~700 PLN |
| Office rack (~130W avg) | 1,139 | ~911 PLN |
| **Total** | **2,015** | **~1,611 PLN** |

Up roughly 210 PLN/year on the repo estimate — the U7 Pro APs and the
UCG-Max both draw more than the U6-Lite and UCG-Ultra they replaced.
The office rack figure is now also heat you are putting into a room
you work in.

---

## Decision points and contingencies

Things that cannot be settled from a desk. Each has a trigger, a
test, and an action.

### D1 — The "KAMERA" drop (Phase 1)

**Trigger:** the labelled cable in the patch panel.
**Test:** trace it and check whether it is punched down and where it
terminates.
**If it is a live exterior run** → you have a wired camera position
you did not know about. Wired cameras beat WiFi on every axis;
revisit the camera decision before buying anything wireless.
**If it is a stub or mislabelled** → proceed with WiFi cameras, and
accept that without the garage AP they depend on the salon AP
through an exterior wall.

### D2 — PPPoE throughput with IDS/IPS (2.1)

**Test:** speed test with IDS/IPS off, then on. Record both.
**If throughput holds near line rate** → done.
**If it drops materially** → decide while the return window is open.
Options in order: disable IDS/IPS on trusted VLANs only, accept the
cap, or return the gateway. Do this test on day one, not after the
rack is cabled.

### D3 — MTU (2.1)

**Test:** bring the PPPoE session up at 1500 (RFC 4638).
**If the session fails or you see fragmentation** → fall back to
1492. Symptoms of getting this wrong are subtle: most sites work,
some large POSTs and some VPN traffic hang.

### D4 — Manual client creation in UniFi (2.3)

**Test:** try adding a DHCP reservation for a MAC the controller has
never seen.
**If your firmware allows it** → migrate the whole table in one pass
before powering anything on.
**If it does not** → two passes. Reserve what is online now, then
finish as the cluster and QNAP come up in 2.11.

### D5 — WireGuard key import (2.5)

**Test:** attempt to import the Merlin server private key.
**If accepted** → existing client configs keep working.
**If rejected** → regenerate and reissue every client config. Budget
an evening. Do not dismantle the AX58U until remote access is proven
working from mobile data.

### D6 — 6 GHz on a transition-mode SSID (2.8)

**Test:** set Main to WPA2/WPA3 transition and check whether the
6 GHz radio broadcasts it.
**If yes** → one SSID, three bands, done.
**If no** → add a separate `Main-6G` SSID rather than forcing the
whole network to WPA3.

### D7 — DFS viability (2.8, after everything works)

The plan starts conservative: 40 MHz on non-DFS channels 36 and 44.
**Test:** after a week of stable operation, move AP2 to 80 MHz on
DFS 100-112 and watch the UniFi logs for radar events.
**If clean after two weeks** → keep it, you gained bandwidth for free.
**If radar events appear** → revert. A DFS hit silences the radio for
60 seconds, which is unacceptable on a call.

### D8 — Two APs sufficient? (2.8)

**Test:** WiFi survey after the two APs are live. Kitchen, upstairs
corners, garage, camera positions.
**If coverage holds** → stop here, you saved ~880 zł.
**If the garage, a far corner, or a camera position is weak** → add
the third AP in the garage. Note this forces a third 5 GHz channel
allocation, at which point DFS stops being optional and D7 becomes
mandatory rather than a nice-to-have.

### D9 — Salon AP position (2.8)

**Test:** with the AP flat on the RTV cabinet, check 6 GHz
throughput from the sofa and coverage in the kitchen.
**If acceptable** → leave it, zero cost.
**If disappointing** → extend the drop up the wall in slim trunking
and ceiling-mount. Best RF by a clear margin and the AP disappears.

### D10 — Cloudflare ingress approach (2.6)

**Test:** audit every port forward on the AX58U against your existing
`cloudflared` tunnel routes.
**If all are redundant** → delete them, drop the allowlist entirely,
and this becomes a no-op. Best case.
**If some must stay** → rebuild the IP Group allowlist in UniFi and
script it from the cluster. Do not switch anything to the tunnel
during the migration — one change at a time.

### D11 — Frigate detector after the move (2.12)

Frigate uses OpenVINO on the M720q's Intel UHD 630 iGPU. That is
sized for 2 cameras; you are planning 3.
**Test:** check detector inference speed and CPU load once all
cameras are streaming.
**If inference time climbs** → reduce detect resolution or fps
first. Only then consider a Coral TPU.

### D12 — IoT per-device exceptions (2.4)

Policy is decided: default deny, allow per device.
**Test:** as each device is onboarded, block it and see what breaks.
**If it works locally** → leave it blocked, record it.
**If it needs cloud** → add a per-device allow and write down why.
Review the exception list every time you revisit the plan; this is
the rule set most likely to rot.

---

## Sanity checks before you commit money or time

- [ ] Confirm the Pro Max 16 rack mount kit is **not** needed — the
      shelf is the plan, rails are 360 mm and the kit wants 400 mm
- [ ] Confirm UCG-Max listing is EU stock with Polish warranty
- [ ] Confirm ISP connection type really is PPPoE
      (`WAN → Internet Connection` on Merlin, or `ip addr show ppp0`)
- [ ] Measure the UPS-to-PDU cable run before buying the extension —
      the ceiling rack makes it longer than a floor rack would
- [ ] Verify PDU socket spacing fits the 210 W switch brick and the
      UCG-Max USB-C adapter side by side
- [ ] Every patch panel port links at 1 Gbps, not 100 Mbps, before
      any configuration work starts

---

## Deferred

- Third AP (garage) — see D8
- Ceiling-mounting the salon AP — see D9
- Upper-floor drop extended to ceiling height
- NVMe in the UCG-Max if you ever want Protect
- Wired cameras if D1 turns up usable exterior runs
- Scripted UniFi API config for DHCP reservations and Cloudflare
  ranges, kept in the repo
