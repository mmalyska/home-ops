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
- `cluster-secrets` contains only keys that appear in non-injectable fields
- `s3_access_key` and `s3_secret_key` appear **only** in `Secret` `data` fields → per-app
  ExternalSecrets, NOT `cluster-secrets`
- App-specific credentials (API keys, passwords, tokens) always go to per-app ExternalSecrets

## Migration Strategy: Gradual, Non-Destructive

The migration runs in three tracks that can be executed independently and in any order after
Phase 0:

**Track A — Plugin infrastructure update** (Phase 0): Add a *second* plugin (`SECRET_PROVIDER`
trigger) alongside the existing SOPS plugin. Both run in parallel. Apps migrate one by one by
switching their trigger env var. The old SOPS plugin is only removed in the final cleanup phase
once all apps have migrated.

**Track B — Per-app migration**: Each app is migrated independently. An app is not touched until
its Bitwarden secrets are ready. Rolling back a single app is as simple as reverting its
`app-config.yaml`.

**Track C — SOPS cleanup** (final): Remove the old plugin and SOPS infrastructure only after
every app has switched to `SECRET_PROVIDER`.

At no point are all apps broken simultaneously. The cluster remains fully functional throughout.

---

## Prerequisites

- The `argocd-secret-replacer` plugin must already have the new `secret --mount` verb implemented
  and released. See `.plans/argocd-secret-replacer-k8s-provider.md`.
- The `bitwarden` ClusterSecretStore is already working (cloudflare-dns, adguard-dns, cloudflared
  all use it successfully).
- Bitwarden secrets for a specific app must be added **before** migrating that app — not all
  upfront. See per-app sections for which secrets each app needs.

---

## Bitwarden Secrets Reference

Secrets must be added to Bitwarden Secrets Manager in project
`422f340a-6eb8-4a4f-90d1-b3fe00d00d76`. Note the UUID of each for use in ExternalSecret
`remoteRef.key` fields. Mark UUIDs with `#gitleaks:allow #KEY_NAME` comments in YAML.

### Global — go into `cluster-secrets` (used in non-injectable fields only)

Add these to Bitwarden before starting Phase 0, as they are needed by the very first migrated app:

| Key name in Secret | Bitwarden key name | Used in |
|--------------------|--------------------|---------|
| `private-domain` | `PRIVATE_DOMAIN` | hostnames, cert dnsNames, ConfigMap, Middleware, values.yaml |
| `s3_endpoint` | `S3_ENDPOINT` | `values.yaml` barmanObjectStore.endpointURL strings |
| `email` | `CERT_MANAGER_EMAIL` | cert-manager ClusterIssuer |
| `masterkey` | `LITELLM_MASTER_KEY` | litellm values.yaml |
| `encryption-key` | `N8N_ENCRYPTION_KEY` | n8n values.yaml |
| `discord_botid` | `BOTKUBE_DISCORD_BOTID` | botkube values.yaml |
| `discord_token` | `BOTKUBE_DISCORD_TOKEN` | botkube values.yaml |
| `discord_channel` | `BOTKUBE_DISCORD_CHANNEL` | botkube values.yaml |
| `ops` | `MINECRAFT_OPS` | minecraft-bedrock values.yaml |
| `whitelistUsers` | `MINECRAFT_WHITELIST_USERS` | minecraft-bedrock values.yaml |
| `world-password` | `VINTAGESTORY_WORLD_PASSWORD` | vintagestory values.yaml (verify field) |

### Per-app — add to Bitwarden just before migrating each app

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
  │     Keys: private-domain, s3_endpoint, email, masterkey, encryption-key,
  │           discord_*, ops, whitelistUsers, world-password
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

## Phase 0 — Extend ArgoCD infrastructure (non-breaking, must land first)

This phase **adds** new plugin definitions alongside the existing ones. No existing app is changed.
Both `SOPS_SECRET_FILE` (old) and `SECRET_PROVIDER` (new) plugins run simultaneously. Apps continue
to use SOPS until they are individually migrated.

