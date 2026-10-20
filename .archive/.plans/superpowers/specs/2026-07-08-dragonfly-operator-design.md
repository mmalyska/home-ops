# Dragonfly Operator — Standalone Redis Replacement Design

**Date:** 2026-07-08
**Status:** Approved

## Goal

Replace the Bitnami-redis-family/Valkey instances backing Harbor, Nextcloud, oauth2-proxy, and Gitea with per-app Dragonfly instances managed by the official `dragonfly-operator`, mirroring the existing `charts/pgsql-cnpg/` reusable-chart pattern for Postgres.

## Context & Decisions

- **Survey of current redis-family usage in the repo:**
  | App | Current component | Verdict |
  |---|---|---|
  | anytype | Custom `charts/anytype` Deployment running `redis/redis-stack-server`, loads `redisbloom.so` | **Excluded.** Dragonfly does not implement the Redis module API — RedisBloom has no equivalent. Stays on redis-stack. |
  | harbor | Harbor chart's bundled internal Redis (`redis.type: internal`) | Included. Plain cache/lock usage, no modules. |
  | nextcloud | Bitnami `redis` subchart, standalone | Included. Plain cache/locking. |
  | oauth2-proxy | Bitnami `redis-ha` subchart (sentinel, replicas: 1, quorum 1 — not real HA) | Included. Session storage only. |
  | gitea | Bundled `valkey` subchart (already non-Bitnami) | Included per user request, for full consistency even though Valkey wasn't itself a pain point. Connection strings also currently carry a hardcoded plaintext password (`redis+cluster://:gitea@...`) — migrating fixes this as a side effect. |

