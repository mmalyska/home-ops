# Plan: Migrate from Traefik to Envoy Gateway

**Created:** 2026-03-13
**Status:** Phase 1 complete (2026-03-13)
**Goal:** Migrate all apps from Traefik (ingress controller) to Envoy Gateway (Gateway API), then remove Traefik entirely.

---

## Context for New Claude Sessions

This is a GitOps home-lab repo (Talos Linux + ArgoCD). Read `CLAUDE.md` at the repo root before starting — it explains the app pattern, secret management, and HTTPRoute templates. Remember to update plan after each finished step so it is up to date with progress.

**Key facts for this migration:**
- Traefik is currently at `192.168.48.50` and handles ALL internal traffic via AdGuard wildcard DNS `*.<private-domain>` → `.48.50`
- Envoy Gateway is already installed and running with two gateways:
  - `envoy-external` at `192.168.48.20` (internet-facing via Cloudflare Tunnel)
  - `envoy-internal` at `192.168.48.21` (internal network only)
- Both gateways already use the `cert-production` wildcard TLS secret — **no per-app Certificate resources needed** after migration
- The `<secret:private-domain>` token is used everywhere for the private domain — never write the real domain value
- Gateway API resources live in app namespaces but reference the gateway in `envoy-gateway` namespace
- See `CLAUDE.md` section "HTTPRoute — Internal" and "HTTPRoute — External" for the exact YAML patterns to use

**What "migrating an app" means:**
1. Add a new `templates/httproute.yaml` (or equivalent) with a `kind: HTTPRoute`
2. Disable or delete the old `Ingress`/`IngressRoute` resource (or turn off the chart-native ingress in `values.yaml`)
3. Delete any per-app `Certificate` resources (no longer needed — gateway uses `cert-production` wildcard)
4. For apps configured via chart `values.yaml` ingress blocks: set `ingress.enabled: false` (or equivalent) and add a separate `templates/httproute.yaml`

---

## Current State

### Apps Using Traefik (to migrate)

| App | Path | Kind | Gateway Target | Status |
|-----|------|------|---------------|--------|
| ArgoCD | `cluster/apps/core/argocd/resources/ingress.yaml` | `IngressRoute` | internal | enabled |
| Grafana | `cluster/apps/system/prometheus-stack/templates/httproute.yaml` | `HTTPRoute` | internal | **MIGRATED** |
| Keycloak | `cluster/apps/system/keycloak/templates/ingress.yaml` | `IngressRoute` | **both** (OIDC issuer) | enabled |
| oauth2-proxy | `cluster/apps/system/oauth2-proxy/values.yaml` | `Ingress` (chart) | external | enabled |
| Jellyfin | `cluster/apps/default/jellyfin/templates/httproute.yaml` | `HTTPRoute` | internal | **MIGRATED** |
| qnap-proxy | `cluster/apps/default/qnap-proxy/templates/httproute.yaml` | `HTTPRoute` | internal | **MIGRATED** |
| hass-proxy | `cluster/apps/default/hass-proxy/templates/ingress.yaml` | `Ingress` (x2) | internal | enabled |
| Gitea | `cluster/apps/default/gitea/values.yaml` | `Ingress` (chart) | internal | enabled |
| open-webui | `cluster/apps/default/open-webui/templates/httproute.yaml` | `HTTPRoute` | internal | **MIGRATED** |
| litellm | `cluster/apps/default/litellm/templates/httproute.yaml` | `HTTPRoute` | internal | **MIGRATED** |
| n8n | `cluster/apps/default/n8n/values.yaml` | `Ingress` (chart) | UI=internal, webhooks=external | enabled |
| rook-ceph | `cluster/apps/core/rook-ceph/cluster/values.yaml` | `Ingress` (chart) | internal | enabled |
| ollama | `cluster/apps/home-automation/ollama/templates/httproute.yaml` | `HTTPRoute` | internal | **MIGRATED** |
| home-assistant | `cluster/apps/home-automation/home-assistant/values.yaml` | `Ingress` (chart) | internal | **disabled** |
| grocy | `cluster/apps/default/grocy/templates/ingress.yaml` | `Ingress` | internal | **disabled** |
| gethomepage | `cluster/apps/default/gethomepage/values.yaml` | `Ingress` (chart) | internal | **disabled** |

