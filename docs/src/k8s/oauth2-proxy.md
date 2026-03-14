# OAuth2 Proxy — Protecting Apps with Envoy Gateway

oauth2-proxy runs in the `oauth2-proxy` namespace and authenticates users against Keycloak (OIDC).
It is integrated with Envoy Gateway via the `SecurityPolicy` `extAuth` mechanism — a standards-based
replacement for Traefik's `ForwardAuth` middleware.

## How It Works

```
Browser → envoy-internal → SecurityPolicy (extAuth) → oauth2-proxy /oauth2/auth
                                                              ↓ 200 OK (sets X-Auth-Request-* headers)
                                          → upstream app (receives X-Auth-Request-* headers)
```

1. A request arrives at an HTTPRoute that has a `SecurityPolicy` attached.
2. Envoy sends a sub-request to `oauth2-proxy:4180/oauth2/auth` with the original request headers
   (including the session cookie).
3. oauth2-proxy validates the session:
   - **Valid** → returns `200 OK` + `X-Auth-Request-*` response headers. Envoy forwards the
     configured headers to the upstream app and lets the request through.
   - **No/invalid session** → returns `302` redirect to the login page. Envoy forwards this
     redirect directly to the browser.
4. After login, Keycloak redirects back to `oauth.<private-domain>/oauth2/callback`, which sets
   the session cookie and redirects the user back to the original URL.

## Prerequisites

- oauth2-proxy is deployed and healthy (`kubectl get pods -n oauth2-proxy`)
- The `ReferenceGrant` in `cluster/apps/system/oauth2-proxy/templates/referencegrant.yaml`
  grants permission for `SecurityPolicy` resources in the `grocy` namespace to reference the
  `oauth2-proxy` Service. **To protect an app in a different namespace, add that namespace to
  the ReferenceGrant** (see [Adding a New Namespace](#adding-a-new-namespace)).

## Protecting an App

### 1. Add the HTTPRoute

Create `cluster/apps/{category}/{app}/templates/httproute.yaml` as usual, targeting `envoy-internal`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

### 2. Add a SecurityPolicy

Create `cluster/apps/{category}/{app}/templates/securitypolicy.yaml`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: myapp-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: myapp
  extAuth:
    http:
      backendRef:
        name: oauth2-proxy
        namespace: oauth2-proxy
        port: 4180
      path: "/oauth2/auth"
      headersToBackend:
        - X-Auth-Request-User
        - X-Auth-Request-Email
        - X-Auth-Request-Groups
        - X-Auth-Request-Preferred-Username
        - Authorization
```

`headersToBackend` lists the headers that Envoy copies from the oauth2-proxy auth response into
the upstream request. Only list headers your app actually uses — at minimum
`X-Auth-Request-Preferred-Username` if the app uses reverse-proxy auth.

### 3. Grant Cross-Namespace Access

The `SecurityPolicy` in your app's namespace references the `oauth2-proxy` Service in the
`oauth2-proxy` namespace. A `ReferenceGrant` in the `oauth2-proxy` namespace must permit this.

#### Adding a New Namespace

Edit `cluster/apps/system/oauth2-proxy/templates/referencegrant.yaml` and add your namespace to
the `from` list:

```yaml
spec:
  from:
    - group: gateway.envoyproxy.io
      kind: SecurityPolicy
      namespace: grocy
    - group: gateway.envoyproxy.io
      kind: SecurityPolicy
      namespace: myapp   # add this
  to:
    - group: ""
      kind: Service
```

## Using Auth Headers in the App

oauth2-proxy sets the following response headers on a successful auth check. These are forwarded
to the upstream app if listed in `headersToBackend`:

| Header | Value |
|--------|-------|
| `X-Auth-Request-User` | Username |
| `X-Auth-Request-Email` | User's email address |
| `X-Auth-Request-Groups` | Comma-separated group memberships |
| `X-Auth-Request-Preferred-Username` | Preferred username (most apps use this) |
| `Authorization` | Bearer token (if `pass_access_token = true`) |

### Example: Grocy `ReverseProxyAuthMiddleware`

Grocy is configured with `authClass: ReverseProxyAuthMiddleware` and
`reverseProxyAuthHeader: x-auth-request-preferred-username`. It reads the username directly from
this header — no separate login screen needed once the OAuth session exists.

## API Endpoints Without OAuth

Some apps expose an API endpoint that uses its own authentication (e.g., API keys) and should not
require an OAuth session. In this case:

- **Do not add a SecurityPolicy** to the API HTTPRoute.
- **Strip the `X-Auth-Request-Preferred-Username` header** from incoming requests to prevent
  clients from spoofing a username to bypass the app's own auth:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp-api
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp-api.<secret:private-domain>
  rules:
    - filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            remove:
              - X-Auth-Request-Preferred-Username
      backendRefs:
        - name: myapp
          port: 80
```

## Troubleshooting

### SecurityPolicy not applied — `Accepted: False`

```sh
kubectl describe securitypolicy myapp-auth -n myapp
```

Common causes:
- HTTPRoute name in `targetRefs` doesn't match the actual HTTPRoute name.
- ReferenceGrant missing or doesn't include the app's namespace.

### 403 on every request

oauth2-proxy is denying the request. Check oauth2-proxy logs:

```sh
kubectl logs -n oauth2-proxy -l app.kubernetes.io/name=oauth2-proxy --tail=50
```

Check that `email_domains = [ "*" ]` is set in the oauth2-proxy configFile (allows any email).
If you restrict to specific groups, verify the user is a member of the required Keycloak group.

### Redirect loop after login

The `redirect_url` in oauth2-proxy config must match the hostname used to access the proxy.
The current value is `https://oauth.<private-domain>/oauth2/callback`.
If `oauth.<private-domain>` is not resolving, the redirect after login will fail.

### App not receiving username header

Verify `X-Auth-Request-Preferred-Username` is listed in `headersToBackend` in the SecurityPolicy.
Verify oauth2-proxy has `set_xauthrequest = true` and `pass_user_headers = true` in its configFile.