- **Topology — one Dragonfly CR per app, not a shared instance:** user explicitly chose per-app instances over a single shared Dragonfly deployment, to preserve the current blast-radius isolation (each app's cache/session store failure is independent) at the cost of 4 small pods instead of 1.

- **Reusable chart, not one-off manifests per app:** user explicitly asked for the same `charts/pgsql-cnpg`-style subchart pattern — a single `charts/dragonfly` chart that each consuming app depends on locally, parameterized by `name`.

- **Operator distribution:** official chart is published as an OCI artifact, `oci://ghcr.io/dragonflydb/dragonfly-operator/helm`, chart `dragonfly-operator`, latest `v1.6.1` (verified via GitHub release notes: "Helm chart: oci://ghcr.io/dragonflydb/dragonfly-operator/helm"). This repo already consumes OCI helm dependencies elsewhere (`litellm` → `oci://ghcr.io/berriai`, `envoy-gateweay` → `oci://mirror.gcr.io/envoyproxy`), so no new tooling is needed.

- **CRD:** `apiVersion: dragonflydb.io/v1alpha1`, `kind: Dragonfly`. Relevant spec fields for this use case: `replicas`, `image`, `resources`, `authentication.passwordFromSecret` (a `corev1.SecretKeySelector`), `args`. Persistence fields (`snapshot.*`, `tiering.*`) exist but are unused here.

- **Persistence — none:** user confirmed in-memory only for all four instances. None of the four use cases (cache, cache, sessions, session/cache/queue) require durable storage; losing state on restart means a cache miss or a forced re-login, which is what happens today anyway since none of the current subcharts are configured with durable persistence either.

- **Rollout for live apps — straight cutover, no blue-green:** nextcloud and oauth2-proxy are both `enabled: true` today. Because there's no data worth preserving across the swap, the plan is to remove the old subchart block and add the `dragonfly:` block in the same change, rather than running both side-by-side temporarily. Verified via `helm template` before merge, per this repo's standing verification rule.

- **Secrets — reuse where they exist, defer where the app is disabled:** `nextcloud-redis-auth` (key `redis-password`) and `oauth-secret` (key `redis-password`) already exist in Bitwarden for nextcloud and oauth2-proxy respectively and will be reused as-is for `authentication.passwordFromSecret`. Harbor and gitea are both currently `enabled: "false"` — their `ExternalSecret` templates and `dragonfly:` wiring are added now so the apps are ready to go, but the actual new Bitwarden Secrets Manager entries for their passwords are deferred until each app is re-enabled (no point provisioning secrets for apps that aren't running).

## Architecture

```
cluster/apps/system/dragonfly-operator/     # new system app
  Chart.yaml            # dependency: dragonfly-operator, oci://ghcr.io/dragonflydb/dragonfly-operator/helm, v1.6.1
  app-config.yaml       # namespace: dragonfly-system, syncWave: "-5" (mirrors rabbitmq-cluster-operator: deploy before consumers)

charts/dragonfly/                           # new reusable chart, mirrors charts/pgsql-cnpg/
  Chart.yaml
  values.yaml
  templates/
    dragonfly.yaml                          # single Dragonfly CR

cluster/apps/default/nextcloud/app/         # existing app, modified
cluster/apps/system/oauth2-proxy/           # existing app, modified
cluster/apps/default/harbor/                # existing app (disabled), modified
cluster/apps/default/gitea/                 # existing app (disabled), modified
```

## Reusable Chart: `charts/dragonfly/`

**`values.yaml`:**
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
  existingSecret: ""     # secret name
  existingSecretKey: password   # key within the secret
args: []
```

**`templates/dragonfly.yaml`:** renders a single `Dragonfly` CR named `<name>-dragonfly` (parallel to `pgsql-cnpg`'s `<name>-cnpg` naming), setting `spec.replicas`, `spec.resources`, `spec.authentication.passwordFromSecret.{name,key}` from `existingSecret`/`existingSecretKey`, and passing through `args` via `toYaml` when set. No `snapshot`/persistence block is templated at all — deliberately absent, not just defaulted off, since none of the four consumers need it.

**Service naming:** the operator is expected to create a Service matching the `Dragonfly` object's name (`<name>-dragonfly`), analogous to how CNPG creates `<name>-cnpg-rw`. This is called out as unverified in Open Questions below — confirm by rendering/deploying a real instance before wiring up app connection strings.

## Per-App Changes

- **nextcloud** (`cluster/apps/default/nextcloud/app/values.yaml`): remove the `redis:` Bitnami subchart block entirely; add `dragonfly: {name: nextcloud, authentication: {existingSecret: nextcloud-redis-auth, existingSecretKey: redis-password}}` to the app's own `Chart.yaml` dependency + values; point Nextcloud's Redis host env vars at `nextcloud-dragonfly.nextcloud.svc.cluster.local`, reusing the existing `nextcloud-redis-auth` secret (same mechanism already used for the Bitnami subchart's `auth.existingSecret`, just repointed).
- **oauth2-proxy** (`cluster/apps/system/oauth2-proxy/values.yaml`): remove the `redis-ha:` block; add `dragonfly: {name: oauth2-proxy, authentication: {existingSecret: oauth-secret, existingSecretKey: redis-password}}`; update `sessionStorage.redis` host to `oauth2-proxy-dragonfly.oauth2-proxy.svc.cluster.local` (`clientType: standalone` already matches Dragonfly's single-instance model, no change needed there).
- **harbor** (`cluster/apps/default/harbor/values.yaml`, disabled): remove `redis: {type: internal}`; add `dragonfly: {name: harbor}`; switch to `redis: {type: external, external: {host: harbor-dragonfly, port: "6379", ...}}`; add a new `harbor-dragonfly-auth` `ExternalSecret` template now, but the Bitwarden entry itself is created when harbor is re-enabled.
- **gitea** (`cluster/apps/default/gitea/values.yaml`, disabled): remove `valkey: {enabled: true}`; add `dragonfly: {name: gitea}`; replace the three `redis+cluster://:gitea@gitea-redis-cluster-headless...` connection strings with `redis://:<secret:gitea-dragonfly-password>@gitea-dragonfly.gitea.svc.cluster.local:6379/0?...`, wired through the `cluster-secrets` token-substitution mechanism (`SECRET_PROVIDER: cluster-secrets` is already set in `app-config.yaml`) or a new `ExternalSecret`, decided during implementation. This also removes the pre-existing hardcoded plaintext password.

## Verification

Per this repo's standing rule, before considering any part of this done:
- `helm template` on `charts/dragonfly/` standalone, and on each of the four modified apps as a dependency.
- `kubectl kustomize` is not applicable (all four are Helm-based apps).
- `task lint:all` (yamllint, helmlint, prettier).
- For the two live apps (nextcloud, oauth2-proxy): live check after deploy — confirm the app pod connects to its `<name>-dragonfly` service, cache/session behavior works (e.g., oauth2-proxy login round-trip, Nextcloud page load), and the old subchart's resources are gone (no orphaned PVC/Secret).

## Out of Scope

- Anytype's redis-stack/RedisBloom instance.
- Making any Dragonfly instance multi-replica/HA — single replica per instance, consistent with what's effectively running today (oauth2-proxy's quorum-1 sentinel setup isn't real HA either).
- A shared/multi-tenant Dragonfly instance — explicitly rejected in favor of per-app isolation.

## Open Questions (for implementation-plan phase)

- Confirm the exact Service name/port the operator generates for a `Dragonfly` CR (assumed `<name>-dragonfly`:6379) by rendering or deploying a sample instance before wiring app connection strings.
- Confirm whether gitea's new password should flow through a dedicated `ExternalSecret` (consistent with nextcloud/oauth2-proxy) or the `cluster-secrets` token mechanism (consistent with `app-config.yaml`'s existing `SECRET_PROVIDER: cluster-secrets` setting) — the value ends up inside a connection-string field embedded in `values.yaml`, which per this repo's secrets rule (token in non-Secret field → `cluster-secrets`) points toward the token mechanism, but the password still needs to originate from a `Secret` for the `Dragonfly` CR's `authentication.passwordFromSecret` to consume it — needs both mechanisms wired together, exact shape TBD.
- Whether Harbor's `redis.type: external` config block expects a full URL, or discrete host/port/password fields — confirm against the installed Harbor chart version's values schema.
- Whether `dragonfly-operator` needs a `NetworkPolicy` allowance added anywhere in this cluster's existing NetworkPolicy setup (operator defaults `networkPolicyEnabled: true`, restricting its own admin port — should not affect app connectivity, but confirm during implementation).
- Renovate wiring for the new OCI chart dependency and the operator's own image tag — confirm it's picked up by the existing OCI-helm renovate datasource pattern already used for `litellm`/`envoy-gateweay` with no extra config.
