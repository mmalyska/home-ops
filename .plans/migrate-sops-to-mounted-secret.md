# Plan: Migrate from SOPS to Mounted K8s Secret (argocd-secret-replacer)

## Goal

Replace all per-app SOPS-encrypted `secret.sec.yaml` files with two mechanisms:
1. **Global `cluster-secrets`** K8s Secret mounted into ArgoCD repo-server sidecars — feeds the
   `argocd-secret-replacer secret --mount /cluster-secrets` command for tokens that appear in
   fields that cannot use `secretKeyRef` injection (hostnames, cert dnsNames, ConfigMap values,
   Middleware addresses, NFS server fields, Helm values.yaml strings, etc.)
2. **Per-app `ExternalSecret`** resources (Bitwarden) — for credentials that end up in K8s
   `Secret` `data`/`stringData` fields, consumed via `secretKeyRef` or ESO template rendering

## The Architectural Rule (apply everywhere, no exceptions)

> **Token in a `Secret` `data`/`stringData` field** → replace with ESO `ExternalSecret`.
> Plugin NOT needed.
>
> **Token in any other field** (hostname, cert spec, ConfigMap, Middleware, values.yaml string,
> NFS server, etc.) → keep `<secret:key>` token, resolved by plugin from `/cluster-secrets` mount.
> Plugin IS needed.

This means:
- `cluster-secrets` contains **only** keys that appear in non-injectable fields:
  `private-domain`, `s3_endpoint` (used in `values.yaml` barmanObjectStore URL strings)
- `s3_access_key` and `s3_secret_key` appear **only** in `Secret` `data` fields
  (`<secret:s3_access_key|base64>`) → these go to **per-app ExternalSecrets**, NOT
  `cluster-secrets`
- App-specific credentials (API keys, passwords, tokens) always go to per-app ExternalSecrets

## Prerequisites

- The `argocd-secret-replacer` plugin must already have the new `secret --mount` verb implemented
  and released. See `.plans/argocd-secret-replacer-k8s-provider.md`.
- All secrets listed in the "Bitwarden secrets to add" section below must exist in Bitwarden
  Secrets Manager before any app migration is attempted. The agent doing this work does NOT add
  secrets to Bitwarden — that must be done manually by the operator.
- The `bitwarden` ClusterSecretStore is already working (cloudflare-dns, adguard-dns, cloudflared
  all use it successfully).

## Bitwarden Secrets to Add (manual — operator action before starting)

Secrets must be added to Bitwarden Secrets Manager in project
`422f340a-6eb8-4a4f-90d1-b3fe00d00d76`. Note the UUID of each for use in ExternalSecret
`remoteRef.key` fields. Mark UUIDs with `#gitleaks:allow #KEY_NAME` comments in YAML.

### Global — go into `cluster-secrets` (used in non-injectable fields only)
| Key name in Secret | Bitwarden key name | Used in |
|--------------------|--------------------|---------|
| `private-domain` | `PRIVATE_DOMAIN` | hostnames, cert dnsNames, ConfigMap, Middleware, values.yaml |
| `s3_endpoint` | `S3_ENDPOINT` | `values.yaml` barmanObjectStore.endpointURL strings |

