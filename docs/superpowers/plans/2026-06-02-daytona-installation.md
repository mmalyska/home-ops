# Daytona Installation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Daytona sandbox platform with Harbor as a standalone ArgoCD app, enabling isolated sandboxes for Hermes agent profiles and SSH-accessible dev environments.

**Architecture:** Harbor deployed at `cluster/apps/default/harbor/` (CNPG + Ceph RBD). Daytona at `cluster/apps/ai/daytona/` with Harbor subchart disabled, Keycloak (`home` realm) as OIDC, runners targeting `daytona-sandbox-c: "true"` nodes, SSH Gateway on Cilium daytona-pool (.51–.70). All HTTP via Envoy Gateway HTTPRoutes. All secrets in `cluster-secrets` (substituted by argocd-secret-replacer plugin before Helm renders) except Harbor robot credentials and Keycloak OIDC client secret which go via per-app ExternalSecrets (created post-initial-deploy).

**Secrets strategy:** Values that appear as Helm chart strings → `<secret:key>` tokens in values.yaml → cluster-secrets substitution. Values that come from external systems created post-deploy (Harbor robot account, Keycloak client secret) → per-app ExternalSecret + `extraEnv` secretKeyRef.

**Tech Stack:** Helm (harbor/harbor v1.19.1, daytona/daytona v0.0.25, pgsql-cnpg v1.3.2), ArgoCD, CNPG, Ceph (`ceph-block` StorageClass), Cilium L2 LB-IPAM, Envoy Gateway, Keycloak, Bitwarden ESO.

**Design spec:** `docs/superpowers/specs/2026-06-02-daytona-installation-design.md`

---

## Task 1: Add Cilium daytona IP pool

**Files:**
- Modify: `cluster/apps/core/cilium/templates/config.yaml`

- [ ] **Step 1: Append daytona pool to cilium config**

Open `cluster/apps/core/cilium/templates/config.yaml` and append after the existing resources:

```yaml
---
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "daytona-pool"
spec:
  blocks:
    - start: "192.168.48.51"
      stop: "192.168.48.70"
```

The existing `l2policy` has no `serviceSelector` or `ipPoolSelector` — it already announces all LoadBalancer IPs on the cluster interfaces. No new L2 policy is needed.

- [ ] **Step 2: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 3: Commit**

```bash
git add cluster/apps/core/cilium/templates/config.yaml
git commit -m "feat(cilium): add daytona-pool for sandbox LB IPs (192.168.48.51-70)"
```

---

## Task 2: Add daytona-sandbox-c node label to controlplane template

**Files:**
- Modify: `provision/talos/templates/controlplane.yaml`

- [ ] **Step 1: Add label to nodeLabels section**

In `provision/talos/templates/controlplane.yaml`, find the `nodeLabels` section and add:

```yaml
  nodeLabels:
    topology.kubernetes.io/region: home
    topology.kubernetes.io/zone: m
    daytona-sandbox-c: "true"
```

- [ ] **Step 2: Regenerate Talos clusterconfig**

```bash
cd /workspaces/home-ops/provision/talos
talhelper genconfig
```

Expected: `clusterconfig/` files updated with new nodeLabel.

- [ ] **Step 3: Apply config to all three control-plane nodes**

Apply one node at a time:

```bash
TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig \
  talosctl -n 192.168.48.2 apply-config \
  -f /workspaces/home-ops/provision/talos/clusterconfig/home-mc1.yaml

TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig \
  talosctl -n 192.168.48.3 apply-config \
  -f /workspaces/home-ops/provision/talos/clusterconfig/home-mc2.yaml

TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig \
  talosctl -n 192.168.48.4 apply-config \
  -f /workspaces/home-ops/provision/talos/clusterconfig/home-mc3.yaml
```

- [ ] **Step 4: Verify label on all nodes**

```bash
kubectl get nodes -l daytona-sandbox-c=true
```

Expected: mc1, mc2, mc3 all listed.

- [ ] **Step 5: Commit**