### 0.1 — Add new plugin definitions to `sops-replacer-plugin.yaml`

**File:** `cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`

**ADD** two new ConfigMap entries alongside the existing ones (do not modify or remove the existing
`sops-replacer-plugin-kustomize.yaml` and `sops-replacer-plugin-helm.yaml` entries):

```yaml
# ADD these two new entries to the ConfigMap data:
  secret-replacer-plugin-kustomize.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: secret-replacer-plugin-kustomize
    spec:
      version: v1.0
      allowConcurrency: true
      discover:
        find:
          command:
            - sh
            - "-c"
            - "[[ ! -z $ARGOCD_ENV_SECRET_PROVIDER ]] && find . -name 'kustomization.yaml'"
      generate:
        command:
          - bash
          - "-c"
          - |-
            kustomize build --enable-alpha-plugins . | argocd-secret-replacer secret --mount /cluster-secrets
      lockRepo: false
  secret-replacer-plugin-helm.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: secret-replacer-plugin-helm
    spec:
      version: v1.0
      allowConcurrency: true
      discover:
        find:
          command:
            - sh
            - "-c"
            - "[[ ! -z $ARGOCD_ENV_SECRET_PROVIDER ]] && find . -name 'Chart.yaml'"
      init:
        command:
          - bash
          - "-c"
          - helm dependency update
      generate:
        command:
          - bash
          - "-c"
          - |-
            helm template --include-crds --release-name "$ARGOCD_APP_NAME" --namespace "$ARGOCD_APP_NAMESPACE" --kube-version $KUBE_VERSION --api-versions $KUBE_API_VERSIONS . | argocd-secret-replacer secret --mount /cluster-secrets
      lockRepo: false
```

### 0.2 — Add new sidecar containers to `argo-cd-repo-server-ksops-patch.yaml`

**File:** `cluster/apps/core/argocd/patches/argo-cd-repo-server-ksops-patch.yaml`

**ADD** two new sidecar containers (alongside the existing `sops-replacer-plugin-kustomize` and
`sops-replacer-plugin-helm` — do not modify or remove those):

```yaml
# ADD to spec.template.spec.containers:
- name: secret-replacer-plugin-kustomize
  command: [/var/run/argocd/argocd-cmp-server]
  image: ghcr.io/mmalyska/argocd-secret-replacer:rolling@sha256:<NEW_DIGEST>
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
  resources:
    limits:
      cpu: 250m
      memory: 512Mi
    requests:
      cpu: 10m
      memory: 16Mi
  volumeMounts:
    - mountPath: /var/run/argocd
      name: var-files
    - mountPath: /home/argocd/cmp-server/plugins
      name: plugins
    - mountPath: /tmp
      name: tmp-sops-replacer-plugin
    - mountPath: /home/argocd/cmp-server/config/plugin.yaml
      name: sops-replacer-plugin
      subPath: secret-replacer-plugin-kustomize.yaml
    - mountPath: /cluster-secrets
      name: cluster-secrets
      readOnly: true
- name: secret-replacer-plugin-helm
  command: [/var/run/argocd/argocd-cmp-server]
  image: ghcr.io/mmalyska/argocd-secret-replacer:rolling@sha256:<NEW_DIGEST>
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 10m
      memory: 16Mi
  env:
    - name: HELM_CACHE_HOME
      value: /helm-working-dir
    - name: HELM_CONFIG_HOME
      value: /helm-working-dir
    - name: HELM_DATA_HOME
      value: /helm-working-dir
  volumeMounts:
    - mountPath: /var/run/argocd
      name: var-files
    - mountPath: /home/argocd/cmp-server/plugins
      name: plugins
    - mountPath: /tmp
      name: tmp-sops-replacer-plugin
    - mountPath: /home/argocd/cmp-server/config/plugin.yaml
      name: sops-replacer-plugin
      subPath: secret-replacer-plugin-helm.yaml
    - mountPath: /cluster-secrets
      name: cluster-secrets
      readOnly: true
    - name: helm-working-dir
      mountPath: /helm-working-dir

# ADD to spec.template.spec.volumes (alongside existing sops-age volume):
- name: cluster-secrets
  secret:
    secretName: cluster-secrets
```