### Apps Already Using Envoy Gateway
None — zero HTTPRoutes exist in `cluster/apps/` today (only the `https-redirect` inside `cluster/apps/system/envoy-gateweay/` itself).

---

## Migration Order

Work tier by tier. After each app, verify via `kubectl` or browser before moving on.

### Phase 1 — Tier 1: Straightforward apps (no special routing, no middleware)

Do these in any order. Each is a simple "add HTTPRoute + remove old Ingress + delete cert" operation.

- [x] **open-webui** — disable chart ingress in `values.yaml`, add `templates/httproute.yaml` (internal)
- [x] **litellm** — disable chart ingress in `values.yaml`, add `templates/httproute.yaml` (internal)
- [x] **ollama** — disable chart ingress in `values.yaml`, add `templates/httproute.yaml` (internal)
- [x] **Grafana** — replaced `templates/ingress.yaml` (IngressRoute) + `templates/cert.yaml` with `templates/httproute.yaml` (internal); hostname renamed `grafana.internal.` → `grafana.` to fit `cert-production` wildcard
- [x] **Jellyfin** — replaced `templates/ingress.yaml` + `templates/certificate.yaml` with `templates/httproute.yaml` (internal); cleaned up `values.yaml` ingress block
- [x] **qnap-proxy** — replaced `templates/ingress.yaml` + `templates/cert.yaml` with `templates/httproute.yaml` (internal)

### Phase 2 — Tier 2: Moderate apps (multi-route or special backend)

- [ ] **hass-proxy** — replace `templates/ingress.yaml` with two HTTPRoutes (`hass.` and `agh.` hostnames); fix broken service selector (see notes)
- [ ] **rook-ceph** — disable chart ingress in `cluster/apps/core/rook-ceph/cluster/values.yaml`, add `cluster/apps/core/rook-ceph/cluster/templates/httproute.yaml` (internal)
- [ ] **n8n** — disable chart ingress in `values.yaml`, add `templates/httproute.yaml` with two routes: `n8n-webhook.` on `envoy-external`, `n8n.` on `envoy-internal`
- [ ] **Gitea** — disable chart ingress in `values.yaml`, add `templates/httproute.yaml`; decide internal vs external
- [ ] **ArgoCD** — replace `cluster/apps/core/argocd/resources/ingress.yaml` (IngressRoute) with HTTPRoute (see gRPC note below)

### Phase 3 — Tier 3: Complex apps (auth, header filtering)

- [ ] **oauth2-proxy** — disable chart ingress, add HTTPRoute; delete `templates/forward-auth-middleware.yaml`; research SecurityPolicy extAuth as replacement
- [ ] **Keycloak** — replace IngressRoute with HTTPRoute on both gateways; resolve the Cloudflare Warp header block (see unknowns)

### Phase 4 — DNS Cutover

> **Strategy changed (2026-03-13):** The wildcard `*.<domain>` → `192.168.48.50` has been removed from `internal-gateway-endpoint`. DNS is now managed per-app: external-dns picks up each HTTPRoute (annotated `controller: dns-controller`) and creates an A record → `192.168.48.21` automatically. Remaining Traefik-specific static records are kept until those apps are migrated.

- [x] ~~Change wildcard target from `.48.50` to `.48.21`~~ — **replaced by per-app external-dns via HTTPRoute source**
- [ ] After ArgoCD is migrated (Phase 2): remove the `argocd.<domain>` → `192.168.48.50` static record from `internal-gateway-endpoint` in `cluster/apps/system/adguard-dns/templates/dnsendpoints.yaml`
- [ ] After Keycloak is migrated: remove the `l.<domain>` → `192.168.48.50` static record from `keycloak-endpoint` in `cluster/apps/system/adguard-dns/templates/dnsendpoints.yaml` (added 2026-03-14)

### Phase 5 — Re-enable disabled apps with HTTPRoutes

- [ ] **grocy** — replace `templates/ingress.yaml` with HTTPRoute; implement extAuth SecurityPolicy (depends on oauth2-proxy Phase 3)
- [ ] **gethomepage** — disable chart ingress, add HTTPRoute (internal, bare domain)
- [ ] **home-assistant** — disable chart ingress, add HTTPRoute (internal, two hostnames)