```bash
git add provision/talos/templates/controlplane.yaml provision/talos/clusterconfig/
git commit -m "feat(talos): add daytona-sandbox-c node label to control-plane nodes"
```

---

## Task 3: Add Daytona + Harbor secrets to cluster-secrets

**Files:**
- Modify: `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`

These secrets are needed before Harbor and Daytona values.yaml can be committed, because values.yaml uses `<secret:key>` tokens that reference these keys.

- [ ] **Step 1: Generate all secrets and store in Bitwarden**

Run these commands to generate values. Store each in Bitwarden Secrets Manager and note the UUID.

```bash
# Harbor admin password
echo "HARBOR_ADMIN_PASSWORD: (generate 32+ char password in Bitwarden UI)"

# Daytona SSH gateway keypairs
ssh-keygen -t ed25519 -f /tmp/gw_host -N "" && ssh-keygen -t ed25519 -f /tmp/gw_client -N ""
echo "DAYTONA_SSH_HOST_PRIVATE_KEY:";   cat /tmp/gw_host     | base64 -w 0; echo
echo "DAYTONA_SSH_HOST_PUBLIC_KEY:";    cat /tmp/gw_host.pub  | base64 -w 0; echo
echo "DAYTONA_SSH_CLIENT_PRIVATE_KEY:"; cat /tmp/gw_client    | base64 -w 0; echo
echo "DAYTONA_SSH_CLIENT_PUBLIC_KEY:";  cat /tmp/gw_client.pub | base64 -w 0; echo

# Daytona encryption
echo "DAYTONA_ENCRYPTION_KEY:";   openssl rand -base64 32 | head -c 32; echo
echo "DAYTONA_ENCRYPTION_SALT:";  openssl rand -base64 32; echo

# Daytona API tokens (shared across API / runner / runner-manager / ssh-gateway)
echo "DAYTONA_RUNNER_MANAGER_API_KEY:"; openssl rand -hex 32
echo "DAYTONA_RUNNER_API_TOKEN:";       openssl rand -hex 32
echo "DAYTONA_SYSTEM_API_TOKEN:";       openssl rand -hex 32
echo "DAYTONA_SSH_GATEWAY_API_KEY:";    openssl rand -hex 32

# Daytona DB password (controls the CNPG bootstrap password — choose and store this)
echo "DAYTONA_DB_PASSWORD:"; openssl rand -hex 24
```

Bitwarden entries to create (note UUID for each):
| Secret key | Description |
|---|---|
| `HARBOR_ADMIN_PASSWORD` | Harbor admin password |
| `DAYTONA_SSH_HOST_PRIVATE_KEY` | SSH gateway host private key (base64) |
| `DAYTONA_SSH_HOST_PUBLIC_KEY` | SSH gateway host public key (base64) |
| `DAYTONA_SSH_CLIENT_PRIVATE_KEY` | SSH gateway client private key (base64) |
| `DAYTONA_SSH_CLIENT_PUBLIC_KEY` | SSH gateway client public key (base64) |
| `DAYTONA_ENCRYPTION_KEY` | 32-char Daytona encryption key |
| `DAYTONA_ENCRYPTION_SALT` | Daytona encryption salt |
| `DAYTONA_RUNNER_MANAGER_API_KEY` | Shared API key between API + runner-manager |
| `DAYTONA_RUNNER_API_TOKEN` | Runner's auth token to API |
| `DAYTONA_SYSTEM_API_TOKEN` | Daytona system API token |
| `DAYTONA_SSH_GATEWAY_API_KEY` | SSH gateway's API key |
| `DAYTONA_DB_PASSWORD` | Daytona PostgreSQL password (set at CNPG init) |

- [ ] **Step 2: Add entries to cluster-secrets-externalsecret.yaml**

Edit `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml` and append the following inside the `data:` list. Replace each `<UUID>` with the actual Bitwarden UUID:

```yaml
    - secretKey: harbor-admin-password
      remoteRef:
        key: "<HARBOR_ADMIN_PASSWORD_UUID>" #gitleaks:allow #HARBOR_ADMIN_PASSWORD
    - secretKey: daytona-ssh-host-private-key
      remoteRef:
        key: "<DAYTONA_SSH_HOST_PRIVATE_KEY_UUID>" #gitleaks:allow #DAYTONA_SSH_HOST_PRIVATE_KEY
    - secretKey: daytona-ssh-host-public-key
      remoteRef:
        key: "<DAYTONA_SSH_HOST_PUBLIC_KEY_UUID>" #gitleaks:allow #DAYTONA_SSH_HOST_PUBLIC_KEY
    - secretKey: daytona-ssh-client-private-key
      remoteRef:
        key: "<DAYTONA_SSH_CLIENT_PRIVATE_KEY_UUID>" #gitleaks:allow #DAYTONA_SSH_CLIENT_PRIVATE_KEY
    - secretKey: daytona-ssh-client-public-key
      remoteRef:
        key: "<DAYTONA_SSH_CLIENT_PUBLIC_KEY_UUID>" #gitleaks:allow #DAYTONA_SSH_CLIENT_PUBLIC_KEY
    - secretKey: daytona-encryption-key
      remoteRef:
        key: "<DAYTONA_ENCRYPTION_KEY_UUID>" #gitleaks:allow #DAYTONA_ENCRYPTION_KEY
    - secretKey: daytona-encryption-salt
      remoteRef:
        key: "<DAYTONA_ENCRYPTION_SALT_UUID>" #gitleaks:allow #DAYTONA_ENCRYPTION_SALT
    - secretKey: daytona-runner-manager-api-key
      remoteRef:
        key: "<DAYTONA_RUNNER_MANAGER_API_KEY_UUID>" #gitleaks:allow #DAYTONA_RUNNER_MANAGER_API_KEY
    - secretKey: daytona-runner-api-token
      remoteRef:
        key: "<DAYTONA_RUNNER_API_TOKEN_UUID>" #gitleaks:allow #DAYTONA_RUNNER_API_TOKEN
    - secretKey: daytona-system-api-token
      remoteRef:
        key: "<DAYTONA_SYSTEM_API_TOKEN_UUID>" #gitleaks:allow #DAYTONA_SYSTEM_API_TOKEN
    - secretKey: daytona-ssh-gateway-api-key
      remoteRef:
        key: "<DAYTONA_SSH_GATEWAY_API_KEY_UUID>" #gitleaks:allow #DAYTONA_SSH_GATEWAY_API_KEY
    - secretKey: daytona-db-password
      remoteRef:
        key: "<DAYTONA_DB_PASSWORD_UUID>" #gitleaks:allow #DAYTONA_DB_PASSWORD
```

- [ ] **Step 3: Lint and commit**

```bash
task lint:all
git add cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml
git commit -m "feat(cluster-secrets): add Harbor and Daytona secret entries"
```

- [ ] **Step 4: Push and wait for cluster-secrets to refresh**

```bash
git push
```

Wait ~1 minute for ESO to refresh the `cluster-secrets` K8s Secret in the `argocd` namespace:

```bash
kubectl -n argocd get secret cluster-secrets -o jsonpath='{.data.harbor-admin-password}' | base64 -d | wc -c
```

Expected: non-zero character count (confirms the key was populated).

---

## Task 4: Create Harbor app — chart definition and app-config

**Files:**
- Create: `cluster/apps/default/harbor/app-config.yaml`
- Create: `cluster/apps/default/harbor/Chart.yaml`

- [ ] **Step 1: Create directory and app-config.yaml**

```bash
mkdir -p cluster/apps/default/harbor/templates
```

Create `cluster/apps/default/harbor/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: harbor
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Step 2: Create Chart.yaml**

Create `cluster/apps/default/harbor/Chart.yaml`:

```yaml
---
apiVersion: v2
name: harbor
type: application
version: 1.0.0
dependencies:
  - name: harbor
    version: 1.19.1
    repository: https://helm.goharbor.io
  - name: pgsql-cnpg
    version: 1.3.2
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Step 3: Download chart dependencies**

