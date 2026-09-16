# Centralized Logging (Loki + Grafana Alloy) — Design

## Context

Backlog item from `.plans/TODO.md` under "Infrastructure — Logging": the
`monitoring` namespace is metrics-only (`kube-prometheus-stack` +
`smartctl-exporter`) — no Loki/Promtail/Fluent Bit/Vector anywhere in the
cluster. Surfaced while disabling rook-ceph's `logCollector` (PR #4468) to
reclaim idle resource reservation, which made Ceph component logs
`kubectl logs`-only (ephemeral, lost on pod restart/rotation).

Driving needs (in priority order):

1. Post-mortem K8s pod logs — see logs from a pod/container that already
   crashed or restarted, past `kubectl`'s ephemeral buffer.
2. Asus router logs — the router runs **Asuswrt-Merlin**, which has a
   built-in remote syslog client (System Log settings) that can point at an
   IP:port. No history exists today.
3. Cross-service correlation — search/filter logs across many pods and the
   router in one place, ideally without learning a new UI.

Cluster is heterogeneous: `mc1`/`mc2`/`mc3` are amd64 control-plane nodes;
`nv1` is an arm64 (Jetson) worker. Confirmed both `grafana/loki` and
`grafana/alloy` images are multi-arch (amd64/arm64 present in each image's
manifest on Docker Hub) — no architecture blocker for running Alloy's
DaemonSet on `nv1`.

## Goals

- Durable (30-day) storage of all Kubernetes pod logs, queryable after a
  pod/container has restarted or been deleted.
- Ingest the Merlin router's syslog stream into the same store.
- Query both from the Grafana instance that already exists
  (`cluster/apps/system/prometheus-stack`) — no new UI.

## Non-goals

- Loki ruler / alerting on log content — Prometheus already owns alerting;
  revisit only if a specific pattern needs paging that metrics can't catch.
- New dashboards beyond ad-hoc Grafana Explore usage — add one later only if
  a recurring need shows up.
- S3/object-storage backend for Loki chunks — a single `ceph-block` PVC is
  enough at this scale; migrate later only if 50Gi becomes limiting.
- Scripting the Merlin router's syslog-destination config — one-time manual
  change in the router's own UI, not something this repo manages.
- Guaranteed delivery of router syslog — UDP is fire-and-forget by design;
  an Alloy syslog-receiver outage drops messages sent during the gap. Same
  class of tradeoff already accepted for the rook-ceph `logCollector`
  decision.

## Design

### 1. Namespace & app placement

Both new apps land in the existing `monitoring` namespace (same
observability domain as `prometheus-stack`), following the standard
`cluster/apps/{category}/{app-name}/` pattern from CLAUDE.md:

- `cluster/apps/system/loki/` — `grafana/loki` chart, monolithic
  (`SingleBinary`) deployment mode.
- `cluster/apps/system/alloy/` — `grafana/alloy` chart, deployed twice via
  `appSubfolder` (multi-component pattern already used elsewhere in the
  repo): one instance as a DaemonSet for K8s log tailing, one as a
  single-replica Deployment for the router syslog receiver.

### 2. Loki (log store)

- Monolithic/single-binary mode — simplest operational model, matches the
  scale of a 3-node homelab (rejects the microservices/SSD deployment mode
  as unnecessary complexity).
- Filesystem storage backed by one `ceph-block` PVC, sized 50Gi.
- `limits_config.retention_period: 720h` (30 days), enforced by Loki's
  built-in compactor running in-process against the filesystem store — no
  separate retention infrastructure needed.
- Scheduled preferentially on an amd64 control-plane node (near the Ceph
  storage it mounts); no arm64 requirement for this component specifically.

### 3. Alloy DaemonSet (K8s pod logs)

- Runs on all 4 nodes (`mc1`-`mc3` + `nv1`), tailing container logs via
  Kubernetes pod discovery (standard `discovery.kubernetes` + log-file
  tailing pattern).
- Pushes to Loki's write endpoint (in-cluster Service, e.g.
  `loki-gateway.monitoring.svc:80` or the single-binary Service directly).
- Confirmed multi-arch: no separate arm64-specific handling needed for
  `nv1`.

### 4. Alloy syslog receiver (router logs)

- Single-replica Deployment (not part of the DaemonSet — a syslog listener
  needs one stable network target, not one instance per node).
- Runs a `loki.source.syslog` UDP listener, exposed via a
  `LoadBalancer` Service using Cilium LB-IPAM
  (`lbipam.cilium.io/ips` annotation — the pattern already used by
  jellyfin/whisper/vintagestory/etc.). Pool is `192.168.48.20`-`.50`;
  currently-used IPs are `.20`-`.23`, `.27`-`.29`, so `.24` is a candidate —
  confirm still free at implementation time.
- Tags ingested entries with a distinguishing label (e.g.
  `source="asus-router"`) so they're filterable separately from K8s logs in
  LogQL/Explore.
- The cluster's existing `CiliumL2AnnouncementPolicy`
  (`cluster/apps/core/cilium/templates/config.yaml`) already excludes `nv1`
  from serving L2 (ARP) announcements for LoadBalancer IPs, due to a known
  eBPF/NIC quirk on that node. This is pre-existing infra, not something
  this design needs to touch — the syslog receiver's LB IP will be
  announced correctly by the `mc` nodes regardless of which node the pod
  itself schedules onto.
- Router-side change (manual, out of GitOps): enable Asuswrt-Merlin's
  "Remote Syslog Server" and point it at the new LB IP/port.

### 5. Grafana integration

Add Loki as a datasource via `additionalDataSources` in
`cluster/apps/system/prometheus-stack/values.yaml`, pointing at Loki's
in-cluster query endpoint. No new Grafana instance or plugin — reuses the
one already running.

## Verification plan

- `helm template` render of both the `loki` and `alloy` charts (both
  `appSubfolder` instances) before committing, per repo convention.
- Post-deploy: confirm the Loki pod is healthy, confirm the Alloy DaemonSet
  is `Running` on all 4 nodes including `nv1`, and confirm a live test log
  line (e.g. `kubectl logs`-visible output from any pod) shows up in
  Grafana Explore within a few seconds.
- After the router-side Merlin config change: send a test event from the
  router and confirm it lands in Loki with the `source="asus-router"`
  label, within Grafana Explore.
- Retention (30 days) is a config assertion, not something practically
  testable at deploy time — confirm via the rendered Loki config showing
  `retention_period: 720h` rather than waiting a month.

## Open follow-ups (not in this implementation)

- Loki ruler/alerting on specific log patterns, if a real incident shows
  metrics-based alerting missed something logs would have caught.
- Starter Grafana dashboards for router logs / K8s error logs, if ad-hoc
  Explore usage proves insufficient after living with it a while.
- S3-compatible object storage backend for Loki, if 50Gi/30-day retention
  becomes limiting.