### Per-app — go into individual ExternalSecrets (used only in Secret data fields)
| Bitwarden key name | App | Target Secret key | Description |
|--------------------|-----|-------------------|-------------|
| `ARGOCD_PRIVATE_REPO_TYPE` | argocd | `type` | git repo type |
| `ARGOCD_PRIVATE_REPO_URL` | argocd | `url` | git repo URL |
| `ARGOCD_PRIVATE_REPO_USERNAME` | argocd | `username` | git repo username |
| `ARGOCD_PRIVATE_REPO_PASSWORD` | argocd | `password` | git repo password |
| `ARGOCD_OIDC_KEYCLOAK_CLIENT_SECRET` | argocd | `oidc.keycloak.clientSecret` | Keycloak OIDC client secret |
| `S3_ACCESS_KEY` | gitea, keycloak, home-assistant, litellm, n8n | `S3_ACCESS_KEY_ID` | S3 access key ID |
| `S3_SECRET_KEY` | gitea, keycloak, home-assistant, litellm, n8n | `S3_ACCESS_SECRET_KEY` | S3 secret access key |
| `BOTKUBE_DISCORD_BOTID` | botkube | `discord_botid` | Discord bot ID |
| `BOTKUBE_DISCORD_TOKEN` | botkube | `discord_token` | Discord bot token |
| `BOTKUBE_DISCORD_CHANNEL` | botkube | `discord_channel` | Discord channel ID |
| `N8N_ENCRYPTION_KEY` | n8n | `encryption-key` | n8n encryption key |
| `LITELLM_MASTER_KEY` | litellm | `LITELLM_MASTER_KEY` | LiteLLM master key |
| `LITELLM_ANTHROPIC_API_KEY` | litellm | `ANTHROPIC_API_KEY` | Anthropic API key |
| `LITELLM_OPENAI_API_KEY` | litellm | `OPENAI_API_KEY` | OpenAI API key |
| `MINECRAFT_WHITELIST_USERS` | minecraft-bedrock | `whitelistUsers` | Whitelist users JSON |
| `MINECRAFT_OPS` | minecraft-bedrock | `ops` | Ops users JSON |
| `VINTAGESTORY_WORLD_PASSWORD` | vintagestory | `world-password` | World password |
| `CERT_MANAGER_API_TOKEN` | cert-manager | `api-token` | Cloudflare API token |
| `CERT_MANAGER_EMAIL` | cert-manager | `email` | ACME email |
| `DYNDNS_TOKEN` | dyndns | `token` | DynDNS token |
| `DYNDNS_DOMAIN_COM_ZONE` | dyndns | `domain-com-zone` | .com zone ID |
| `DYNDNS_DOMAIN_COM_NAME` | dyndns | `domain-com-name` | .com domain name |
| `DYNDNS_DOMAIN_CLOUD_ZONE` | dyndns | `domain-cloud-zone` | .cloud zone ID |
| `DYNDNS_DOMAIN_CLOUD_NAME` | dyndns | `domain-cloud-name` | .cloud domain name |
| `OAUTH2_PROXY_CLIENT_ID` | oauth2-proxy | `client-id` | OIDC client ID |
| `OAUTH2_PROXY_CLIENT_SECRET` | oauth2-proxy | `client-secret` | OIDC client secret |
| `OAUTH2_PROXY_COOKIE_SECRET` | oauth2-proxy | `cookie-secret` | Cookie encryption secret |
| `OAUTH2_PROXY_REDIS_PASSWORD` | oauth2-proxy | `redis-password` | Redis password |
| `DOPPLER_TOKEN` | external-secrets | `dopplerToken` | Doppler API token (bootstrap) |

---

## Architecture After Migration

```
Bitwarden Secrets Manager
  │
  ├─► ExternalSecret: cluster-secrets (namespace: argocd)
  │     Keys: private-domain, s3_endpoint
  │     → K8s Secret: cluster-secrets (argocd ns)
  │           mounted at /cluster-secrets/ in repo-server sidecars
  │           → argocd-secret-replacer secret --mount /cluster-secrets
  │           → resolves tokens in: hostnames, cert dnsNames, ConfigMap data,
  │                                 Middleware addresses, NFS server, values.yaml strings
  │
  └─► Per-app ExternalSecrets (in each app's own namespace)
        → K8s Secrets with S3 keys, API keys, passwords, etc.
        → consumed via secretKeyRef or mounted as env — no plugin involved
```

---

## Step-by-Step Implementation

### Phase 0 — Update ArgoCD infrastructure (must land first, before any app migration)

#### 0.1 — Update `sops-replacer-plugin.yaml`

**File:** `cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`

**Discover** — change trigger env var from `SOPS_SECRET_FILE` to `SECRET_PROVIDER`,
and remove the `find . -name '$ARGOCD_ENV_SOPS_SECRET_FILE'` check (no per-app file needed):

```yaml
# kustomize plugin discover:
- sh
- "-c"
- "[[ ! -z $ARGOCD_ENV_SECRET_PROVIDER ]] && find . -name 'kustomization.yaml'"

# helm plugin discover:
- sh
- "-c"
- "[[ ! -z $ARGOCD_ENV_SECRET_PROVIDER ]] && find . -name 'Chart.yaml'"
```