```bash
cd cluster/apps/default/harbor
helm dependency update
```

Expected: `charts/` directory created.

- [ ] **Step 4: Commit**

```bash
git add cluster/apps/default/harbor/
git commit -m "feat(harbor): add chart definition and app-config"
```

---

## Task 5: Create Harbor values.yaml

**Files:**
- Create: `cluster/apps/default/harbor/values.yaml`

- [ ] **Step 1: Create values.yaml**

Create `cluster/apps/default/harbor/values.yaml`:

```yaml
harbor:
  expose:
    type: clusterIP
    tls:
      enabled: false
  externalURL: https://harbor.<secret:private-domain>

  # Admin password from cluster-secrets (substituted before Helm renders)
  harborAdminPassword: <secret:harbor-admin-password>

  persistence:
    enabled: true
    persistentVolumeClaim:
      registry:
        storageClass: ceph-block
        size: 200Gi
      jobservice:
        jobLog:
          storageClass: ceph-block
          size: 5Gi
      database:
        storageClass: ceph-block
        size: 2Gi
      redis:
        storageClass: ceph-block
        size: 2Gi
      trivy:
        storageClass: ceph-block
        size: 5Gi

  database:
    type: external
    external:
      host: harbordb-cnpg-rw
      port: "5432"
      username: app
      coreDatabase: app
      existingSecret: harbordb-cnpg-app
      sslmode: require

  redis:
    type: internal

  trivy:
    enabled: false

  notary:
    server:
      enabled: false
    signer:
      enabled: false

pgsql-cnpg:
  name: harbordb
  storage:
    size: 5Gi
```

- [ ] **Step 2: Render and verify**

```bash
cd cluster/apps/default/harbor
helm template harbor . -f values.yaml 2>&1 | grep -E "^kind:|Error" | head -30
```

Expected: list of resource kinds, no `Error` lines. Note the main service name (look for `kind: Service` + name lines — should include a `harbor` or similar service on port 80).

- [ ] **Step 3: Lint and commit**

```bash
cd /workspaces/home-ops
task lint:all
git add cluster/apps/default/harbor/values.yaml
git commit -m "feat(harbor): add values.yaml with CNPG + Ceph + cluster-secrets tokens"
```

---

## Task 6: Create Harbor HTTPRoute

**Files:**
- Create: `cluster/apps/default/harbor/templates/httproute.yaml`

- [ ] **Step 1: Confirm Harbor main service name**

```bash
cd cluster/apps/default/harbor
helm template harbor . -f values.yaml | grep -B1 "port: 80" | grep "name:" | head -5
```

Note the service name serving port 80. It is typically the release name (`harbor`).

- [ ] **Step 2: Create httproute.yaml**

Create `cluster/apps/default/harbor/templates/httproute.yaml` (update `backendRefs.name` if the service from Step 1 differs from `harbor`):

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: harbor
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - harbor.<secret:private-domain>
  rules:
    - backendRefs:
        - name: harbor
          port: 80
```

- [ ] **Step 3: Lint and commit**

```bash
cd /workspaces/home-ops
task lint:all
git add cluster/apps/default/harbor/templates/
git commit -m "feat(harbor): add HTTPRoute"
```

---

## Task 7: Deploy Harbor and bootstrap

- [ ] **Step 1: Push and wait for ArgoCD to sync Harbor**

```bash
git push
```

In ArgoCD: monitor the `harbor` application. CNPG cluster `harbordb-cnpg` initializes first (~2–3 min), then Harbor pods start.

- [ ] **Step 2: Verify Harbor is reachable**

```bash
# Fetch HARBOR_PASS from Bitwarden CLI: bws secret get <HARBOR_ADMIN_PASSWORD_UUID>
HARBOR_PASS="$(bws secret get <HARBOR_ADMIN_PASSWORD_UUID> --output-format env | cut -d= -f2)"
curl -sk "https://harbor.<private-domain>/api/v2.0/systeminfo" \
  --user "admin:${HARBOR_PASS}" | python3 -m json.tool | grep harbor_version