Note: The image digest `<NEW_DIGEST>` must be the digest of the new plugin release that includes
the `secret --mount` verb. Update the existing SOPS sidecar digests to the same release at the
same time so all four sidecars run the same image version.

### 0.3 — Create `cluster-secrets` ExternalSecret

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
    - secretKey: email
      remoteRef:
        key: "<BITWARDEN_UUID_CERT_MANAGER_EMAIL>" #gitleaks:allow #CERT_MANAGER_EMAIL
    - secretKey: masterkey
      remoteRef:
        key: "<BITWARDEN_UUID_LITELLM_MASTER_KEY>" #gitleaks:allow #LITELLM_MASTER_KEY
    - secretKey: encryption-key
      remoteRef:
        key: "<BITWARDEN_UUID_N8N_ENCRYPTION_KEY>" #gitleaks:allow #N8N_ENCRYPTION_KEY
    - secretKey: discord_botid
      remoteRef:
        key: "<BITWARDEN_UUID_BOTKUBE_DISCORD_BOTID>" #gitleaks:allow #BOTKUBE_DISCORD_BOTID
    - secretKey: discord_token
      remoteRef:
        key: "<BITWARDEN_UUID_BOTKUBE_DISCORD_TOKEN>" #gitleaks:allow #BOTKUBE_DISCORD_TOKEN
    - secretKey: discord_channel
      remoteRef:
        key: "<BITWARDEN_UUID_BOTKUBE_DISCORD_CHANNEL>" #gitleaks:allow #BOTKUBE_DISCORD_CHANNEL
    - secretKey: ops
      remoteRef:
        key: "<BITWARDEN_UUID_MINECRAFT_OPS>" #gitleaks:allow #MINECRAFT_OPS
    - secretKey: whitelistUsers
      remoteRef:
        key: "<BITWARDEN_UUID_MINECRAFT_WHITELIST_USERS>" #gitleaks:allow #MINECRAFT_WHITELIST_USERS
    - secretKey: world-password
      remoteRef:
        key: "<BITWARDEN_UUID_VINTAGESTORY_WORLD_PASSWORD>" #gitleaks:allow #VINTAGESTORY_WORLD_PASSWORD
```

### 0.4 — Add new resources to argocd kustomization

**File:** `cluster/apps/core/argocd/kustomization.yaml`

Add to `resources:` only:
```yaml
- resources/cluster-secrets-externalsecret.yaml
```

All existing resources and patches remain unchanged.

### ✓ Verification after Phase 0

After ArgoCD syncs the `argocd` app:
- `kubectl get secret cluster-secrets -n argocd` should show all keys populated by ESO
- `kubectl get pods -n argocd` repo-server pod should have 4 CMP sidecar containers (2 old + 2 new)
- All existing apps continue working unchanged via the old SOPS plugin

---

## Per-App Migration

Each app below is fully self-contained and can be done in any order. For each app:
1. Add the required Bitwarden secrets (listed per app)
2. Make the file changes
3. Commit and let ArgoCD sync — verify the app works
4. Only then proceed to the next app

The trigger for the new plugin is `SECRET_PROVIDER: cluster-secrets` instead of
`SOPS_SECRET_FILE: secret.sec.yaml`. When an app has both a `secret.sec.yaml` and the new env var,
ArgoCD will use the new plugin (discover picks `SECRET_PROVIDER` first). The old `secret.sec.yaml`
file can be deleted in the same commit.

---

### App: `argocd` (core)

**Bitwarden secrets needed first:**
- `ARGOCD_PRIVATE_REPO_TYPE`, `ARGOCD_PRIVATE_REPO_URL`, `ARGOCD_PRIVATE_REPO_USERNAME`,
  `ARGOCD_PRIVATE_REPO_PASSWORD`, `ARGOCD_OIDC_KEYCLOAK_CLIENT_SECRET`
- `PRIVATE_DOMAIN` (already added in Phase 0)

**Changes:**

`cluster/apps/core/argocd/app-config.yaml`:
```yaml
# Change env var:
- name: SECRET_PROVIDER    # was: SOPS_SECRET_FILE
  value: cluster-secrets   # was: secret.sec.yaml