**Generate** — change both from `argocd-secret-replacer sops -f "$ARGOCD_ENV_SOPS_SECRET_FILE"` to:

```yaml
# kustomize:
kustomize build --enable-alpha-plugins . | argocd-secret-replacer secret --mount /cluster-secrets

# helm:
helm template --include-crds --release-name "$ARGOCD_APP_NAME" --namespace "$ARGOCD_APP_NAMESPACE" \
  --kube-version $KUBE_VERSION --api-versions $KUBE_API_VERSIONS . \
  | argocd-secret-replacer secret --mount /cluster-secrets
```

#### 0.2 — Update `argo-cd-repo-server-ksops-patch.yaml`

**File:** `cluster/apps/core/argocd/patches/argo-cd-repo-server-ksops-patch.yaml`

Changes:
1. **Add** volume `cluster-secrets` from the `cluster-secrets` K8s Secret
2. **Add** volumeMount `mountPath: /cluster-secrets` (readOnly: true) to both sidecar containers
3. **Remove** volume `sops-age`
4. **Remove** `SOPS_AGE_KEY_FILE` env var from both sidecar containers

```yaml
# ADD under spec.template.spec.volumes:
- name: cluster-secrets
  secret:
    secretName: cluster-secrets

# ADD to volumeMounts in BOTH sidecar containers:
- mountPath: /cluster-secrets
  name: cluster-secrets
  readOnly: true

# REMOVE from volumes:
- name: sops-age
  secret:
    secretName: sops-age

# REMOVE from BOTH sidecar containers env:
- name: SOPS_AGE_KEY_FILE
  value: /sops-age/key
```

#### 0.3 — Create `cluster-secrets` ExternalSecret

**New file:** `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cluster-secrets
  namespace: argocd
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: cluster-secrets
    creationPolicy: Owner
  data:
    - secretKey: private-domain
      remoteRef:
        key: "<BITWARDEN_UUID_PRIVATE_DOMAIN>" #gitleaks:allow #PRIVATE_DOMAIN
    - secretKey: s3_endpoint
      remoteRef:
        key: "<BITWARDEN_UUID_S3_ENDPOINT>" #gitleaks:allow #S3_ENDPOINT
```

Note: `s3_access_key` and `s3_secret_key` are NOT here — they appear only in Secret `data` fields
and go to per-app ExternalSecrets instead.

#### 0.4 — Add new resources to argocd kustomization

**File:** `cluster/apps/core/argocd/kustomization.yaml`

Add to `resources:`:
```yaml
- resources/cluster-secrets-externalsecret.yaml
- resources/repository-externalsecret.yaml
- resources/argocd-oidc-externalsecret.yaml
```

Remove from `resources:`:
```yaml
- resources/repository.yaml   # replaced by repository-externalsecret.yaml
```

Remove from `patches:`:
```yaml
- path: patches/argocd-secret.yaml   # replaced by argocd-oidc-externalsecret.yaml
```

#### 0.5 — Replace `repository.yaml` with ExternalSecret

**Delete:** `cluster/apps/core/argocd/resources/repository.yaml`

**Create:** `cluster/apps/core/argocd/resources/repository-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: private-repo-creds
  namespace: argocd
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: private-repo-creds
    creationPolicy: Owner
    template:
      metadata:
        labels:
          argocd.argoproj.io/secret-type: repo-creds
      data:
        password: '{{ `{{ .PASSWORD }}` }}'
        type: '{{ `{{ .TYPE }}` }}'
        url: '{{ `{{ .URL }}` }}'
        username: '{{ `{{ .USERNAME }}` }}'
  data:
    - secretKey: TYPE
      remoteRef:
        key: "<UUID>" #gitleaks:allow #ARGOCD_PRIVATE_REPO_TYPE
    - secretKey: URL
      remoteRef:
        key: "<UUID>" #gitleaks:allow #ARGOCD_PRIVATE_REPO_URL
    - secretKey: USERNAME
      remoteRef:
        key: "<UUID>" #gitleaks:allow #ARGOCD_PRIVATE_REPO_USERNAME
    - secretKey: PASSWORD
      remoteRef:
        key: "<UUID>" #gitleaks:allow #ARGOCD_PRIVATE_REPO_PASSWORD
```