```

Expected: JSON with `harbor_version` field.

- [ ] **Step 3: Create daytona project in Harbor**

```bash
curl -X POST "https://harbor.<private-domain>/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  --user "admin:${HARBOR_PASS}" \
  -d '{"project_name": "daytona", "public": false, "metadata": {"public": "false"}}'
```

Expected: HTTP 201.

- [ ] **Step 4: Create Harbor robot account for Daytona**

```bash
curl -X POST "https://harbor.<private-domain>/api/v2.0/robots" \
  -H "Content-Type: application/json" \
  --user "admin:${HARBOR_PASS}" \
  -d '{
    "name": "daytona-runner",
    "duration": -1,
    "permissions": [{
      "kind": "project",
      "namespace": "daytona",
      "access": [
        {"resource": "repository", "action": "push"},
        {"resource": "repository", "action": "pull"},
        {"resource": "artifact",   "action": "read"}
      ]
    }]
  }'
```

Expected: HTTP 201. **Copy the `secret` field from the response immediately — it is shown only once.** The robot username format is `robot$daytona-runner`.

- [ ] **Step 5: Store robot credentials in Bitwarden and add to cluster-secrets**

1. Create two Bitwarden secrets:
   - `HARBOR_ROBOT_NAME` → `robot$daytona-runner`
   - `HARBOR_ROBOT_SECRET` → the secret from Step 4

2. Edit `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml` and append:

```yaml
    - secretKey: daytona-harbor-robot-name
      remoteRef:
        key: "<HARBOR_ROBOT_NAME_UUID>" #gitleaks:allow #HARBOR_ROBOT_NAME
    - secretKey: daytona-harbor-robot-secret
      remoteRef:
        key: "<HARBOR_ROBOT_SECRET_UUID>" #gitleaks:allow #HARBOR_ROBOT_SECRET
```

3. Commit and push:

```bash
git add cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml
git commit -m "feat(cluster-secrets): add Harbor robot credentials for Daytona"
git push
```

4. Wait for cluster-secrets to refresh:

```bash
kubectl -n argocd get secret cluster-secrets -o jsonpath='{.data.daytona-harbor-robot-name}' | base64 -d
```

Expected: `robot$daytona-runner`.

---

## Task 8: Create Daytona app — chart definition and app-config

**Files:**
- Create: `cluster/apps/ai/daytona/app-config.yaml`
- Create: `cluster/apps/ai/daytona/Chart.yaml`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p cluster/apps/ai/daytona/templates
```

- [ ] **Step 2: Create app-config.yaml**

Create `cluster/apps/ai/daytona/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: daytona
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Step 3: Create Chart.yaml**

Create `cluster/apps/ai/daytona/Chart.yaml`:

```yaml
---
apiVersion: v2
name: daytona
type: application
version: 1.0.0
dependencies:
  - name: daytona
    version: 0.0.25
    repository: https://daytonaio.github.io/helm-charts
  - name: pgsql-cnpg
    version: 1.3.2
    repository: file://../../../../charts/pgsql-cnpg/
```

- [ ] **Step 4: Download chart dependencies**

```bash
cd cluster/apps/ai/daytona
helm dependency update
```

Expected: `charts/` directory populated.

- [ ] **Step 5: Commit**

```bash
git add cluster/apps/ai/daytona/app-config.yaml cluster/apps/ai/daytona/Chart.yaml \
        cluster/apps/ai/daytona/charts/ cluster/apps/ai/daytona/Chart.lock
