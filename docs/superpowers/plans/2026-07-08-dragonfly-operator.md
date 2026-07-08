# Dragonfly Operator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the Dragonfly Operator and a reusable `charts/dragonfly` chart (mirroring `charts/pgsql-cnpg`), then migrate oauth2-proxy, Nextcloud, Harbor, and Gitea from their current Bitnami-redis-family/Valkey instances onto per-app Dragonfly CRs.

**Architecture:** A new system app installs the official `dragonfly-operator` Helm chart (OCI, CRDs bundled). A new leaf chart `charts/dragonfly/` templates a single `Dragonfly` CR per consuming app, values-driven like `pgsql-cnpg`. Each of the four target apps drops its old redis-family subchart block and adds a `dragonfly:` block instead, reusing existing Bitwarden-backed secrets where they already exist (oauth2-proxy, nextcloud) and adding new ones where they don't (harbor, gitea — both currently disabled).

**Tech Stack:** Helm (OCI dependency), Dragonfly Operator v1.6.1 (`dragonflydb.io/v1alpha1` `Dragonfly` CRD), External Secrets Operator + Bitwarden `ClusterSecretStore`, ArgoCD ApplicationSet.

## Status: Complete

All 6 tasks implemented and reviewed (task-level reviews + a final whole-branch review). Shipped across 5 PRs rather than one, since live-app tasks (3, 4) each required a merge-and-verify stop-gate before the next task could start:

| Task                   | Outcome                                                                                                                                                                                                                                                                                                                                    |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1 (Dragonfly Operator) | Merged as part of PR [#4482](https://github.com/mmalyska/home-ops/pull/4482)                                                                                                                                                                                                                                                               |
| 2 (`charts/dragonfly`) | Merged as part of PR [#4482](https://github.com/mmalyska/home-ops/pull/4482)                                                                                                                                                                                                                                                               |
| 3 (oauth2-proxy, live) | Merged as part of PR [#4482](https://github.com/mmalyska/home-ops/pull/4482). Live verification surfaced a production crash-loop, fixed in a follow-up PR [#4484](https://github.com/mmalyska/home-ops/pull/4484) — see Deviation 1 below.                                                                                                 |
| 4 (Nextcloud, live)    | PR [#4485](https://github.com/mmalyska/home-ops/pull/4485), merged, live-verified healthy.                                                                                                                                                                                                                                                 |
| 5 (Harbor, disabled)   | PR [#4486](https://github.com/mmalyska/home-ops/pull/4486), merged. Final whole-branch review found a latent auth bug in this PR — the fix (commit `50c3d753`) was pushed after #4486 was already merged, so it landed as a separate follow-up PR [#4488](https://github.com/mmalyska/home-ops/pull/4488) instead — see Deviation 2 below. |
| 6 (Gitea, disabled)    | PR [#4487](https://github.com/mmalyska/home-ops/pull/4487), stacked on #4486, merged.                                                                                                                                                                                                                                                      |

**Deviation 1, found during Task 3 live verification (systematic-debugging):** `oauth2-proxy-dragonfly-0` crash-looped in production after #4482 merged. Root cause, confirmed directly from its logs (`There are 1 threads, so 256.00MiB are required. Exiting...`): Dragonfly hard-exits at boot when `maxmemory < threads * 256MB`; its default heuristic sets `maxmemory` to 80% of the container's memory _limit_; `charts/dragonfly`'s original default limit of `256Mi` (Task 2) produced `204.8Mi` — below the floor for even 1 thread. This is a chart-level defect affecting every instance, not just oauth2-proxy — oauth2-proxy's own pod crash-loop was purely downstream (`no route to host`, no ready Service endpoints). Fixed in PR [#4484](https://github.com/mmalyska/home-ops/pull/4484): bumped `charts/dragonfly`'s default `resources.limits.memory` to `512Mi`, and bumped the chart's own version `1.0.0` → `1.0.1` (propagated to every consumer's pinned dependency version below) so a cached local chart tarball can't silently mask the fix — same pinning convention this repo already uses for `pgsql-cnpg`. Live-verified healthy post-merge.

**Takeaway applied going forward:** the `dragonfly` dependency version in Tasks 4-6's text below reads `1.0.1`, not the `1.0.0` originally written for this plan — corrected during execution before those tasks' briefs were generated.

**Deviation 2, found during the final whole-branch review:** Harbor's original Task 5 implementation set `redis.external.existingSecret: harbor-dragonfly-auth`. Harbor's chart resolves that via Helm's `lookup` function (`harbor.redis.pwdfromsecret`), which returns empty under this repo's CMP plugin — a plain `helm template` invocation with no live cluster API access (`cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`). The password would have silently rendered empty, breaking Harbor's redis auth on re-enable; a per-task reviewer couldn't have caught this since it only shows up by comparing Harbor's approach against Gitea's working `<secret:key>` token pattern. A first attempted fix (switching to a `<secret:key>` token in `redis.external.password`) was itself verified broken: Harbor's `harbor.redis.cred` helper pipes the password through Helm's `urlquery` unconditionally, mangling the token into `%3Csecret%3A...%3E` before the secret-replacer's literal-match regex (traced directly in `mmalyska/argocd-secret-replacer`'s source) ever runs. Since Harbor's redis is a ClusterIP-only cache with nothing worth protecting, the final fix runs this instance unauthenticated instead: dropped `existingSecret`/`authentication` entirely, removed the now-unused `harbor-dragonfly-auth` ExternalSecret template. Verified via render: no password segment in `_REDIS_URL_CORE`/`_REDIS_URL_REG`, no `authentication` block on the CR. The `HARBOR_DRAGONFLY_PASSWORD` Bitwarden entry created for the original approach is now unused (left for the user to clean up or not).

**Deviation 3 (race condition):** the fix for Deviation 2 was pushed to #4486's branch, but the user had already merged #4486 by that point — GitHub does not retroactively add commits to an already-merged PR, so the fix silently never reached `main`. Caught when the user reported "I don't see any PRs for gitea and harbor" after both had, in fact, already been merged (a visibility/timing confusion on their end) — checking triggered a fresh look at what `main` actually contained, which is how the missed fix was discovered. Corrected via a new PR, [#4488](https://github.com/mmalyska/home-ops/pull/4488), branched fresh off `main` and cherry-picking the fix commit. **Takeaway:** after any post-review fix commit, confirm the target PR is still open and actually contains the new commit before considering the fix shipped — a merge can happen between pushing a fix and checking on it.

**Minor findings from the final review, triaged and not acted on:** Harbor's pre-existing dead `persistence.persistentVolumeClaim.redis` (2Gi) block is consistent with an already-dead `persistentVolumeClaim.database` block in the same file (harmless, disabled app); none of the four consumer apps' umbrella `Chart.yaml` versions were bumped, which the reviewer confirmed is this repo's actual convention (non-issue), not drift.

## Global Constraints

- Never mutate live cluster state (kubectl apply/delete, ArgoCD sync) without explicit user confirmation — changes land via PR + ArgoCD auto-sync, not manual `kubectl apply`.
- Never push to `main` directly — branch naming `feat/`, `fix/`, `chore/` per repo convention.
- Render every manifest/values change before committing: `helm template`, then `task lint:all`.
- Never commit secret values — gitleaks pre-commit hook blocks it. Bitwarden `remoteRef.key` UUIDs are not secret values themselves and are tagged `#gitleaks:allow` per existing convention.
- Anytype's `redis-stack`/RedisBloom instance is explicitly out of scope — do not touch `charts/anytype/` or `cluster/apps/default/anytype/`.
- Creating new Bitwarden Secrets Manager entries (for harbor/gitea, which don't have existing redis passwords) is a mutating action on a shared external system — confirm with the user before creating them, per this repo's standing rule on hard-to-reverse/shared-system actions.
- Verified facts baking this plan (see `docs/superpowers/specs/2026-07-08-dragonfly-operator-design.md` for full research trail):
  - Dragonfly Operator Helm chart: `oci://ghcr.io/dragonflydb/dragonfly-operator/helm`, chart name `dragonfly-operator`, version string is literally `v1.6.1` (with the `v` prefix — confirmed from the chart's own `Chart.yaml`). CRDs are installed by the chart itself (`crds.install: true` default) — no separate CRD-install step needed.
  - `Dragonfly` CR fields used here: `spec.replicas` (int), `spec.resources` (`corev1.ResourceRequirements`), `spec.authentication.passwordFromSecret.{name,key}` (`corev1.SecretKeySelector`), `spec.args` ([]string).
  - The operator creates a Service named exactly after the `Dragonfly` object's `metadata.name` (confirmed from `internal/resources/resources.go`: `serviceName := df.Name` unless `spec.serviceSpec.name` overrides it), listening on port `6379` (confirmed from `internal/resources/const.go`: `DragonflyPort = 6379`). So a CR named `<name>-dragonfly` produces a Service at `<name>-dragonfly.<namespace>.svc.cluster.local:6379`.
  - Default `NetworkPolicyEnabled: true` only restricts the separate admin port (`9999`), not the main Redis-protocol port (`6379`) — no NetworkPolicy changes needed for app connectivity.
  - Harbor chart (`goharbor/harbor-helm` v1.19.1) `redis.external` schema (confirmed from its `values.yaml`): `addr` (string, `"<host>:<port>"`), `existingSecret` (string, secret must contain key `REDIS_PASSWORD`), plus `coreDatabaseIndex`/`jobserviceDatabaseIndex`/`registryDatabaseIndex`/`trivyAdapterIndex` (all fine at their defaults `0`/`1`/`2`/`5`).
  - Nextcloud chart (v9.2.0) `_helpers.tpl`'s `nextcloud.env.redis` (confirmed from source): setting `redis.enabled: false` and `externalRedis.enabled: true` correctly wires `REDIS_HOST`/`REDIS_HOST_PORT`/`REDIS_HOST_PASSWORD` (the latter via `secretKeyRef` when `externalRedis.existingSecret.enabled: true`) — the dead-code bug noted in the current `values.yaml` comment only applies while `redis.enabled: true`.
  - oauth2-proxy chart (v10.7.0) ships `initContainers.waitForRedis` (confirmed from source comment): it watches the redis-ha **master pod via the Kubernetes API** (RBAC role binding to get/list/watch that specific pod), not a redis-cli ping. This is hard-wired to the redis-ha subchart's pod and cannot be repointed at a Dragonfly pod. It must be disabled (`initContainers.waitForRedis.enabled: false`) when cutting over — oauth2-proxy will retry its Redis connection normally on its own and briefly crash-loop until Dragonfly is ready, which is self-resolving. If this proves flaky in practice, the repo's own `k8s-wait-for-db` skill pattern is the documented fallback (not applied preemptively here, to avoid unnecessary complexity for what should be a fast-starting dependency).

---

### Task 1: Dragonfly Operator system app

**Files:**

- Create: `cluster/apps/system/dragonfly-operator/Chart.yaml`
- Create: `cluster/apps/system/dragonfly-operator/app-config.yaml`

**Interfaces:**

- Produces: CRD `dragonflies.dragonflydb.io` (`apiVersion: dragonflydb.io/v1alpha1`, `kind: Dragonfly`) registered cluster-wide, and a running operator Deployment in namespace `dragonfly-system`. Tasks 2+ depend on this CRD existing before any `Dragonfly` object can reconcile.

- [x] **Step 1: Create the Chart.yaml with the OCI dependency**

```bash
mkdir -p /workspaces/home-ops/cluster/apps/system/dragonfly-operator
```

Create `cluster/apps/system/dragonfly-operator/Chart.yaml`:

```yaml
---
apiVersion: v2
name: dragonfly-operator-subchart
type: application
version: 1.0.0
appVersion: "v1.6.1"
dependencies:
  - name: dragonfly-operator
    version: v1.6.1
    repository: oci://ghcr.io/dragonflydb/dragonfly-operator/helm
```

- [x] **Step 2: Create the app-config**

Create `cluster/apps/system/dragonfly-operator/app-config.yaml`:

```yaml
- enabled: "true"
  namespace: dragonfly-system
  syncWave: "-5"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

`syncWave: "-5"` matches the precedent set by `cluster/apps/system/rabbitmq-cluster-operator/app-config.yaml` and `cluster/apps/system/external-secrets/app-config.yaml` — operators whose CRDs other apps instantiate resources against directly need to exist before consumer apps sync.

- [x] **Step 3: Fetch the dependency and render**

```bash
cd /workspaces/home-ops/cluster/apps/system/dragonfly-operator
helm dependency build
helm template dragonfly-operator . | grep -c "kind: CustomResourceDefinition"
helm template dragonfly-operator . | grep "name: dragonflies.dragonflydb.io"
```

Expected: first command prints `1`, second prints a matching line (the CRD's `metadata.name`).

- [x] **Step 4: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 5: Commit**

```bash
git add cluster/apps/system/dragonfly-operator/
git commit -m "feat(dragonfly): add Dragonfly Operator system app"
```

---

### Task 2: Reusable `dragonfly` chart

**Files:**

- Create: `charts/dragonfly/Chart.yaml`
- Create: `charts/dragonfly/values.yaml`
- Create: `charts/dragonfly/templates/dragonfly.yaml`

**Interfaces:**

- Consumes: nothing (leaf chart, depends only on the CRD from Task 1 existing in the cluster at apply time — not at render time, so `helm template` works standalone without Task 1 being deployed).
- Produces (values contract for Tasks 3–6):
  - `name` (string, required) — instance name; CR (and its Service) is named `<name>-dragonfly`.
  - `replicas` (int, default `1`)
  - `resources` (map, default populated below) — passed through verbatim to `spec.resources`
  - `authentication.existingSecret` (string, default `""`) — name of a pre-existing `Secret`; when empty, `spec.authentication` is omitted entirely (unauthenticated instance)
  - `authentication.existingSecretKey` (string, default `password`) — key within that secret
  - `args` (list, default `[]`) — passed through to `spec.args`

- [x] **Step 1: Create Chart.yaml**

```bash
mkdir -p /workspaces/home-ops/charts/dragonfly/templates
```

Create `charts/dragonfly/Chart.yaml`:

```yaml
---
apiVersion: v2
name: dragonfly
type: application
version: 1.0.0
```

- [x] **Step 2: Create values.yaml**

Create `charts/dragonfly/values.yaml`:

```yaml
name: ""
replicas: 1
resources:
  requests:
    memory: 128Mi
    cpu: 50m
  limits:
    memory: 256Mi
    cpu: 250m
authentication:
  existingSecret: ""
  existingSecretKey: password
args: []
```

- [x] **Step 3: Create the template**

Create `charts/dragonfly/templates/dragonfly.yaml`:

```yaml
apiVersion: dragonflydb.io/v1alpha1
kind: Dragonfly
metadata:
  name: {{ printf "%s-%s" .Values.name "dragonfly" }}
spec:
  replicas: {{ .Values.replicas }}
  {{- with .Values.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .Values.authentication.existingSecret }}
  authentication:
    passwordFromSecret:
      name: {{ .Values.authentication.existingSecret }}
      key: {{ .Values.authentication.existingSecretKey }}
  {{- end }}
  {{- with .Values.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

- [x] **Step 4: Render and verify**

Run:

```bash
helm template test-instance charts/dragonfly --set name=test-instance --set authentication.existingSecret=test-secret
```

Expected: a single `Dragonfly` document named `test-instance-dragonfly`, `spec.replicas: 1`, `spec.resources` populated, `spec.authentication.passwordFromSecret.name: test-secret` / `key: password`. No template errors.

Then verify the no-auth path:

```bash
helm template test-instance charts/dragonfly --set name=test-instance
```

Expected: same document, but no `spec.authentication` key at all.

- [x] **Step 5: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 6: Commit**

```bash
git add charts/dragonfly/
git commit -m "feat(charts): add reusable dragonfly chart"
```

---

### Task 3: Migrate oauth2-proxy to Dragonfly (live app)

**Files:**

- Modify: `cluster/apps/system/oauth2-proxy/Chart.yaml`
- Modify: `cluster/apps/system/oauth2-proxy/values.yaml`

**Interfaces:**

- Consumes: `dragonfly` chart's values contract (Task 2) — `name`, `authentication.existingSecret`, `authentication.existingSecretKey`.
- Produces: Service `oauth2-proxy-dragonfly.oauth2-proxy.svc.cluster.local:6379`, authenticated with the existing `oauth-secret`/`redis-password` key (no Bitwarden changes needed).

- [x] **Step 1: Add the dependency**

In `cluster/apps/system/oauth2-proxy/Chart.yaml`, add the dependency:

```yaml
---
apiVersion: v2
name: oauth2-proxy-subchart
type: application
version: 1.0.0
appVersion: "7.2.0"
dependencies:
  - name: oauth2-proxy
    version: 10.7.0
    repository: https://oauth2-proxy.github.io/manifests
  - name: dragonfly
    version: 1.0.0
    repository: file://../../../../charts/dragonfly/
```

- [x] **Step 2: Remove the redis-ha block, add the dragonfly block, disable waitForRedis, repoint sessionStorage**

In `cluster/apps/system/oauth2-proxy/values.yaml`, delete the entire `redis-ha:` block (from `redis-ha:` through the `hostPath:` sub-block, i.e. everything currently between `redis-ha:` and `initContainers:`), and make these changes:

```yaml
sessionStorage:
  type: redis
  redis:
    clientType: standalone
    existingSecret: oauth-secret
    passwordKey: redis-password
    standalone:
      connectionUrl: redis://oauth2-proxy-dragonfly.oauth2-proxy.svc.cluster.local:6379
initContainers:
  waitForRedis:
    enabled: false
```

`sessionStorage.redis.standalone.connectionUrl` is the chart's native field for this (confirmed from the `oauth2-proxy` chart v10.7.0 `values.yaml`: "URL of redis standalone server for redis session storage (e.g. `redis://HOST[:PORT]`). Automatically generated if not set" — it's only auto-generated when the bundled `redis-ha`/`redis` subchart is enabled, which it no longer is here, so it must be set explicitly).

Then add, as a top-level sibling of `oauth2-proxy:` (i.e. same nesting level as `host:`):

```yaml
dragonfly:
  name: oauth2-proxy
  authentication:
    existingSecret: oauth-secret
    existingSecretKey: redis-password
```

- [x] **Step 3: Fetch dependencies and render**

```bash
cd /workspaces/home-ops/cluster/apps/system/oauth2-proxy
helm dependency build
helm template oauth2-proxy . -f values.yaml
```

Expected: a `Dragonfly` document named `oauth2-proxy-dragonfly` with `authentication.passwordFromSecret.name: oauth-secret` / `key: redis-password`; the oauth2-proxy `Deployment` has no `redis-ha` StatefulSet alongside it; the redis connection host in the rendered oauth2-proxy config/env points at `oauth2-proxy-dragonfly.oauth2-proxy.svc.cluster.local`; no `waitForRedis` init container present. No template errors.

- [x] **Step 4: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 5: Commit, push, open PR**

```bash
git add cluster/apps/system/oauth2-proxy/
git commit -m "feat(oauth2-proxy): migrate session redis to Dragonfly"
git push -u origin feat/dragonfly-oauth2-proxy
gh pr create --title "feat: migrate oauth2-proxy sessions to Dragonfly" --body "$(cat <<'EOF'
## Summary
- Replaces oauth2-proxy's bundled redis-ha (sentinel, quorum 1 — not real HA anyway) with a Dragonfly instance via the new operator
- Reuses the existing `oauth-secret`/`redis-password` Bitwarden-backed secret, no new secrets needed

See `docs/superpowers/specs/2026-07-08-dragonfly-operator-design.md` for full design context.

## Test plan
- [x] `helm template` renders clean (done locally, see commits)
- [ ] After merge: confirm `oauth2-proxy-dragonfly` pod healthy in `oauth2-proxy` namespace
- [ ] After merge: confirm oauth2-proxy pod is not crash-looping and connects to the new Dragonfly instance
- [ ] After merge: full login round-trip through oauth2-proxy succeeds (session survives a page reload)
- [ ] After merge: confirm old `redis-ha`/sentinel pods and PVCs are gone (no orphaned resources)
EOF
)"
```

**STOP HERE.** Do not proceed to Task 4 until the user has merged this PR and confirmed the live-cluster checks in the PR's test plan pass.

---

### Task 4: Migrate Nextcloud to Dragonfly (live app)

**Files:**

- Modify: `cluster/apps/default/nextcloud/app/Chart.yaml`
- Modify: `cluster/apps/default/nextcloud/app/values.yaml`

**Interfaces:**

- Consumes: `dragonfly` chart's values contract (Task 2); depends on Task 3's PR being merged and verified first (per the stop-gate), though this task is otherwise independent of oauth2-proxy technically.
- Produces: Service `nextcloud-dragonfly.nextcloud.svc.cluster.local:6379`, authenticated with the existing `nextcloud-redis-auth`/`redis-password` key (no Bitwarden changes needed).

- [x] **Step 1: Confirm the Task 3 gate was actually passed**

Before editing anything, confirm with the user that Task 3's PR is merged and oauth2-proxy is stable on Dragonfly. If not, stop and wait.

- [x] **Step 2: Add the dependency**

In `cluster/apps/default/nextcloud/app/Chart.yaml`, add the dependency:

```yaml
---
apiVersion: v2
name: nextcloud-subchart
type: application
version: 1.0.0
appVersion: "34.0.1"
dependencies:
  - name: nextcloud
    version: 9.2.0
    repository: https://nextcloud.github.io/helm/
  - name: pgsql-cnpg
    version: 1.3.2
    repository: file://../../../../../charts/pgsql-cnpg/
  - name: dragonfly
    version: 1.0.1
    repository: file://../../../../../charts/dragonfly/
```

- [x] **Step 3: Replace the redis block, add externalRedis + dragonfly**

In `cluster/apps/default/nextcloud/app/values.yaml`, replace:

```yaml
# NOTE: chart 9.2.0's templates/_helpers.tpl `nextcloud.env.redis` takes the
# `redis.enabled` branch whenever it is true, completely ignoring `externalRedis.*`
# (that block only applies when `redis.enabled: false`). So there is no
# `externalRedis` section here — it would be dead configuration that misleadingly
# implies a secretKeyRef-based password lookup that never happens.
#
# With `redis.enabled: true`, the bundled Bitnami Redis subchart deploys its own
# in-cluster, ClusterIP-only Redis (service `nextcloud-redis-master`). Setting
# `auth.existingSecret` below (verified via `helm template` against the subchart's
# templates/secret.yaml + _helpers.tpl `redis.secretName`/`redis.secretPasswordKey`)
# suppresses the subchart's own auto-generated Secret and makes both the Redis
# server (StatefulSet) and the Nextcloud app container's REDIS_HOST_PASSWORD env var
# read the password from the same ExternalSecret-managed Secret below, so no
# plaintext credential is committed here.
redis:
  enabled: true
  auth:
    enabled: true
    existingSecret: nextcloud-redis-auth
    existingSecretPasswordKey: redis-password
```

with:

```yaml
# Redis is now provided by a per-app Dragonfly instance (see `dragonfly:` block
# below), not the bundled Bitnami subchart. Setting `redis.enabled: false` makes
# `nextcloud.env.redis` take the `externalRedis` branch instead (confirmed via
# the chart's templates/_helpers.tpl) so REDIS_HOST/REDIS_HOST_PORT/REDIS_HOST_PASSWORD
# get wired to the Dragonfly service below.
redis:
  enabled: false
externalRedis:
  enabled: true
  host: nextcloud-dragonfly
  port: 6379
  existingSecret:
    enabled: true
    secretName: nextcloud-redis-auth
    passwordKey: redis-password
```

Then add, as a top-level sibling of `nextcloud:` (same nesting level as `pgsql-cnpg:`):

```yaml
dragonfly:
  name: nextcloud
  authentication:
    existingSecret: nextcloud-redis-auth
    existingSecretKey: redis-password
```

- [x] **Step 4: Fetch dependencies and render**

```bash
cd /workspaces/home-ops/cluster/apps/default/nextcloud/app
helm dependency build
helm template nextcloud . -f values.yaml | grep -A3 "REDIS_HOST"
```

Expected: `REDIS_HOST` = `nextcloud-dragonfly`, `REDIS_HOST_PORT` = `"6379"`, `REDIS_HOST_PASSWORD` sourced via `secretKeyRef` from `nextcloud-redis-auth`/`redis-password`. Also confirm a `Dragonfly` document named `nextcloud-dragonfly` is present, and no Bitnami `redis` StatefulSet/Secret is rendered. No template errors.

- [x] **Step 5: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 6: Commit, push, open PR**

```bash
git add cluster/apps/default/nextcloud/app/
git commit -m "feat(nextcloud): migrate redis cache/locking to Dragonfly"
git push -u origin feat/dragonfly-nextcloud
gh pr create --title "feat: migrate Nextcloud redis to Dragonfly" --body "$(cat <<'EOF'
## Summary
- Replaces Nextcloud's bundled Bitnami redis subchart with a Dragonfly instance via the operator
- Reuses the existing `nextcloud-redis-auth`/`redis-password` Bitwarden-backed secret, no new secrets needed

See `docs/superpowers/specs/2026-07-08-dragonfly-operator-design.md` for full design context.

## Test plan
- [x] `helm template` renders clean, confirmed REDIS_HOST/REDIS_HOST_PORT/REDIS_HOST_PASSWORD wiring (done locally, see commits)
- [ ] After merge: confirm `nextcloud-dragonfly` pod healthy in `nextcloud` namespace
- [ ] After merge: confirm Nextcloud pod restarts cleanly and connects to the new Dragonfly instance (check logs for redis connection errors)
- [ ] After merge: Nextcloud web UI loads, login works, file browsing works (exercises the cache/locking path)
- [ ] After merge: confirm old Bitnami redis StatefulSet/Service/PVC are gone (no orphaned resources)
EOF
)"
```

**STOP HERE.** Do not proceed to Task 5 until the user has merged this PR and confirmed the live-cluster checks in the PR's test plan pass.

---

### Task 5: Wire Harbor for Dragonfly (disabled app)

**Files:**

- Modify: `cluster/apps/default/harbor/Chart.yaml`
- Modify: `cluster/apps/default/harbor/values.yaml`
- Create: `cluster/apps/default/harbor/templates/dragonfly-externalsecret.yaml`

**Interfaces:**

- Consumes: `dragonfly` chart's values contract (Task 2).
- Produces: Service `harbor-dragonfly.harbor.svc.cluster.local:6379`, a new `harbor-dragonfly-auth` Secret (key `REDIS_PASSWORD`, matching Harbor's chart requirement that "if using existingSecret, the key must be REDIS_PASSWORD").
- Note: harbor's `app-config.yaml` has `enabled: "false"` — this task prepares the app to use Dragonfly but does not require live verification, since nothing is currently running. It DOES require a new Bitwarden secret, which needs explicit user confirmation per Global Constraints.

- [x] **Step 1: Confirm the Task 4 gate was actually passed**

Before editing anything, confirm with the user that Task 4's PR is merged and Nextcloud is stable on Dragonfly. If not, stop and wait.

- [x] **Step 2: Confirm creating a new Bitwarden secret with the user**

Ask the user to confirm before proceeding: this task needs a new Bitwarden Secrets Manager entry for Harbor's Dragonfly password (no existing entry today). Get explicit confirmation, then create it (a strong random password, e.g. `openssl rand -base64 32`) and record the resulting entry's UUID for Step 4. If the user prefers to create it themselves, wait for them to provide the UUID before proceeding.

- [x] **Step 3: Add the dependency**

In `cluster/apps/default/harbor/Chart.yaml`, add the dependency:

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
  - name: dragonfly
    version: 1.0.1
    repository: file://../../../../charts/dragonfly/
```

- [x] **Step 4: Create the ExternalSecret**

Create `cluster/apps/default/harbor/templates/dragonfly-externalsecret.yaml` (replace `<BITWARDEN_UUID>` with the real ID from Step 2). The same underlying password is templated into two keys in the one target `Secret` — `REDIS_PASSWORD` because Harbor's chart requires that exact key name for `redis.external.existingSecret`, and `password` because the `dragonfly` chart's `authentication.existingSecretKey` (Step 5) reads that name:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: harbor-dragonfly-auth
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: harbor-dragonfly-auth
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        REDIS_PASSWORD: "{{ `{{ .password }}` }}"
        password: "{{ `{{ .password }}` }}"
  data:
    - secretKey: password
      remoteRef:
        key: "<BITWARDEN_UUID>" #gitleaks:allow #HARBOR_DRAGONFLY_PASSWORD
```

- [x] **Step 5: Replace the redis block, add dragonfly**

In `cluster/apps/default/harbor/values.yaml`, replace:

```yaml
redis:
  type: internal
```

with:

```yaml
redis:
  type: external
  external:
    addr: "harbor-dragonfly:6379"
    existingSecret: harbor-dragonfly-auth
```

Then add, as a top-level sibling of `harbor:` (same nesting level as `pgsql-cnpg:`):

```yaml
dragonfly:
  name: harbor
  authentication:
    existingSecret: harbor-dragonfly-auth
    existingSecretKey: password
```

- [x] **Step 6: Fetch dependencies and render**

```bash
cd /workspaces/home-ops/cluster/apps/default/harbor
helm dependency build
helm template harbor . -f values.yaml | grep -B2 -A5 "REDIS_URL\|redis"
```

Expected: a `Dragonfly` document named `harbor-dragonfly`; an `ExternalSecret` named `harbor-dragonfly-auth`; Harbor's own rendered config referencing `harbor-dragonfly:6379` as the external redis address, no internal redis StatefulSet rendered. No template errors.

- [x] **Step 7: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 8: Commit, push, open PR**

```bash
git add cluster/apps/default/harbor/
git commit -m "feat(harbor): wire Dragonfly as external redis"
git push -u origin feat/dragonfly-harbor
gh pr create --title "feat: wire Harbor for Dragonfly" --body "$(cat <<'EOF'
## Summary
- Replaces Harbor's bundled internal redis with a Dragonfly instance via the operator
- Harbor is currently `enabled: false` — this is prep work, not a live cutover; live verification happens whenever Harbor is re-enabled

## Test plan
- [x] `helm template` renders clean (done locally, see commits)
- [ ] No live verification — app is disabled. Re-verify when Harbor is next enabled.
EOF
)"
```

No stop-gate here — harbor isn't live, so there's nothing to verify in production. Proceed to Task 6 once this PR is merged (or in parallel, if the user prefers).

---

### Task 6: Wire Gitea for Dragonfly (disabled app)

**Files:**

- Modify: `cluster/apps/default/gitea/Chart.yaml`
- Modify: `cluster/apps/default/gitea/values.yaml`
- Modify: `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`
- Create: `cluster/apps/default/gitea/templates/dragonfly-externalsecret.yaml`

**Interfaces:**

- Consumes: `dragonfly` chart's values contract (Task 2).
- Produces: Service `gitea-dragonfly.gitea.svc.cluster.local:6379`, a new `gitea-dragonfly-auth` Secret (key `redis-password`), and (as a side effect) removes the currently-hardcoded plaintext `:gitea@` password from the three `redis+cluster://` connection strings.
- Note: gitea's `app-config.yaml` has `enabled: "false"` — same reasoning as Task 5, no live verification required, new Bitwarden secret needs confirmation.

- [x] **Step 1: Confirm creating a new Bitwarden secret with the user**

Same as Task 5 Step 2 — confirm with the user before creating a new Bitwarden entry for Gitea's Dragonfly password. Get the resulting UUID before proceeding.

- [x] **Step 2: Add the dependency**

In `cluster/apps/default/gitea/Chart.yaml`, add the dependency:

```yaml
---
apiVersion: v2
name: gitea-subchart
type: application
version: 1.0.0
appVersion: "1.16.1"
dependencies:
  - name: gitea
    version: 12.6.0
    repository: https://dl.gitea.io/charts/
  - name: pgsql-cnpg
    version: 1.3.2
    repository: file://../../../../charts/pgsql-cnpg/
  - name: dragonfly
    version: 1.0.1
    repository: file://../../../../charts/dragonfly/
```

- [x] **Step 3: Add the token to the central `cluster-secrets` ExternalSecret**

Every `<secret:key>` token used anywhere in this repo (e.g. `<secret:private-domain>`, `<secret:harbor-admin-password>`) resolves through **one centralized** `ExternalSecret` at `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml` — the `argocd-secret-replacer` CMP plugin reads from the `cluster-secrets` Secret it produces. A new token requires a new entry here, not just a per-app `ExternalSecret`. Add (using the real Bitwarden UUID from Step 1 — this is the **same** UUID used again in Step 4's per-app secret, since it's the same underlying password consumed two different ways):

```yaml
- secretKey: gitea-dragonfly-password
  remoteRef:
    key: "<BITWARDEN_UUID>" #gitleaks:allow #GITEA_DRAGONFLY_PASSWORD
```

Append this to the end of the `data:` list in `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`.

- [x] **Step 4: Create the per-app ExternalSecret**

Create `cluster/apps/default/gitea/templates/dragonfly-externalsecret.yaml` (same Bitwarden UUID from Step 1/3 — this feeds the `Dragonfly` CR's `authentication.passwordFromSecret`, a separate consumption path from the `<secret:key>` token mechanism used in Step 5's connection strings):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gitea-dragonfly-auth
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: gitea-dragonfly-auth
    creationPolicy: Owner
  data:
    - secretKey: redis-password
      remoteRef:
        key: "<BITWARDEN_UUID>" #gitleaks:allow #GITEA_DRAGONFLY_PASSWORD
```

- [x] **Step 5: Replace the valkey block, update connection strings, add dragonfly**

In `cluster/apps/default/gitea/values.yaml`, under the `gitea:` key, replace:

```yaml
session:
  PROVIDER: redis-cluster
  PROVIDER_CONFIG: redis+cluster://:gitea@gitea-redis-cluster-headless.gitea.svc.cluster.local:6379/0?pool_size=100&idle_timeout=180s&
cache:
  ENABLED: true
  ADAPTER: redis-cluster
  HOST: redis+cluster://:gitea@gitea-redis-cluster-headless.gitea.svc.cluster.local:6379/0?pool_size=100&idle_timeout=180s&
queue:
  TYPE: redis
  CONN_STR: redis+cluster://:gitea@gitea-redis-cluster-headless.gitea.svc.cluster.local:6379/0?pool_size=100&idle_timeout=180s&
```

with (using `redis://` since Dragonfly is a single instance, not a cluster — `redis+cluster://` is no longer correct):

```yaml
session:
  PROVIDER: redis
  PROVIDER_CONFIG: redis://:<secret:gitea-dragonfly-password>@gitea-dragonfly.gitea.svc.cluster.local:6379/0?pool_size=100&idle_timeout=180s&
cache:
  ENABLED: true
  ADAPTER: redis
  HOST: redis://:<secret:gitea-dragonfly-password>@gitea-dragonfly.gitea.svc.cluster.local:6379/0?pool_size=100&idle_timeout=180s&
queue:
  TYPE: redis
  CONN_STR: redis://:<secret:gitea-dragonfly-password>@gitea-dragonfly.gitea.svc.cluster.local:6379/0?pool_size=100&idle_timeout=180s&
```

and replace:

```yaml
valkey-cluster:
  enabled: false
valkey:
  enabled: true
```

with:

```yaml
valkey-cluster:
  enabled: false
valkey:
  enabled: false
```

Then add, as a top-level sibling of `gitea:` (same nesting level as `pgsql-cnpg:`):

```yaml
dragonfly:
  name: gitea
  authentication:
    existingSecret: gitea-dragonfly-auth
    existingSecretKey: redis-password
```

- [x] **Step 6: Fetch dependencies and render**

```bash
cd /workspaces/home-ops/cluster/apps/default/gitea
helm dependency build
helm template gitea . -f values.yaml | grep -B2 -A2 "PROVIDER_CONFIG\|CONN_STR\|redis://"
```

Expected: all three connection strings show `redis://:<secret:gitea-dragonfly-password>@gitea-dragonfly.gitea.svc.cluster.local:6379/0?...` (the `<secret:...>` token is expected to remain literally unresolved by `helm template` — it's substituted later by the `argocd-secret-replacer` CMP plugin, not by Helm); a `Dragonfly` document named `gitea-dragonfly`; an `ExternalSecret` named `gitea-dragonfly-auth`; no `valkey` StatefulSet rendered. No template errors.

Then verify the central secrets file separately:

```bash
kubectl kustomize cluster/apps/core/argocd/resources/.. 2>/dev/null | grep -A2 "secretKey: gitea-dragonfly-password" || \
  grep -A2 "secretKey: gitea-dragonfly-password" cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml
```

Expected: the new entry is present with the correct `remoteRef.key` UUID.

- [x] **Step 7: Lint**

Run: `task lint:all`
Expected: no errors.

- [x] **Step 8: Commit, push, open PR**

```bash
git add cluster/apps/default/gitea/ cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml
git commit -m "feat(gitea): wire Dragonfly for session/cache/queue, drop hardcoded redis password"
git push -u origin feat/dragonfly-gitea
gh pr create --title "feat: wire Gitea for Dragonfly" --body "$(cat <<'EOF'
## Summary
- Replaces Gitea's bundled valkey subchart with a Dragonfly instance via the operator
- Fixes a pre-existing hardcoded plaintext redis password (`:gitea@...`) as a side effect
- Gitea is currently `enabled: false` — this is prep work, not a live cutover; live verification happens whenever Gitea is next enabled

## Test plan
- [x] `helm template` renders clean, confirmed connection strings and secret wiring (done locally, see commits)
- [ ] No live verification — app is disabled. Re-verify when Gitea is next enabled.
EOF
)"
```

No stop-gate here — gitea isn't live either. This is the final task in this plan.

---

## Post-plan follow-up (not part of this plan's scope)

- When Harbor or Gitea are next re-enabled, re-verify their Dragonfly wiring live (pod health, actual connectivity, a functional smoke test) before considering the migration complete for that app — Tasks 5/6 only verified via `helm template`.
- Once all four apps are confirmed stable on Dragonfly, this is a good moment to check whether `charts/dragonfly`'s default `resources` block (128Mi/256Mi, 50m/250m cpu) needs per-app tuning — start conservative and adjust based on observed usage, same lesson learned the hard way in the RabbitMQ migration (see `docs/superpowers/plans/2026-07-06-rabbitmq-operator.md`, Deviation 3).