#### 0.6 — Replace `argocd-secret.yaml` patch with ExternalSecret

**Delete:** `cluster/apps/core/argocd/patches/argocd-secret.yaml`

**Create:** `cluster/apps/core/argocd/resources/argocd-oidc-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: argocd-oidc-secret
  namespace: argocd
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: argocd-secret
    creationPolicy: Merge
  data:
    - secretKey: oidc.keycloak.clientSecret
      remoteRef:
        key: "<UUID>" #gitleaks:allow #ARGOCD_OIDC_KEYCLOAK_CLIENT_SECRET
```

Note: `creationPolicy: Merge` — ArgoCD manages `argocd-secret` itself; this only patches in the
OIDC key without taking ownership of the whole Secret.

#### 0.7 — Update argocd `app-config.yaml`

**File:** `cluster/apps/core/argocd/app-config.yaml`

```yaml
# Before:
plugin:
  env:
    - name: SOPS_SECRET_FILE
      value: secret.sec.yaml

# After:
plugin:
  env:
    - name: SECRET_PROVIDER
      value: cluster-secrets
```

The remaining tokens in argocd templates (`<secret:private-domain>` in `argocd-cm.yaml` and
`ingress.yaml`) are non-injectable fields — they continue to be resolved by the plugin from
`/cluster-secrets`. No changes needed to those template files.

**Delete:** `cluster/apps/core/argocd/secret.sec.yaml`

---

### Phase 1 — Apps using ONLY `private-domain` in non-injectable fields

These apps have `secret.sec.yaml` with only `private-domain`, used in `values.yaml` hostname
strings or template files. Pure env var rename + delete.

For each: change `app-config.yaml`, delete `secret.sec.yaml`. No template changes.

```yaml
# app-config.yaml change (identical for all):
plugin:
  env:
    - name: SECRET_PROVIDER   # was: SOPS_SECRET_FILE
      value: cluster-secrets  # was: secret.sec.yaml
```

**Apps:**
- `cluster/apps/core/rook-ceph/cluster/` (note: `appSubfolder: cluster` stays — only env var changes)
- `cluster/apps/default/gethomepage/`
- `cluster/apps/default/grocy/`
- `cluster/apps/default/hass-proxy/`
- `cluster/apps/default/open-webui/`
- `cluster/apps/default/qnap-proxy/`
- `cluster/apps/home-automation/ollama/`
- `cluster/apps/system/nfs-subdir-external-provisioner/`
- `cluster/apps/system/prometheus-stack/`
- `cluster/apps/system/traefik/`

---

### Phase 2 — Apps using `private-domain` + `s3_endpoint` in non-injectable fields,
###           AND `s3_access_key`/`s3_secret_key` in Secret data fields

The S3 access/secret keys appear only in `Secret` `data` fields (as `|base64` tokens) — they must
move to a per-app ExternalSecret. The `s3_endpoint` token appears in `values.yaml`
barmanObjectStore URL strings — it stays in the plugin via `cluster-secrets`.

For each app in this phase:
1. Change `app-config.yaml` env var
2. Replace `templates/secrets.yaml` (which used `<secret:s3_access_key|base64>` etc.) with an
   ExternalSecret
3. Remove `checksum/secrets` annotation from any Deployment/StatefulSet that referenced
   `secret.sec.yaml`
4. Delete `secret.sec.yaml`

#### `cluster/apps/default/gitea/`

**Delete:** `cluster/apps/default/gitea/templates/secrets.yaml`

**Create:** `cluster/apps/default/gitea/templates/s3-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gitea-s3-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: gitea-secrets
    creationPolicy: Owner
  data:
    - secretKey: S3_ACCESS_KEY_ID
      remoteRef:
        key: "<UUID>" #gitleaks:allow #S3_ACCESS_KEY
    - secretKey: S3_ACCESS_SECRET_KEY
      remoteRef:
        key: "<UUID>" #gitleaks:allow #S3_SECRET_KEY
```