```

`cluster/apps/core/argocd/kustomization.yaml`:
- Add to `resources:`: `resources/repository-externalsecret.yaml`
- Add to `resources:`: `resources/argocd-oidc-externalsecret.yaml`
- Remove from `resources:`: `resources/repository.yaml`
- Remove from `patches:`: `path: patches/argocd-secret.yaml`

**Create** `cluster/apps/core/argocd/resources/repository-externalsecret.yaml`:
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

**Create** `cluster/apps/core/argocd/resources/argocd-oidc-externalsecret.yaml`:
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

**Delete:** `resources/repository.yaml`, `patches/argocd-secret.yaml`, `secret.sec.yaml`

Templates `patches/argocd-cm.yaml` and `resources/ingress.yaml` keep their `<secret:private-domain>`
tokens unchanged — resolved by the new plugin from `/cluster-secrets`.

---

### App: `rook-ceph/cluster` (core)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets` from Phase 0)

**Changes:**

`cluster/apps/core/rook-ceph/cluster/app-config.yaml`:
```yaml
- name: SECRET_PROVIDER
  value: cluster-secrets
```

**Delete:** `cluster/apps/core/rook-ceph/cluster/secret.sec.yaml`

---

### App: `gethomepage` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `grocy` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `hass-proxy` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `open-webui` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `qnap-proxy` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `nfs-mounts` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `jellyfin` (default)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

**Changes:**

`values.yaml`:
- Replace `<secret:jellyfin-service-ip>` with the hardcoded IP value (`192.168.48.XX`) —
  this is a LoadBalancer IP, not a secret. Read the current SOPS-decrypted value first to confirm
  the IP, then hardcode it.

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `botkube` (default)

**Bitwarden secrets needed first:** `BOTKUBE_DISCORD_BOTID`, `BOTKUBE_DISCORD_TOKEN`,
`BOTKUBE_DISCORD_CHANNEL` (all already in `cluster-secrets` from Phase 0)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

No template changes — discord tokens in `values.yaml` are non-injectable Helm values, resolved
by the plugin from `cluster-secrets`.

---

### App: `gitea` (default)

**Bitwarden secrets needed first:** `S3_ACCESS_KEY`, `S3_SECRET_KEY` (per-app);
`PRIVATE_DOMAIN`, `S3_ENDPOINT` (already in `cluster-secrets`)

**Changes:**

**Delete:** `cluster/apps/default/gitea/templates/secrets.yaml`

**Create:** `cluster/apps/default/gitea/templates/s3-externalsecret.yaml`:
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

Remove `checksum/secrets: {{ .Files.Get "secret.sec.yaml" | sha256sum }}` annotation from any
Deployment/StatefulSet template that has it.

