---
name: add-app
description: >
  Step-by-step workflow for adding a new application to the home-ops cluster.
  Use when creating a new ArgoCD app, writing app-config.yaml, Chart.yaml,
  values.yaml, HTTPRoutes, ExternalSecrets, or any cluster/apps/ templates.
when_to_use: >
  Trigger phrases: "add app", "new application", "create app", "deploy X to cluster",
  "add HTTPRoute", "write ExternalSecret", "add secret for app".
---

# Add App Skill

Use this skill when adding a new application, creating HTTPRoutes, writing ExternalSecrets, or working with template patterns.

## Adding a New Application

1. Create directory `cluster/apps/{category}/{app-name}/`
2. Create `app-config.yaml` with `enabled: "true"`, namespace, and sync policy
3. Add `Chart.yaml` with Helm chart dependency (or `kustomization.yaml`)
4. Add `values.yaml` with customizations
5. If secrets needed: create `templates/credentials-externalsecret.yaml` for K8s Secret data fields, or add `SECRET_PROVIDER: cluster-secrets` plugin block for `<secret:key>` tokens in non-injectable fields
6. Add any extra manifests in `templates/`
7. Commit — ArgoCD ApplicationSet will auto-discover the new app

## Secrets — Step-by-Step

### Adding a global token (non-injectable field, e.g. hostname in values.yaml)

1. Add secret to Bitwarden Secrets Manager, note its UUID
2. Add entry to `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`
3. Use `<secret:key>` token in template/values file
4. Set `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`

### Adding a per-app credential (K8s Secret data field)

1. Add secret to Bitwarden Secrets Manager, note its UUID
2. Create `templates/credentials-externalsecret.yaml` with the ExternalSecret
3. Reference via `secretKeyRef` or ESO template expressions

## ExternalSecret Pattern (Bitwarden)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: my-app-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: my-app-secret
    creationPolicy: Owner
  data:
    - secretKey: MY_KEY
      remoteRef:
        key: "<bitwarden-uuid>" #gitleaks:allow #MY_KEY_NAME
```

Mark UUID lines with `#gitleaks:allow #KEY_NAME` to suppress false positives.

**ESO template expressions inside Helm `templates/`** — wrap `{{ }}` in Go raw string literals:

```yaml
MY_VALUE: "{{ `{{ .MY_KEY }}` }}"
```

## HTTPRoute — Internal (AdGuard DNS, home network only)

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

## HTTPRoute — External (Cloudflare DNS + Tunnel, internet-facing)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-external
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - myapp.<secret:private-domain>
  rules:
    - backendRefs:
        - name: myapp
          port: 80
```

## HTTPRoute — Both internal and external

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
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
        - name: myapp
          port: 80
```

## DNS routing — annotation rules

| Annotation value | Processed by | Used on |
|-----------------|-------------|---------|
| `dns-controller` | adguard-dns (envoy-internal routes) or cloudflare-dns (envoy-external routes) | HTTPRoutes |
| `internal` | adguard-dns only | DNSEndpoints |
| `external` | cloudflare-dns only | DNSEndpoints |

HTTPRoutes always use `controller: dns-controller`. Which DNS backend processes it is determined by which gateway it attaches to.

TLS is terminated at the gateway using the wildcard `cert-production` secret — no per-app Certificate resource needed unless a different domain is required.

## TLS Certificate (cert-manager) — only when wildcard doesn't cover it

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-cert
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
spec:
  secretName: myapp-cert
  issuerRef:
    name: lets-encrypt-dns01-production-cf
    kind: ClusterIssuer
  commonName: "myapp.<secret:private-domain>"
  dnsNames:
    - "myapp.<secret:private-domain>"
```