Remove `checksum/secrets` annotation from the gitea Deployment (if present).
`values.yaml` keeps `<secret:private-domain>` and `<secret:s3_endpoint>` tokens — resolved by
plugin. `app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.

#### `cluster/apps/system/keycloak/`

**Delete:** `cluster/apps/system/keycloak/templates/secrets.yaml`

**Create:** `cluster/apps/system/keycloak/templates/s3-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: keycloak-s3-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: keycloak-secrets
    creationPolicy: Owner
  data:
    - secretKey: S3_ACCESS_KEY_ID
      remoteRef:
        key: "<UUID>" #gitleaks:allow #S3_ACCESS_KEY
    - secretKey: S3_ACCESS_SECRET_KEY
      remoteRef:
        key: "<UUID>" #gitleaks:allow #S3_SECRET_KEY
```

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.

#### `cluster/apps/home-automation/home-assistant/`

`templates/secrets.yaml` is actually an ExternalSecret (ESO resource) that mixes
`<secret:s3_access_key|base64>` sops-replacer tokens inside ESO template expressions — an
anti-pattern. Fix by pulling S3 keys directly from Bitwarden in the ExternalSecret `data[]`
alongside existing Doppler-sourced keys.

**Modify:** `cluster/apps/home-automation/home-assistant/templates/secrets.yaml`

- Remove `<secret:s3_access_key|base64>` and `<secret:s3_secret_key|base64>` tokens from the
  ESO template `data` section
- Add direct Bitwarden `remoteRef` entries for S3 keys to the ExternalSecret `data[]`
- Remove `<secret:private-domain>` from `SECRET_EXTERNAL_URL` ESO template value; add
  `PRIVATE_DOMAIN` as a Bitwarden data entry and use `{{ .PRIVATE_DOMAIN }}` ESO expression

Result: this ExternalSecret is fully self-contained — no sops-replacer tokens remain in it.

Since all tokens are removed from templates, **the plugin is no longer needed for home-assistant**.
Remove the `plugin` block from `app-config.yaml` entirely.
Delete `secret.sec.yaml`.

---

### Phase 3 — Apps with ONLY app-specific Secret data fields (no non-injectable tokens)

These apps need per-app ExternalSecrets. After migration, no `<secret:>` tokens remain in any
template — the plugin block is removed entirely from `app-config.yaml`.

#### `cluster/apps/system/cert-manager/`

The `<secret:email>` token appears in `ClusterIssuer` `spec.acme.email` — a non-injectable field.
The `<secret:api-token|base64>` token appears in a `Secret` `data` field.

**Two separate resources needed:**

**Create:** `cluster/apps/system/cert-manager/templates/api-token-externalsecret.yaml`
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: cert-manager-api-token
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: cert-manager-secret
    creationPolicy: Owner
  data:
    - secretKey: api-token
      remoteRef:
        key: "<UUID>" #gitleaks:allow #CERT_MANAGER_API_TOKEN
```

The `<secret:email>` token in `ClusterIssuer` is non-injectable — it must stay as a plugin token.
Add `CERT_MANAGER_EMAIL` to `cluster-secrets` ExternalSecret (add to 0.3):

```yaml
# Add to cluster-secrets ExternalSecret data[]:
- secretKey: email
  remoteRef:
    key: "<UUID>" #gitleaks:allow #CERT_MANAGER_EMAIL
```

Keep `plugin` block in `app-config.yaml` (plugin still needed for `<secret:email>` in
ClusterIssuer).
Delete `secret.sec.yaml`.

#### `cluster/apps/system/external-secrets/`

`dopplerToken` appears in a `Secret` `data` field — pure ESO replacement.
The existing `bitwarden-access-token` secret is manually bootstrapped. Do the same for
`doppler-token-auth-api`: bootstrap manually once, then keep refreshed via ExternalSecret.

**Modify:** `cluster/apps/system/external-secrets/templates/secret.yaml`

Replace the `doppler-token-auth-api` Secret (which uses `<secret:dopplerToken|base64>`) with an
ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: doppler-token
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: doppler-token-auth-api
    creationPolicy: Owner
  data:
    - secretKey: dopplerToken
      remoteRef:
        key: "<UUID>" #gitleaks:allow #DOPPLER_TOKEN