`values.yaml` keeps `<secret:private-domain>` and `<secret:s3_endpoint>` tokens — resolved by
plugin. `app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `n8n` (default)

**Bitwarden secrets needed first:** `N8N_ENCRYPTION_KEY` (already in `cluster-secrets`);
`S3_ACCESS_KEY`, `S3_SECRET_KEY` (per-app, if S3 templates exist — verify)

**Changes:**

`encryption-key` is already in `cluster-secrets` — plugin resolves it from `values.yaml`.

If `templates/secrets.yaml` exists with `<secret:s3_access_key|base64>`:
- **Delete** it
- **Create** `templates/s3-externalsecret.yaml` (same pattern as gitea above)

Remove any `checksum/secrets` annotation referencing `secret.sec.yaml`.

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `litellm` (default)

**Bitwarden secrets needed first:** `LITELLM_MASTER_KEY` (already in `cluster-secrets`);
`S3_ACCESS_KEY`, `S3_SECRET_KEY`, `LITELLM_ANTHROPIC_API_KEY`, `LITELLM_OPENAI_API_KEY` (per-app)

**Changes:**

`<secret:masterkey>` in `values.yaml` → resolved from `cluster-secrets` by plugin. No change to
`values.yaml` needed.

**Delete:** `cluster/apps/default/litellm/templates/secrets.yaml`

**Create:** `cluster/apps/default/litellm/templates/api-externalsecret.yaml`:
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

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `ollama` (home-automation)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `home-assistant` (home-automation)

**Bitwarden secrets needed first:** `S3_ACCESS_KEY`, `S3_SECRET_KEY`, `PRIVATE_DOMAIN`
(note: `PRIVATE_DOMAIN` comes from Bitwarden directly into the ESO, not from `cluster-secrets`)

**Special case:** `templates/secrets.yaml` is already an ESO `ExternalSecret` resource (not a plain
K8s Secret) that currently mixes sops-replacer tokens inside ESO template expressions. Modify it
in-place — do not wrap it in another ExternalSecret.

**Modify** `cluster/apps/home-automation/home-assistant/templates/secrets.yaml`:
- Remove `<secret:s3_access_key|base64>` and `<secret:s3_secret_key|base64>` from the ESO
  `spec.target.template.data` section
- Add direct Bitwarden `remoteRef` entries for `S3_ACCESS_KEY_ID` and `S3_ACCESS_SECRET_KEY`
  to the ExternalSecret `spec.data[]`
- Remove `<secret:private-domain>` from the `SECRET_EXTERNAL_URL` template value; add
  `PRIVATE_DOMAIN` as a Bitwarden data entry and reference it as `{{ .PRIVATE_DOMAIN }}` in
  the ESO template expression

After this change, no sops-replacer tokens remain in any home-assistant template.

**Remove** the `plugin` block entirely from `app-config.yaml` (no tokens remain).
**Delete** `secret.sec.yaml`.

---

### App: `minecraft-bedrock` (games)

**Bitwarden secrets needed first:** `MINECRAFT_OPS`, `MINECRAFT_WHITELIST_USERS` (already in
`cluster-secrets`); `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `vintagestory` (games)

**Bitwarden secrets needed first:** `VINTAGESTORY_WORLD_PASSWORD` (already in `cluster-secrets`
if non-injectable; otherwise per-app ExternalSecret if in Secret data — verify first);
`PRIVATE_DOMAIN` (already in `cluster-secrets`)

Before making changes, read `templates/` files to confirm where `world-password` is used:
- If used in a `values.yaml` string or non-Secret template field → already in `cluster-secrets`,
  just change env var
- If used in a `Secret` `data` field → create a per-app ExternalSecret for it instead

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `nfs-subdir-external-provisioner` (system)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `prometheus-stack` (system)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `traefik` (system)

**Bitwarden secrets needed first:** `PRIVATE_DOMAIN` (already in `cluster-secrets`)

