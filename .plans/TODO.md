# TODO

General backlog items not tied to a specific migration plan.

---

## Infrastructure — CNPG

- [ ] **Migrate CNPG clusters from `system` to `standard` + barman-cloud plugin**
  - `system` images are deprecated upstream (cloudnative-pg/postgres-containers)
  - Affected: `honchodb-cnpg` (currently `17.6-system-bookworm` as short-term fix)
  - Long-term path: deploy [plugin-barman-cloud](https://github.com/cloudnative-pg/plugin-barman-cloud) as a system app, then switch all CNPG clusters to `standard-bookworm` images
  - Other clusters (`litellm`, `gitea`, `keycloak`) use the deprecated plain `17.X` rolling tags — should also migrate to `standard` + plugin
  - Ref: https://github.com/cloudnative-pg/plugin-barman-cloud

## Daytona — Runner Migration to Dedicated Workers

- [ ] **Move Daytona runners from control-plane nodes to dedicated worker nodes** (when new workers are purchased)
  1. Add label `daytona-sandbox-c: "true"` and taint `sandbox=true:NoSchedule` to new worker node Talos configs (`provision/talos/nodes/<worker>.yaml`)
  2. Remove `daytona-sandbox-c: "true"` from `provision/talos/templates/controlplane.yaml` `machine.nodeLabels`
  3. Apply Talos config to all affected nodes — runners shift automatically, no Daytona values change needed

## Apps — Chart Upgrades

- [ ] **Jellyfin** — migrate from local custom chart to official `jellyfin/jellyfin` Helm chart
  - Upstream chart: https://github.com/jellyfin/jellyfin-helm/tree/master/charts/jellyfin
  - Current: `cluster/apps/default/jellyfin/` is a hand-rolled chart with no external dep
  - Check if official chart supports Gateway API `route:` natively (would let us drop `templates/httproute.yaml` too)
  - Review if PVC/storage config, LoadBalancer service (`192.168.48.22`), and resource requests map cleanly to new chart values
  - Do after Traefik → Envoy migration Phase 1 is stable