```

Remove `plugin` block from `app-config.yaml`. Delete `secret.sec.yaml`.

#### `cluster/apps/system/oauth2-proxy/`

`<secret:client-id|base64>` etc. are in `templates/secret.yaml` (Secret data fields) →
ExternalSecret. But `<secret:private-domain>` appears in `templates/forward-auth-middleware.yaml`
(Middleware `spec.forwardAuth.address`) and in `values.yaml` hostname strings → non-injectable,
plugin still needed.

**Delete:** `cluster/apps/system/oauth2-proxy/templates/secret.yaml`

**Create:** `cluster/apps/system/oauth2-proxy/templates/credentials-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: oauth-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: oauth-secret
    creationPolicy: Owner
  data:
    - secretKey: client-id
      remoteRef:
        key: "<UUID>" #gitleaks:allow #OAUTH2_PROXY_CLIENT_ID
    - secretKey: client-secret
      remoteRef:
        key: "<UUID>" #gitleaks:allow #OAUTH2_PROXY_CLIENT_SECRET
    - secretKey: cookie-secret
      remoteRef:
        key: "<UUID>" #gitleaks:allow #OAUTH2_PROXY_COOKIE_SECRET
    - secretKey: redis-password
      remoteRef:
        key: "<UUID>" #gitleaks:allow #OAUTH2_PROXY_REDIS_PASSWORD
```

Keep `plugin` block in `app-config.yaml` (plugin still needed for `private-domain` in
Middleware and `values.yaml`). Change env var to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

#### `cluster/apps/system/dyndns/`

All dyndns tokens appear in a `Secret` `stringData` field (embedded YAML config). ExternalSecret
with ESO template to render the embedded YAML.

**Delete:** existing `resources/secret.yaml`

**Create:** `cluster/apps/system/dyndns/templates/externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: dyndns-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: dyndns-secret
    creationPolicy: Owner
    template:
      data:
        config.yaml: |
          {{ `{{ .CONFIG }}` }}
  data:
    - secretKey: TOKEN
      remoteRef:
        key: "<UUID>" #gitleaks:allow #DYNDNS_TOKEN
    - secretKey: DOMAIN_COM_ZONE
      remoteRef:
        key: "<UUID>" #gitleaks:allow #DYNDNS_DOMAIN_COM_ZONE
    - secretKey: DOMAIN_COM_NAME
      remoteRef:
        key: "<UUID>" #gitleaks:allow #DYNDNS_DOMAIN_COM_NAME
    - secretKey: DOMAIN_CLOUD_ZONE
      remoteRef:
        key: "<UUID>" #gitleaks:allow #DYNDNS_DOMAIN_CLOUD_ZONE
    - secretKey: DOMAIN_CLOUD_NAME
      remoteRef:
        key: "<UUID>" #gitleaks:allow #DYNDNS_DOMAIN_CLOUD_NAME
```

Note: The `config.yaml` embedded YAML must be constructed via ESO template using the individual
keys. Inspect the existing `resources/secret.yaml` `stringData.config.yaml` content to determine
the exact YAML structure needed in the template.

Remove `plugin` block from `app-config.yaml`. Delete `secret.sec.yaml`.

---

### Phase 4 — Apps with mixed non-injectable tokens + app-specific Secret data tokens

#### `cluster/apps/default/litellm/`

Token analysis:
- `<secret:masterkey>` in `values.yaml` (`litellm-helm.masterkey`) — Helm value string,
  non-injectable → stays in plugin via `cluster-secrets`
- `<secret:s3_endpoint>` in `values.yaml` — non-injectable → stays in plugin via `cluster-secrets`
- `<secret:s3_access_key|base64>` in `templates/secrets.yaml` — Secret data → ExternalSecret
- `<secret:s3_secret_key|base64>` in `templates/secrets.yaml` — Secret data → ExternalSecret
- `<secret:anthropic_api_key|base64>` in `templates/secrets.yaml` — Secret data → ExternalSecret
- `<secret:openai_api_key|base64>` in `templates/secrets.yaml` — Secret data → ExternalSecret
- `<secret:private-domain>` in `values.yaml` — non-injectable → stays in plugin

Add `masterkey` to `cluster-secrets` ExternalSecret (update 0.3):
```yaml
- secretKey: masterkey
  remoteRef:
    key: "<UUID>" #gitleaks:allow #LITELLM_MASTER_KEY