git commit -m "feat(daytona): add chart definition and app-config"
```

---

## Task 9: Create Daytona values.yaml

**Files:**
- Create: `cluster/apps/ai/daytona/values.yaml`

All sensitive values use `<secret:key>` tokens — substituted from cluster-secrets before Helm renders.

- [ ] **Step 1: Create values.yaml**

Create `cluster/apps/ai/daytona/values.yaml`:

```yaml
daytona:
  baseDomain: daytona.<secret:private-domain>

  services:
    api:
      env:
        ENVIRONMENT: "production"
        PORT: "3000"

        # OIDC — Keycloak home realm (Dex subchart is disabled)
        OIDC_CLIENT_ID: "daytona"
        OIDC_ISSUER_BASE_URL: "https://l.<secret:private-domain>/realms/home"
        PUBLIC_OIDC_DOMAIN: "https://l.<secret:private-domain>"
        OIDC_AUDIENCE: "daytona"
        SKIP_USER_EMAIL_VERIFICATION: "true"

        # Encryption
        ENCRYPTION_KEY: <secret:daytona-encryption-key>
        ENCRYPTION_SALT: <secret:daytona-encryption-salt>

        DRAINING_MODE: "archive"
        DRAINING_FORCE: "true"

        DEFAULT_SNAPSHOT_IMAGE_NAME: "daytonaio/sandbox:0.5.1-slim"
        DEFAULT_SNAPSHOT_NAME: "default-snapshot"

        RUNNER_MANAGER_API_KEY: <secret:daytona-runner-manager-api-key>

        # Harbor registry (Harbor deployed as separate app in default namespace)
        TRANSIENT_REGISTRY_URL: "harbor.default.svc.cluster.local"
        TRANSIENT_REGISTRY_ADMIN: <secret:daytona-harbor-robot-name>
        TRANSIENT_REGISTRY_PASSWORD: <secret:daytona-harbor-robot-secret>
        TRANSIENT_REGISTRY_PROJECT_ID: "daytona"
        INTERNAL_REGISTRY_URL: "harbor.default.svc.cluster.local"
        INTERNAL_REGISTRY_ADMIN: <secret:daytona-harbor-robot-name>
        INTERNAL_REGISTRY_PASSWORD: <secret:daytona-harbor-robot-secret>
        INTERNAL_REGISTRY_PROJECT_ID: "daytona"

      resources:
        limits:
          cpu: 500m
          memory: 512Mi
        requests:
          cpu: 100m
          memory: 128Mi

    sshGateway:
      enabled: true
      service:
        type: LoadBalancer
        port: 2222
        annotations:
          io.cilium/lb-ipam-pool: daytona-pool
      # SSH gateway authenticates to API using this key
      apiKey: <secret:daytona-ssh-gateway-api-key>
      sshKeys:
        # All four keys are base64-encoded ed25519 values from cluster-secrets
        privHostSSHKey: <secret:daytona-ssh-host-private-key>
        pubHostSSHKey: <secret:daytona-ssh-host-public-key>
        privClientSSHKey: <secret:daytona-ssh-client-private-key>
        pubClientSSHKey: <secret:daytona-ssh-client-public-key>

    runnermanager:
      env:
        API_TOKEN: <secret:daytona-runner-manager-api-key>

    runner:
      env:
        API_TOKEN: <secret:daytona-runner-api-token>
        SYSTEM_API_TOKEN: <secret:daytona-system-api-token>
        # SSH_PUBLIC_KEY must match pubClientSSHKey above
        SSH_PUBLIC_KEY: <secret:daytona-ssh-client-public-key>
      # Target only nodes labeled daytona-sandbox-c=true (control-plane nodes for now)
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: daytona-sandbox-c
                    operator: In
                    values:
                      - "true"
      resources:
        limits:
          cpu: 2000m
          memory: 4Gi
        requests:
          cpu: 1000m
          memory: 2Gi
      dockerInstaller:
        enabled: true
        xfsStorageSize: "50G"

  # Disabled subcharts — using external services
  postgresql:
    enabled: false

  dex:
    enabled: false

  harbor:
    enabled: false

  minio:
    enabled: false

  pgadmin4:
    enabled: false

  # Bundled Redis — isolated, low overhead
  redis:
    enabled: true
    auth:
      enabled: false
    persistence:
      enabled: true
      storageClass: ceph-block
      size: 1Gi
    replica:
      replicaCount: 0

  # External database — CNPG cluster (password controlled via bootstrap, see templates/)
  externalDatabase:
    host: daytonadb-cnpg-rw
    port: 5432
    name: app
    user: app
    enableTLS: true
    allowSelfSignedCert: true
    password: <secret:daytona-db-password>