`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `keycloak` (system)

**Bitwarden secrets needed first:** `S3_ACCESS_KEY`, `S3_SECRET_KEY` (per-app);
`PRIVATE_DOMAIN`, `S3_ENDPOINT` (already in `cluster-secrets`)

**Changes:**

**Delete:** `cluster/apps/system/keycloak/templates/secrets.yaml`

**Create:** `cluster/apps/system/keycloak/templates/s3-externalsecret.yaml`:
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

Remove any `checksum/secrets` annotation referencing `secret.sec.yaml`.
`app-config.yaml`: change env var. **Delete** `secret.sec.yaml`.

---

### App: `cert-manager` (system)

**Bitwarden secrets needed first:** `CERT_MANAGER_API_TOKEN` (per-app);
`CERT_MANAGER_EMAIL` (already in `cluster-secrets` as key `email`)

**Changes:**

`<secret:email>` in `ClusterIssuer` `spec.acme.email` is non-injectable — resolved by plugin
from `cluster-secrets`. No change to the ClusterIssuer file.

**Create:** `cluster/apps/system/cert-manager/templates/api-token-externalsecret.yaml`:
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

Keep `plugin` block in `app-config.yaml` (plugin still needed for `<secret:email>` in ClusterIssuer).
Change env var to `SECRET_PROVIDER: cluster-secrets`. **Delete** `secret.sec.yaml`.

---

### App: `oauth2-proxy` (system)

**Bitwarden secrets needed first:** `OAUTH2_PROXY_CLIENT_ID`, `OAUTH2_PROXY_CLIENT_SECRET`,
`OAUTH2_PROXY_COOKIE_SECRET`, `OAUTH2_PROXY_REDIS_PASSWORD` (per-app);
`PRIVATE_DOMAIN` (already in `cluster-secrets`)

**Changes:**

`<secret:private-domain>` in `templates/forward-auth-middleware.yaml` and `values.yaml` →
non-injectable, plugin still needed.

**Delete:** `cluster/apps/system/oauth2-proxy/templates/secret.yaml`

**Create:** `cluster/apps/system/oauth2-proxy/templates/credentials-externalsecret.yaml`:
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

`app-config.yaml`: change env var to `SECRET_PROVIDER: cluster-secrets` (plugin still needed).
**Delete** `secret.sec.yaml`.

---

### App: `dyndns` (system)

**Bitwarden secrets needed first:** all 5 dyndns keys (per-app)

**Changes:**

All dyndns tokens appear in a `Secret` `stringData.config.yaml` (embedded YAML) — pure ESO.

Before implementing: read the existing `resources/secret.yaml` (after SOPS decryption) to confirm
the exact YAML structure of `stringData.config.yaml`. The ESO template must reproduce it exactly.

**Delete:** existing `resources/secret.yaml` (the SOPS-based Secret)

**Create:** `cluster/apps/system/dyndns/templates/externalsecret.yaml`:
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
          {{ `{{ .CONFIG_YAML }}` }}
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

Note: The embedded `config.yaml` content structure must be reconstructed in the ESO template.
Either store the full rendered config as a single Bitwarden secret (`CONFIG_YAML`), or build
it from individual keys using ESO template expressions. Choose based on the actual config format.

**Remove** `plugin` block from `app-config.yaml`. **Delete** `secret.sec.yaml`.

---

### App: `external-secrets` (system)

**Bitwarden secrets needed first:** `DOPPLER_TOKEN` (per-app)

**Changes:**

`dopplerToken` appears in a `Secret` `data` field — replace with ESO ExternalSecret. Bootstrap
order: the `bitwarden-access-token` secret is manually provisioned at cluster bootstrap (already
done — it's in `ignoreDifferences`). The `doppler-token-auth-api` secret must also be manually
provisioned once on bootstrap, then kept fresh by ESO.

**Modify** `cluster/apps/system/external-secrets/templates/secret.yaml`:
Replace the plain K8s Secret manifest that uses `<secret:dopplerToken|base64>` with:

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

Add to `app-config.yaml` `ignoreDifferences` (same pattern as `bitwarden-access-token`):
```yaml
ignoreDifferences:
  - kind: Secret
    name: doppler-token-auth-api
    jsonPointers:
      - /data
```

**Remove** `plugin` block from `app-config.yaml`. **Delete** `secret.sec.yaml`.

---

### App: `envoy-gateweay` (system) — new app, never had SOPS

This app uses `<secret:private-domain>` in `templates/cert.yaml` — non-injectable. Plugin needed.
`PRIVATE_DOMAIN` is already in `cluster-secrets` from Phase 0.

**Create/ensure** `cluster/apps/system/envoy-gateweay/app-config.yaml` contains:
```yaml
plugin:
  env:
    - name: SECRET_PROVIDER
      value: cluster-secrets