### Phase 6 — Remove Traefik

- [ ] Set `enabled: "false"` in `cluster/apps/system/traefik/app-config.yaml`
- [ ] Delete the Traefik Middleware CRDs file: `cluster/apps/system/oauth2-proxy/templates/forward-auth-middleware.yaml`
- [ ] Delete the entire `cluster/apps/system/traefik/` directory
- [ ] Release IP `192.168.48.50` from known IPs table in `CLAUDE.md`

---

## HTTPRoute Templates to Use

These are the exact patterns from `CLAUDE.md`. Copy-paste and adapt.

### Internal-only app

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: internal
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp-service-name
          port: 80
```

### External-only app (Cloudflare DNS + Tunnel)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: external
spec:
  parentRefs:
    - name: envoy-external
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp-service-name
          port: 80
```

### Both internal and external

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: external
spec:
  parentRefs:
    - name: envoy-external
      namespace: envoy-gateway
      sectionName: https
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp-service-name
          port: 80
```

> TLS is NOT specified in HTTPRoutes — it's terminated at the gateway using the `cert-production` wildcard. No `tls:` block needed.

---

## Per-App Migration Notes

### ArgoCD — gRPC routing

**Current:** `cluster/apps/core/argocd/resources/ingress.yaml`
- Has two rules: one normal HTTP (priority 10), one for gRPC where `Content-Type: application/grpc` routes with `scheme: h2c`

**Solution:** HTTPRoute rules are evaluated in order (first-match wins). Set `appProtocol: kubernetes.io/h2c` on the `argocd-server` service port so Envoy knows to use h2c upstream. A single HTTPRoute with one rule is sufficient — Envoy handles gRPC transparently over h2c.

Check if argocd chart already sets `appProtocol`:
```sh
kubectl get svc argocd-server -n argocd -o yaml | grep appProtocol
```

If not, patch it or add to values. Then a plain HTTPRoute on `envoy-internal` is enough.

**Files to change:**
- Replace `cluster/apps/core/argocd/resources/ingress.yaml` with HTTPRoute
- May need to add `appProtocol: kubernetes.io/h2c` to argocd-server service via ArgoCD values

---

### Keycloak — priority rules + Cloudflare Warp block

**Current:** `cluster/apps/system/keycloak/templates/ingress.yaml`
- Rule 1 (priority 1): `Host AND PathPrefix(/) AND NOT HeaderRegexp(Cf-Warp-Tag-Id, .*)` — blocks Cloudflare Warp clients from accessing the full app
- Rule 2 (priority 2): `Host AND (PathPrefix(/realms) OR PathPrefix(/resources) OR Path(/robots.txt))` — allows public OIDC endpoints

**UNKNOWN — decision needed:** Why is Cloudflare Warp blocked on Keycloak? Is this still needed? Options:
1. **Remove the restriction** — simplest if it's no longer needed
2. **EnvoyPatchPolicy** (raw xDS) — can add inverted header match but complex
3. **SecurityPolicy with CEL** — not available in current version
4. **Drop the negative match** — only allow specific paths publicly, require everything else to come from internal network (different approach to same goal)

**Gateway target:** Must be on BOTH gateways — Keycloak is the OIDC issuer for kube-apiserver (external access required) and for internal apps.

**Files to change:**
- Replace `cluster/apps/system/keycloak/templates/ingress.yaml` with HTTPRoute on both gateways

---

### oauth2-proxy — ForwardAuth → SecurityPolicy

**Current:** `cluster/apps/system/oauth2-proxy/templates/forward-auth-middleware.yaml`
Four Traefik `Middleware` objects:
- `forward-auth` (chain → `forward-auth-redirect`)
- `forward-auth-auth` (`forwardAuth` to `https://oauth.<private-domain>/oauth2/auth`)
- `forward-auth-error` (handles 401/403 → redirect to `/oauth2/sign_in`)
- `forward-auth-redirect` (`forwardAuth` to internal svc URL, passes through auth response headers)
- `forward-auth-strip-headers` (removes `X-Auth-Request-Preferred-Username` from request)