# CNPG cluster bootstrapped with a specific password so externalDatabase.password matches
pgsql-cnpg:
  name: daytonadb
  storage:
    size: 5Gi
  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: daytonadb-init-secret
```

- [ ] **Step 2: Render and verify**

```bash
cd cluster/apps/ai/daytona
helm template daytona . -f values.yaml 2>&1 | grep -E "^kind:|Error" | head -30
```

Expected: list of Kubernetes resource kinds, no `Error` lines.

- [ ] **Step 3: Lint and commit**

```bash
cd /workspaces/home-ops
task lint:all
git add cluster/apps/ai/daytona/values.yaml
git commit -m "feat(daytona): add values.yaml with Keycloak OIDC, external Harbor, CNPG"
```

---

## Task 10: Create Daytona HTTPRoutes and DB init ExternalSecret

**Files:**
- Create: `cluster/apps/ai/daytona/templates/httproute-api.yaml`
- Create: `cluster/apps/ai/daytona/templates/httproute-proxy.yaml`
- Create: `cluster/apps/ai/daytona/templates/daytonadb-init-externalsecret.yaml`

The DB init ExternalSecret provides the bootstrap credentials for the CNPG cluster. It must be created before CNPG initializes — ArgoCD sync wave ordering handles this (ExternalSecret syncs before the pgsql-cnpg chart resources since it's in `templates/`).

- [ ] **Step 1: Create API HTTPRoute**

Create `cluster/apps/ai/daytona/templates/httproute-api.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: daytona-api
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - daytona.<secret:private-domain>
  rules:
    - backendRefs:
        - name: daytona-api
          port: 3000
```

- [ ] **Step 2: Create Proxy HTTPRoute (wildcard)**

Create `cluster/apps/ai/daytona/templates/httproute-proxy.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: daytona-proxy
  annotations:
    external-dns.alpha.kubernetes.io/controller: dns-controller
spec:
  parentRefs:
    - name: envoy-internal
      namespace: envoy-gateway
      sectionName: https
  hostnames:
    - "*.daytona.<secret:private-domain>"
  rules:
    - backendRefs:
        - name: daytona-proxy
          port: 4000
```

- [ ] **Step 3: Create CNPG DB init ExternalSecret**

This creates `daytonadb-init-secret` with `username` and `password` keys. CNPG uses this secret during `bootstrap.initdb` (referenced in values.yaml `pgsql-cnpg.bootstrap.initdb.secret.name`).

Create `cluster/apps/ai/daytona/templates/daytonadb-init-externalsecret.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: daytonadb-init-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: daytonadb-init-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: "<DAYTONA_DB_USER_UUID>" #gitleaks:allow #DAYTONA_DB_USER (value: "app")
    - secretKey: password
      remoteRef:
        key: "<DAYTONA_DB_PASSWORD_UUID>" #gitleaks:allow #DAYTONA_DB_PASSWORD
```

For `DAYTONA_DB_USER_UUID`: create a Bitwarden secret with value `app` and note its UUID. For `DAYTONA_DB_PASSWORD_UUID`: use the same UUID as `daytona-db-password` already added to cluster-secrets in Task 3.

- [ ] **Step 4: Lint and commit**

```bash
cd /workspaces/home-ops
task lint:all
git add cluster/apps/ai/daytona/templates/
git commit -m "feat(daytona): add HTTPRoutes and CNPG init ExternalSecret"
```

---

## Task 11: Configure Keycloak OIDC client for Daytona

- [ ] **Step 1: Create Keycloak client for Daytona**

Log into Keycloak at `https://l.<private-domain>` → Realm `home` → Clients → Create client:

- **Client ID:** `daytona`
- **Client type:** OpenID Connect
- **Client authentication:** On (confidential)
- **Valid redirect URIs:**
  - `https://daytona.<private-domain>/api/oauth2-redirect.html`
  - `https://daytona.<private-domain>/callback`
  - `http://localhost:8080/api/oauth2-redirect.html`
  - `http://localhost:8080/callback`
  - `http://localhost:3009/callback`

