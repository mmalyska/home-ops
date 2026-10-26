---
name: lan-route-for-external-apps
description: An app whose HTTPRoute only attaches to envoy-external gets no AdGuard record, so LAN traffic hairpins through Cloudflare and the home uplink; add a second route on envoy-internal
metadata:
  type: reference
---

The AdGuard external-dns runs with `--gateway-name=envoy-internal`, so it only publishes records for HTTPRoutes attached to `envoy-internal` (-> 192.168.48.21). A route only on `envoy-external` gets "Gateway envoy-external does not match envoy-internal" and "No endpoints could be generated" in its logs. LAN clients then resolve the hostname to Cloudflare, and every upload or download goes out over the home uplink and back through the tunnel.

Seen on Nextcloud (2026-10-25): LAN uploads ran at 114-274 KB/s. Fix was a second HTTPRoute per host on `envoy-internal` (same annotation `external-dns.alpha.kubernetes.io/controller: dns-controller`), as Home Assistant already does. Done for nextcloud and onlyoffice in #5910.

**Why:** the bandwidth-heavy apps (files, photos, media) are exactly the ones routed external-only.
**How to apply:** when adding or reviewing any internet-exposed app that moves large data, add the internal route too. After a fix, client PCs and phones may keep the stale Cloudflare record until a DNS flush or reconnect. Check it with `nslookup` on the client; the dev container resolves differently from the LAN. See [[gateway-and-dns-architecture]].