**Envoy Gateway equivalent:**
- Replace with `SecurityPolicy` using `extAuth` pointing to oauth2-proxy's internal service
- oauth2-proxy supports both HTTP (port 4180 `/oauth2/auth`) and gRPC ext_authz — check which Envoy uses
- Header passthrough (X-Auth-Request-User, X-Auth-Request-Email, etc.) configured in `extAuth.http.headersToBackend`
- `forward-auth-strip-headers` maps to `HTTPRouteFilter` with `RequestHeaderModifier` removing the header

**UNKNOWN:** Confirm oauth2-proxy ext_authz compatibility with Envoy Gateway. oauth2-proxy docs show `--reverse-proxy` flag for extAuth mode.

**Grocy** depends on this middleware. Its `values.yaml` references:
- `oauth2-proxy-forward-auth@kubernetescrd` → main ingress (full auth)
- `oauth2-proxy-forward-auth-strip-headers@kubernetescrd` → API ingress

After migration, grocy will need a `SecurityPolicy` attached to its HTTPRoute instead.

---

### hass-proxy — ExternalName backends + broken selector

**Current:** `cluster/apps/default/hass-proxy/templates/ingress.yaml`
- Two Ingress objects: `hass.` → ExternalName svc to `192.168.50.9:8123`, `agh.` → `192.168.50.9:8812`
- The `hass-proxy` service has a broken `selector` pointing at Traefik pods — clean this up when migrating

**Note:** `agh.<private-domain>` proxies to AdGuard Home's management UI. This is different from the AdGuard DNS server itself — routing is fine, just be aware.

**RESOLVED:** ExternalName services do NOT work with Envoy Gateway — Envoy reports `no ready endpoints` and returns 503. Use a ClusterIP `Service` with no selector + a matching `Endpoints` resource with the target IP instead.

---

### n8n — split internal/external routing

**Current:** `cluster/apps/default/n8n/values.yaml` — single `Ingress` with two hosts
- `n8n-webhook.<private-domain>` path `/webhook` — needs to be externally reachable for webhook delivery
- `n8n.<private-domain>` path `/` — UI, internal only

**Solution:** Two separate HTTPRoutes (or one with two parentRefs — but different gateways makes two cleaner):
1. Internal HTTPRoute: `n8n.<private-domain>` → `envoy-internal`
2. External HTTPRoute: `n8n-webhook.<private-domain>` → `envoy-external` (and optionally also `envoy-internal`)

**Files to change:**
- Disable `ingress:` block in `cluster/apps/default/n8n/values.yaml`
- Add `cluster/apps/default/n8n/templates/httproute.yaml` with two HTTPRoute objects

---

### rook-ceph — chart-native ingress

**Current:** `cluster/apps/core/rook-ceph/cluster/values.yaml` — ingress configured inline in chart values

**Solution:**
1. Remove the `ingress.dashboard` block from `values.yaml`
2. Add `cluster/apps/core/rook-ceph/cluster/templates/httproute.yaml` with plain internal HTTPRoute

Hostname: `rook.<secret:private-domain>`, service: `rook-ceph-mgr-dashboard` port `https-dashboard` (or `8443`) in namespace `rook-ceph`.

**Note:** rook-ceph has `syncPolicy.enabled: false` (never auto-syncs). After making changes, manually sync in ArgoCD: first sync the operator, then the cluster app.

---

### Grafana — has own Certificate to delete

**Current:** `cluster/apps/system/prometheus-stack/templates/ingress.yaml`
- IngressRoute targeting `grafana.internal.<private-domain>` with `tls.secretName: grafana-internal-domain`
- The cert-manager `Certificate` resource is in the same file

**Solution:** Replace both resources with a single HTTPRoute. The `.internal.` subdomain is just a naming convention here — it still resolves fine via envoy-internal. Keep the same hostname.

---

### Jellyfin — has own Certificate to delete

**Current:** `cluster/apps/default/jellyfin/templates/ingress.yaml` + `templates/certificate.yaml`

**Note:** Jellyfin also has a direct LoadBalancer service at `192.168.48.22` for media streaming (separate from HTTP ingress). That service is unaffected by this migration.