```

**Delete:** `cluster/apps/default/litellm/templates/secrets.yaml`

**Create:** `cluster/apps/default/litellm/templates/api-externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: litellm-secrets
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: litellm-secrets
    creationPolicy: Owner
  data:
    - secretKey: S3_ACCESS_KEY_ID
      remoteRef:
        key: "<UUID>" #gitleaks:allow #S3_ACCESS_KEY
    - secretKey: S3_ACCESS_SECRET_KEY
      remoteRef:
        key: "<UUID>" #gitleaks:allow #S3_SECRET_KEY
    - secretKey: ANTHROPIC_API_KEY
      remoteRef:
        key: "<UUID>" #gitleaks:allow #LITELLM_ANTHROPIC_API_KEY
    - secretKey: OPENAI_API_KEY
      remoteRef:
        key: "<UUID>" #gitleaks:allow #LITELLM_OPENAI_API_KEY
    - secretKey: LITELLM_MASTER_KEY
      remoteRef:
        key: "<UUID>" #gitleaks:allow #LITELLM_MASTER_KEY
```

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets` (plugin still needed for
`private-domain`, `s3_endpoint`, `masterkey` in `values.yaml`).
Delete `secret.sec.yaml`.

#### `cluster/apps/default/n8n/`

- `<secret:encryption-key>` in `values.yaml` env value — non-injectable → add to `cluster-secrets`
- `<secret:private-domain>` in `values.yaml` hostnames — non-injectable → plugin
- S3 keys: check if present in a Secret data template → ExternalSecret if so

Add `encryption-key` to `cluster-secrets` ExternalSecret (update 0.3):
```yaml
- secretKey: encryption-key
  remoteRef:
    key: "<UUID>" #gitleaks:allow #N8N_ENCRYPTION_KEY
```

If `templates/secrets.yaml` exists and uses `s3_access_key|base64`:
Delete it and create `templates/s3-externalsecret.yaml` (same pattern as gitea).

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

#### `cluster/apps/default/jellyfin/`

- `<secret:jellyfin-service-ip>` in `values.yaml` — this is a LoadBalancer IP, not a secret.
  **Hardcode** the actual IP value directly in `values.yaml`. Remove from `secret.sec.yaml`.
- `<secret:private-domain>` in `values.yaml` — non-injectable → plugin

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

#### `cluster/apps/default/botkube/`

- `<secret:discord_botid>`, `<secret:discord_token>`, `<secret:discord_channel>` appear in
  `values.yaml` as Helm values — non-injectable → add to `cluster-secrets`

Add discord keys to `cluster-secrets` ExternalSecret (update 0.3):
```yaml
- secretKey: discord_botid
  remoteRef:
    key: "<UUID>" #gitleaks:allow #BOTKUBE_DISCORD_BOTID
- secretKey: discord_token
  remoteRef:
    key: "<UUID>" #gitleaks:allow #BOTKUBE_DISCORD_TOKEN
- secretKey: discord_channel
  remoteRef:
    key: "<UUID>" #gitleaks:allow #BOTKUBE_DISCORD_CHANNEL
```

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

#### `cluster/apps/default/nfs-mounts/`

- `<secret:private-domain>` in PersistentVolume `spec.nfs.server` — non-injectable → plugin

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

#### `cluster/apps/games/minecraft-bedrock/`

- `<secret:ops>` and `<secret:whitelistUsers>` in `values.yaml` — Helm values, non-injectable
  → add to `cluster-secrets`
- `<secret:private-domain>` in `values.yaml` — non-injectable → plugin

Add minecraft keys to `cluster-secrets` ExternalSecret (update 0.3):
```yaml
- secretKey: ops
  remoteRef:
    key: "<UUID>" #gitleaks:allow #MINECRAFT_OPS
- secretKey: whitelistUsers
  remoteRef:
    key: "<UUID>" #gitleaks:allow #MINECRAFT_WHITELIST_USERS
```

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