- [ ] **Step 2: Copy client secret and add to cluster-secrets**

In Keycloak: Client `daytona` → Credentials tab → copy the client secret.

1. Create Bitwarden secret `DAYTONA_OIDC_CLIENT_SECRET` → paste the Keycloak client secret. Note the UUID.

2. Edit `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml` and append:

```yaml
    - secretKey: daytona-oidc-client-secret
      remoteRef:
        key: "<DAYTONA_OIDC_CLIENT_SECRET_UUID>" #gitleaks:allow #DAYTONA_OIDC_CLIENT_SECRET
```

3. Edit `cluster/apps/ai/daytona/values.yaml` and add `OIDC_CLIENT_SECRET` to `services.api.env`:

```yaml
        OIDC_CLIENT_SECRET: <secret:daytona-oidc-client-secret>
```

4. Commit and push:

```bash
git add cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml \
        cluster/apps/ai/daytona/values.yaml
git commit -m "feat(daytona): add Keycloak OIDC client secret to cluster-secrets"
git push
```

---

## Task 12: Deploy and bootstrap Daytona

- [ ] **Step 1: Push and wait for ArgoCD sync**

If not already pushed:

```bash
git push
```

In ArgoCD: monitor the `daytona` application. CNPG cluster `daytonadb-cnpg` initializes first (~2–3 min) using the `daytonadb-init-secret`, then Daytona pods start.

- [ ] **Step 2: Verify all pods running**

```bash
kubectl -n daytona get pods
```

Expected: `daytona-api-*`, `daytona-proxy-*`, `daytona-runnermanager-*`, `daytona-runner-*`, `daytona-ssh-gateway-*` all `Running`.

- [ ] **Step 3: Verify SSH Gateway LoadBalancer IP from daytona-pool**

```bash
kubectl -n daytona get svc daytona-ssh-gateway
```

Expected: `EXTERNAL-IP` in range `192.168.48.51–192.168.48.70`.

- [ ] **Step 4: Verify Daytona dashboard reachable**

Open `https://daytona.<private-domain>` in browser. Should redirect to Keycloak (`home` realm) login. Log in with a `home` realm user. Expected: Daytona dashboard loads.

- [ ] **Step 5: Verify runner is registered**

```bash
kubectl -n daytona logs deploy/daytona-api | grep -i "runner" | tail -10
```

Expected: log lines referencing runner registration or health.

- [ ] **Step 6: Test SSH gateway connectivity**

```bash
SSH_GW_IP=$(kubectl -n daytona get svc daytona-ssh-gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "SSH Gateway IP: ${SSH_GW_IP}"
nc -zv "${SSH_GW_IP}" 2222
```

Expected: `Connection to <IP> 2222 port [tcp/*] succeeded`.

- [ ] **Step 7: Create and verify first sandbox**

In the Daytona dashboard:
1. Create a new sandbox from image `ubuntu:22.04`
2. Wait for status `Running`
3. Open a terminal in the sandbox via the UI — verify shell prompt

- [ ] **Step 8: Final commit**

If any fixup changes were made during bootstrap:

```bash
git status
git add -A
git commit -m "feat(daytona): bootstrap complete — fixups"
git push
```

---

## Post-Install Checklist

- [ ] **Wire Hermes to Daytona API:** add to Hermes ExternalSecret: `DAYTONA_API_URL=https://daytona.<private-domain>` and generate an admin API key from the Daytona dashboard → store in Bitwarden and reference in Hermes values
- [ ] **Create agent profile snapshots:** start a sandbox, install required tools for a Hermes agent profile, snapshot it → push to Harbor `daytona` project → reference the snapshot image name in Daytona workspace config
- [ ] ***(Optional later)* Harbor Keycloak SSO:** Harbor → Administration → Configuration → Authentication → OIDC → configure with Keycloak `home` realm
- [ ] ***(Future)* Runner migration to dedicated workers:** see `.plans/TODO.md`
