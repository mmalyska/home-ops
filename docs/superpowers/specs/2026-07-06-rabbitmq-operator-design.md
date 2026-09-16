# RabbitMQ Operator — Reusable Queue Provisioning Design

**Date:** 2026-07-06
**Status:** Approved

## Goal

Provide a reusable, declarative way to provision RabbitMQ instances for apps in the cluster, mirroring the existing `charts/pgsql-cnpg/` pattern for Postgres. Use it to replace VerneMQ (currently the sole MQTT broker, used only by Home Assistant).

## Context & Decisions

- **VerneMQ → RabbitMQ (confirmed feasible):** VerneMQ's only consumer is Home Assistant, plain MQTT with 2 users (admin, home_assistant). RabbitMQ's `rabbitmq_mqtt` plugin implements MQTT 3.1/3.1.1/5 and is a well-trodden HA setup. Caveat: QoS 2 is downgraded to QoS 1 (HA/Z2M rarely use QoS 2). RabbitMQ ≥3.12 recommended for the modern native MQTT implementation.
- **OnlyOffice's bundled broker → external RabbitMQ (confirmed NOT feasible, excluded from scope):** The cluster's `charts/onlyoffice-documentserver` runs the stock Community Edition image (`onlyoffice/documentserver`). Traced through the actual `ONLYOFFICE/Docker-DocumentServer` entrypoint script (`run-document-server.sh`): `RABBITMQ_AVAILABLE` is set from `_is_commercial`, which is derived from the `PRODUCT_EDITION` **Docker build-time ARG** — empty for the `documentserver-community` build target. This means the code path that reads `AMQP_URI` never executes on the Community image; it isn't a documented restriction one can route around, it's an unreachable branch. Reaching it requires the `-ee`/`-de` image variants, which require a paid commercial license (Developer Edition: 30-day trial then a paid tier that explicitly forbids serving real end users on the cheapest tier). Not worth it just to externalize a queue — OnlyOffice keeps its bundled internal RabbitMQ/Redis untouched.
- **Operator scope — Cluster Operator only, no Messaging Topology Operator:** the user chose the leaner footprint. Per-app queue/user/vhost provisioning is handled in each consuming app's own templates (ConfigMap + `ExternalSecret`, same mechanism `vernemq/templates/external-secret.yaml` already uses today), not via Topology CRDs.
- **Instance topology — dedicated instance per app, mirrors `pgsql-cnpg` exactly:** default pattern is one `RabbitmqCluster` per owning app. This does not preclude sharing: if two apps need one broker, deploy it as its own standalone app (own directory + namespace) depending on the subchart, and have each consumer connect cross-namespace with its own independently-fetched credentials — exactly how `home-assistant` already consumes the standalone `vernemq` app today (`mqtt://vernemq.ha-vernemq.svc.cluster.local`). The subchart itself has no multi-tenancy logic; sharing is a deployment-topology choice, not a chart feature.
- **Operator source — Kustomize + upstream raw manifest, not Bitnami:** Bitnami has been sunsetting free-tier images/charts (already hit this with the OnlyOffice reference docs using `bitnamilegacy`), a real risk for a long-lived infra dependency. The official `rabbitmq/cluster-operator` project ships only a raw YAML manifest (no Helm chart), so the operator is deployed as a Kustomize-based system app pulling that release manifest as a remote resource — tracks true upstream directly, Renovate can pin/bump the release tag via a custom regex manager (existing pattern in this repo).

## Architecture

```
cluster/apps/system/rabbitmq-cluster-operator/   # new system app, Kustomize-based
  kustomization.yaml                             # remote resource: upstream cluster-operator.yml release
  app-config.yaml

charts/rabbitmq-cluster/                         # new reusable chart, mirrors charts/pgsql-cnpg/
  Chart.yaml
  values.yaml
  templates/
    rabbitmqcluster.yaml                          # RabbitmqCluster CR + optional PodMonitor

cluster/apps/home-automation/rabbitmq/           # new standalone app, replaces vernemq
  Chart.yaml            # depends on rabbitmq-cluster (file://../../../../charts/rabbitmq-cluster/)
  values.yaml           # additionalPlugins: [rabbitmq_mqtt]
  app-config.yaml       # own namespace, e.g. ha-rabbitmq
  templates/
    external-secret.yaml  # definitions.json (admin + home_assistant users), same pattern as vernemq today
```