#### `cluster/apps/games/vintagestory/`

- `<secret:world-password>` — check where it appears:
  - If in `values.yaml` or template non-Secret field → add to `cluster-secrets`
  - If in a Secret `data` field → ExternalSecret
- `<secret:private-domain>` in `values.yaml` — plugin

`app-config.yaml`: change to `SECRET_PROVIDER: cluster-secrets`.
Delete `secret.sec.yaml`.

---

### Phase 5 — New app: `envoy-gateweay`

This app uses `<secret:private-domain>` in `templates/cert.yaml` (Certificate `spec.commonName`,
`spec.dnsNames[]`) — non-injectable fields. Plugin required.

**Create/update:** `cluster/apps/system/envoy-gateweay/app-config.yaml`

```yaml
plugin:
  env:
    - name: SECRET_PROVIDER
      value: cluster-secrets
```

No `secret.sec.yaml` ever needed — it never existed for this app.

---

### Phase 6 — Remove SOPS infrastructure (after ALL apps migrated)

1. **Cluster**: `kubectl delete secret sops-age -n argocd`
2. **Devcontainer secret**: remove `SOPS_AGE_KEY` from devcontainer secrets
3. **`.sops.yaml`**: delete or archive — no longer used
4. **`.pre-commit-config.yaml`**: remove `sops-check` hook
5. **`CLAUDE.md`**: update secrets management section

---

## Final `cluster-secrets` key list

After applying all per-app decisions above, the complete set of keys in `cluster-secrets` is:

| Key | Used by |
|-----|---------|
| `private-domain` | all apps with hostname/cert/ConfigMap/Middleware/values.yaml tokens |
| `s3_endpoint` | gitea, keycloak, home-assistant, litellm (barmanObjectStore URL) |
| `email` | cert-manager ClusterIssuer |
| `masterkey` | litellm values.yaml |
| `encryption-key` | n8n values.yaml |
| `discord_botid` | botkube values.yaml |
| `discord_token` | botkube values.yaml |
| `discord_channel` | botkube values.yaml |
| `ops` | minecraft-bedrock values.yaml |
| `whitelistUsers` | minecraft-bedrock values.yaml |
| `world-password` | vintagestory (if in non-injectable field — verify) |

Keys that are NOT in `cluster-secrets` (go to per-app ExternalSecrets instead):
- `s3_access_key`, `s3_secret_key` — only ever in Secret `data` fields
- All other credentials (API keys, passwords, client secrets)

---

## Important Notes for the Agent

1. **Do NOT add actual secret values** to any file. Bitwarden UUIDs must be filled in by the
   operator. Leave `"<UUID>"` or `"<BITWARDEN_UUID_*>"` placeholders in `remoteRef.key` fields.

2. **Verify token field location before deciding**: for every `<secret:key>` token, check whether
   the surrounding YAML is a `Secret` `data`/`stringData` field (→ ExternalSecret) or any other
   field (→ `cluster-secrets` + plugin). Do not assume — read the file.

3. **checksum annotation**: any file with
   `checksum/secrets: {{ .Files.Get "secret.sec.yaml" | sha256sum }}` must have that annotation
   removed. Helm errors if the referenced file doesn't exist.

4. **Phase 0 must be committed and ArgoCD synced before phases 1–5**. The new plugin command
   must be live before any app switches its `app-config.yaml`.

5. **ExternalSecret `creationPolicy: Merge`** only for targeting existing system-managed Secrets
   (like `argocd-secret`). Use `creationPolicy: Owner` for all new secrets.

6. **`bitwarden` ClusterSecretStore** is cluster-scoped — ExternalSecrets in any namespace can
   reference it with `kind: ClusterSecretStore`.

7. **home-assistant `templates/secrets.yaml`** is already an ExternalSecret resource (ESO), not
   a plain K8s Secret — be careful not to wrap it in another ExternalSecret. Modify it in-place.

8. **dyndns** uses embedded YAML in `stringData.config.yaml`. The ESO template must reconstruct
   the exact same YAML structure. Read the original decrypted config carefully before templating.