Decide: internal or external gateway? Jellyfin is a media server — if you want remote access, use `envoy-external`. If home-only, `envoy-internal`.

---

### Gitea — SSH consideration

**Current:** `cluster/apps/default/gitea/values.yaml` — chart-native ingress

HTTP migration is straightforward. SSH server is `START_SSH_SERVER: false` so no SSH handling needed now. If SSH is needed in future: requires a separate `LoadBalancer` service (HTTPRoute cannot do TCP).

---

## DNS Cutover Strategy

**Actual approach (changed 2026-03-13):** Per-app DNS via external-dns, not a single wildcard flip.

- The `internal-gateway-endpoint` wildcard `*.<domain>` → `192.168.48.50` has been **removed**
- external-dns (adguard controller) automatically creates A records → `192.168.48.21` for each HTTPRoute annotated with `controller: internal`
- The only remaining static Traefik record is `argocd.<domain>` → `192.168.48.50` in `internal-gateway-endpoint`, which stays until ArgoCD is migrated

**Testing migrated apps:**
- DNS resolves automatically once the HTTPRoute is deployed and accepted
- Or use `curl -sk -H "Host: myapp.<private-domain>" https://192.168.48.21/` to test before DNS propagates

**Final cleanup (after ArgoCD migration):**
Remove the `argocd.<domain>` entry from `cluster/apps/system/adguard-dns/templates/dnsendpoints.yaml` `internal-gateway-endpoint`.

---

## Verification Steps

After each app migration:
```sh
# Check HTTPRoute is accepted by the gateway
kubectl get httproute -n <namespace>
kubectl describe httproute <name> -n <namespace>

# Check with egctl (Envoy Gateway CLI)
egctl x status httproute -A --quiet

# Check the app responds (before DNS cutover, hit the gateway IP directly)
curl -sk -H "Host: myapp.<private-domain>" https://192.168.48.21/ | head -5
```

---

## Files to Remove at Final Traefik Cleanup

| File/Dir | Action |
|----------|--------|
| `cluster/apps/system/traefik/` | Delete entire directory |
| `cluster/apps/system/oauth2-proxy/templates/forward-auth-middleware.yaml` | Delete (Traefik Middleware CRDs) |
| `cluster/apps/core/argocd/resources/ingress.yaml` | Delete (replaced by httproute) |
| `cluster/apps/system/keycloak/templates/ingress.yaml` | Delete (replaced by httproute) |
| `cluster/apps/system/prometheus-stack/templates/ingress.yaml` | Delete (replaced by httproute + cert gone) |
| `cluster/apps/default/jellyfin/templates/ingress.yaml` | Delete |
| `cluster/apps/default/jellyfin/templates/certificate.yaml` | Delete |
| `cluster/apps/default/grocy/templates/ingress.yaml` | Delete |
| `cluster/apps/default/qnap-proxy/templates/ingress.yaml` | Delete |
| `cluster/apps/default/hass-proxy/templates/ingress.yaml` | Delete |
| Per-app cert resources in oauth2-proxy, grafana | Delete |
| `cluster/apps/system/adguard-dns/templates/dnsendpoints.yaml` line 26 | Change `.48.50` → `.48.21` |

Also update `CLAUDE.md` LoadBalancer IP table to remove `192.168.48.50` (Traefik) entry.

---

## Open Questions / Decisions Needed

1. **Keycloak Warp block** — ~~Is the `!HeaderRegexp(Cf-Warp-Tag-Id, .*)` rule still needed?~~ **DECIDED: Remove it — no longer needed.** Use plain HTTPRoute on both gateways.

2. **oauth2-proxy extAuth** — Confirm which ext_authz protocol Envoy Gateway uses (HTTP vs gRPC). Review oauth2-proxy docs for `--reverse-proxy` mode compatibility.

3. **Jellyfin** — ~~Internal or external gateway?~~ **DECIDED: internal only (`envoy-internal`)**

4. **Gitea** — ~~Internal or external gateway?~~ **DECIDED: internal only (`envoy-internal`)**

5. **hass-proxy ExternalName** — Test whether ExternalName services work with Envoy Gateway or if manual EndpointSlice is needed.