VerneMQ (`cluster/apps/home-automation/vernemq/`) is deleted once the cutover is verified.

## Reusable Chart: `charts/rabbitmq-cluster/`

**`values.yaml`:**
```yaml
name: ""
replicas: 1
image: ""              # optional override, e.g. rabbitmq:4.1-management
storage:
  size: 5Gi
resources:
  requests:
    memory: 256Mi
    cpu: 100m
  limits:
    memory: 512Mi
    cpu: 500m
additionalPlugins: []    # e.g. [rabbitmq_mqtt] for MQTT-consuming apps
additionalConfig: ""     # raw rabbitmq.conf passthrough, e.g. for definitions import
monitoring:
  enablePodMonitor: true
```

**`templates/rabbitmqcluster.yaml`:** renders a single `RabbitmqCluster` CR named `<name>-rmq`. When `monitoring.enablePodMonitor` is true, the chart auto-appends `rabbitmq_prometheus` to the effective plugin list (callers don't need to remember it) and renders a matching `PodMonitor`. `resources`/`storage.size`/`additionalPlugins` pass through via `toYaml`, same style as `pgsql-cnpg/templates/cnpg.yaml`.

**Credentials:** the RabbitMQ Cluster Operator auto-creates a `<name>-rmq-default-user` secret (host/port/username/password), analogous to CNPG's `<name>-app` secret.

**App-specific fixed users** (e.g. a stable `home_assistant` MQTT user, not the randomly-generated default user): provisioned in the *consuming app's own templates*, not the shared chart — via RabbitMQ's "definitions import on boot" feature (a `definitions.json` mounted into the pod, referenced through `additionalConfig`/`override.statefulSet`). Exact CRD fields to be confirmed during implementation via `helm template` + docs, same as the pgsql-cnpg chart leaves some plugin-specific fields to be nailed down per use.

## Home Assistant Migration

**Cutover steps:**
1. Deploy the operator (system app) + new `rabbitmq` app (home-automation) alongside the existing `vernemq` app — different namespaces, no conflict.
2. Verify independently: `rabbitmqctl` shows both users, MQTT port reachable, `mosquitto_pub`/`sub` round-trip against the new broker.
3. Update `home-assistant/templates/secrets.yaml`: `SECRET_MQTT_HOST` → `mqtt://<name>-rmq.ha-rabbitmq.svc.cluster.local`. Credentials unchanged (same Bitwarden entries, just repointed at the new broker's definitions-imported users).
4. Restart Home Assistant, confirm the MQTT integration reconnects and devices/entities reappear. MQTT state is transient — no data migration needed, just a reconnect.
5. Once stable, delete the `vernemq` app directory and its ArgoCD Application.

**Rollback:** revert `SECRET_MQTT_HOST` back to the vernemq service name. VerneMQ stays untouched until step 5, so rollback is a one-line revert with no data-loss risk.

## Verification

Before considering any part of this done, per this repo's standing rule:
- `helm template` on both `charts/rabbitmq-cluster/` (standalone) and the `rabbitmq` app (as a dependency) — confirm rendered `RabbitmqCluster`/`PodMonitor` manifests look correct.
- `kubectl kustomize` on the `rabbitmq-cluster-operator` system app.
- `task lint:all` (yamllint, helmlint, prettier).
- Live check after deploy: MQTT connectivity test, `rabbitmqctl list_users`/`list_permissions` showing expected users, Prometheus scrape target up.

## Open Questions (for implementation-plan phase)

- Exact upstream release URL/tag format for the `rabbitmq/cluster-operator` manifest, and the right Renovate custom-regex-manager pattern to track it.
- Exact `RabbitmqCluster` CRD fields for boot-time `definitions.json` import (volume mount path, `additionalConfig` syntax) — confirm against current operator version docs during implementation.
- Confirm the Service port name(s) the operator generates for `rabbitmq_prometheus` (used by the `PodMonitor`'s `podMetricsEndpoints[].port`) and for MQTT, by rendering against a real `RabbitmqCluster` example or checking installed CRD schema.
- Whether the current cluster's Prometheus `PodMonitor` selector conventions (labels) need any adjustment to pick up RabbitMQ pods, matching how `enablePodMonitor` works for other apps (e.g. CNPG).