```

No `secret.sec.yaml` ever needed.

---

## Phase Final — Remove SOPS infrastructure

**Only after every single app above has been migrated and verified working.**

### F.1 — Remove old SOPS plugin from `sops-replacer-plugin.yaml`

**File:** `cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`

Remove the two old entries from the ConfigMap:
- `sops-replacer-plugin-kustomize.yaml`
- `sops-replacer-plugin-helm.yaml`

Only the new `secret-replacer-plugin-*` entries remain.

Optionally rename the ConfigMap itself from `sops-replacer-plugin` to `secret-replacer-plugin`
and update all references (volumeMount `subPath` fields in the patch).

### F.2 — Remove old SOPS sidecars from `argo-cd-repo-server-ksops-patch.yaml`

Remove the two old sidecar containers:
- `sops-replacer-plugin-kustomize`
- `sops-replacer-plugin-helm`

Remove the `sops-age` volume from `spec.template.spec.volumes`.

### F.3 — Cluster cleanup (manual)

```bash
kubectl delete secret sops-age -n argocd
```

### F.4 — Repo cleanup

- **`.sops.yaml`**: delete (no longer used)
- **`.pre-commit-config.yaml`**: remove `sops-check` hook entry
- **Devcontainer secret**: remove `SOPS_AGE_KEY` from devcontainer secrets configuration

### F.5 — Documentation

Update `CLAUDE.md` secrets management section to reflect the new ESO + mounted secret approach.

---

## Rollback Procedure (per app)

If an app migration fails after ArgoCD syncs:
1. Revert `app-config.yaml` to restore `SOPS_SECRET_FILE: secret.sec.yaml`
2. Restore `secret.sec.yaml` from git history
3. ArgoCD will re-discover the app via the old SOPS plugin on next sync

The old SOPS plugin and Age key remain available until Phase Final, making every per-app migration
fully reversible.

---

## Important Notes for the Agent

1. **Do NOT add actual secret values** to any file. Bitwarden UUIDs must be filled in by the
   operator. Leave `"<UUID>"` or `"<BITWARDEN_UUID_*>"` placeholders in `remoteRef.key` fields.

2. **Verify token field location before deciding**: for every `<secret:key>` token, check whether
   the surrounding YAML is a `Secret` `data`/`stringData` field (→ ExternalSecret) or any other
   field (→ `cluster-secrets` + plugin). Do not assume — read the file first.

3. **checksum annotation**: any file with
   `checksum/secrets: {{ .Files.Get "secret.sec.yaml" | sha256sum }}` must have that annotation
   removed when `secret.sec.yaml` is deleted. Helm errors if the referenced file doesn't exist.

4. **Phase 0 must be committed and ArgoCD synced before any per-app migration begins.** The
   new plugin sidecars and `cluster-secrets` Secret must exist in the cluster first.

5. **ExternalSecret `creationPolicy: Merge`** only when targeting existing system-managed Secrets
   (like `argocd-secret`). Use `creationPolicy: Owner` for all new secrets.

6. **`bitwarden` ClusterSecretStore** is cluster-scoped — ExternalSecrets in any namespace can
   reference it with `kind: ClusterSecretStore`.

7. **home-assistant `templates/secrets.yaml`** is already an ESO ExternalSecret — modify in-place,
   do not create a new file wrapping it.

8. **dyndns `stringData.config.yaml`**: must inspect the decrypted content structure before
   writing the ESO template. The exact YAML inside the config must be preserved.

9. **New plugin sidecar names** are `secret-replacer-plugin-kustomize` and
   `secret-replacer-plugin-helm` — distinct from the old `sops-replacer-*` names to allow both
   to coexist in the same Deployment spec.
