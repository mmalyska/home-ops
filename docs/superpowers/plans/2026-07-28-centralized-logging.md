# Centralized Logging (Loki + Grafana Alloy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy Grafana Loki + Grafana Alloy into the cluster's `monitoring` namespace so Kubernetes pod logs and the Asus (Merlin) router's syslog stream are durably stored (30 days) and queryable from the existing Grafana.

**Architecture:** One Loki instance (monolithic/`SingleBinary` mode, `ceph-block`-backed PVC) as the log store. Two Grafana Alloy deployments push into it: a DaemonSet that tails Kubernetes pod logs via the Kubernetes API, and a single-replica Deployment exposing a `LoadBalancer` UDP syslog listener for the router. Grafana (already running via `prometheus-stack`) gets Loki added as a datasource.

**Tech Stack:** Helm charts `grafana/loki` (7.1.0), `grafana/alloy` (1.11.0), ArgoCD ApplicationSet auto-discovery, Cilium LB-IPAM for the syslog receiver's stable IP.

## Global Constraints

- All new resources live in the existing `monitoring` namespace — do not create a new namespace (`CreateNamespace=true` is already a global ArgoCD syncOption; `monitoring`'s pod-security labels are already set by `prometheus-stack`'s `app-config.yaml`).
- Loki retention: `720h` (30 days), enforced by the in-process compactor against a single `ceph-block` PVC, `50Gi`.
- No Loki ruler/alerting, no new Grafana dashboards, no S3 backend, no router-side automation — all explicit non-goals in the design spec (`docs/superpowers/specs/2026-07-27-logging-design.md`).
- Every chart/values change must be verified with a local `helm dependency update` + `helm template` render before committing (per `CLAUDE.md` verification rule) — commands and expected output are given in each task below; all were already dry-run validated while writing this plan.
- Branch: work continues on the existing `feat/centralized-logging` branch (already pushed, draft PR #4698 open). Do not open a new branch.
- Never run `kubectl apply`, `argocd app sync`, or otherwise mutate the live cluster without explicit user confirmation — this plan's tasks stop at "committed to the branch"; live verification (Task 6) happens only after the user confirms the PR should be merged/synced.

---

### Task 1: Loki app scaffold

**Files:**
- Create: `cluster/apps/system/loki/app-config.yaml`
- Create: `cluster/apps/system/loki/Chart.yaml`
- Create: `cluster/apps/system/loki/values.yaml`

**Interfaces:**
- Produces: a `Service` named `loki` in namespace `monitoring`, port `3100`, path `/loki/api/v1/push` for writes — Tasks 2, 3, and 4 all point at `http://loki.monitoring.svc.cluster.local:3100`.

- [ ] **Step 1: Create `cluster/apps/system/loki/app-config.yaml`**

```yaml
- enabled: "true"
  namespace: monitoring
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

- [ ] **Step 2: Create `cluster/apps/system/loki/Chart.yaml`**

```yaml
apiVersion: v2
name: loki-subchart
type: application
version: 1.0.0
appVersion: "3.6.8"
dependencies:
  - name: loki
    version: 7.1.0
    repository: https://grafana.github.io/helm-charts
```

- [ ] **Step 3: Create `cluster/apps/system/loki/values.yaml`**

```yaml
loki:
  loki:
    auth_enabled: false
    commonConfig:
      replication_factor: 1
    schemaConfig:
      configs:
        - from: "2024-01-01"
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: loki_index_
            period: 24h
    storage:
      type: filesystem
    limits_config:
      retention_period: 720h
    compactor:
      retention_enabled: true
      delete_request_store: filesystem
  deploymentMode: SingleBinary
  singleBinary:
    replicas: 1
    persistence:
      enabled: true
      storageClass: ceph-block
      size: 50Gi
  # Zero out the SimpleScalable (SSD) targets — SingleBinary mode runs
  # everything in one pod, matching this cluster's small scale.
  backend:
    replicas: 0
  read:
    replicas: 0
  write:
    replicas: 0
  ingester:
    replicas: 0
  querier:
    replicas: 0
  queryFrontend:
    replicas: 0
  queryScheduler:
    replicas: 0
  distributor:
    replicas: 0
  compactor:
    replicas: 0
  indexGateway:
    replicas: 0
  bloomGateway:
    replicas: 0
  bloomPlanner:
    replicas: 0
  bloomBuilder:
    replicas: 0
  gateway:
    enabled: false
  minio:
    enabled: false
  # Memcached-backed caches aren't worth the extra ~2Gi RAM at this log volume.
  resultsCache:
    enabled: false
  chunksCache:
    enabled: false
  test:
    enabled: false
  lokiCanary:
    enabled: false
```

- [ ] **Step 4: Render and verify**

```bash
cd cluster/apps/system/loki
helm dependency update .
helm template loki . -n monitoring -f values.yaml > /tmp/loki-rendered.yaml
grep -A3 'storageClassName: ceph-block' /tmp/loki-rendered.yaml
```

Expected: shows `storage: "50Gi"` under the `ceph-block` storage class block, and the command exits 0 with no Helm errors.

- [ ] **Step 5: Commit**

```bash
git add cluster/apps/system/loki/
git commit -m "feat(loki): add Loki log store (SingleBinary, 30-day retention)"
```

---

### Task 2: Alloy DaemonSet — Kubernetes pod log collection

**Files:**
- Create: `cluster/apps/system/alloy/app-config.yaml`
- Create: `cluster/apps/system/alloy/k8s-logs/Chart.yaml`
- Create: `cluster/apps/system/alloy/k8s-logs/values.yaml`

**Interfaces:**
- Consumes: Loki write endpoint from Task 1 (`http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`).
- Produces: nothing consumed by later tasks — `app-config.yaml` created here is *modified* (appended to) by Task 3.

- [ ] **Step 1: Create `cluster/apps/system/alloy/app-config.yaml`**

```yaml
- enabled: "true"
  appSubfolder: k8s-logs
  namespace: monitoring
  syncWave: "1"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

`syncWave: "1"` deploys Alloy after Loki's default wave (`0`), so the write target exists first — not load-bearing for correctness (Alloy retries), just avoids a noisy first sync.

- [ ] **Step 2: Create `cluster/apps/system/alloy/k8s-logs/Chart.yaml`**

```yaml
apiVersion: v2
name: alloy-k8s-logs-subchart
type: application
version: 1.0.0
appVersion: "v1.18.0"
dependencies:
  - name: alloy
    version: 1.11.0
    repository: https://grafana.github.io/helm-charts
```

- [ ] **Step 3: Create `cluster/apps/system/alloy/k8s-logs/values.yaml`**

```yaml
alloy:
  alloy:
    configMap:
      content: |
        discovery.kubernetes "pod" {
          role = "pod"
          selectors {
            role  = "pod"
            field = "spec.nodeName=" + coalesce(sys.env("HOSTNAME"), constants.hostname)
          }
        }

        discovery.relabel "pod_logs" {
          targets = discovery.kubernetes.pod.targets

          rule {
            source_labels = ["__meta_kubernetes_namespace"]
            action        = "replace"
            target_label  = "namespace"
          }

          rule {
            source_labels = ["__meta_kubernetes_pod_name"]
            action        = "replace"
            target_label  = "pod"
          }

          rule {
            source_labels = ["__meta_kubernetes_pod_container_name"]
            action        = "replace"
            target_label  = "container"
          }

          rule {
            source_labels = ["__meta_kubernetes_namespace", "__meta_kubernetes_pod_container_name"]
            action        = "replace"
            target_label  = "job"
            separator     = "/"
            replacement   = "$1"
          }
        }

        loki.source.kubernetes "pod_logs" {
          targets    = discovery.relabel.pod_logs.output
          forward_to = [loki.write.loki.receiver]
        }

        loki.write "loki" {
          endpoint {
            url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
          }
        }
  controller:
    type: daemonset
```

Uses `loki.source.kubernetes` (reads via the Kubernetes API `pods/log` subresource, like `kubectl logs`) rather than mounting `/var/log` from the host — no hostPath mount, no extra RBAC (the Alloy chart's default `rbac.create: true` already grants `get`/`list`/`watch` on `pods`, `pods/log`, `namespaces` for exactly this component). The `field = "spec.nodeName=" + ...` selector restricts each DaemonSet pod to its own node's pods, per Alloy's documented best practice.

- [ ] **Step 4: Render and verify**

```bash
cd cluster/apps/system/alloy/k8s-logs
helm dependency update .
helm template alloy-k8s-logs . -n monitoring -f values.yaml > /tmp/alloy-k8s-logs-rendered.yaml
grep -n "kind: DaemonSet" /tmp/alloy-k8s-logs-rendered.yaml
```

Expected: one `kind: DaemonSet` match, command exits 0 with no Helm errors.

- [ ] **Step 5: Commit**

```bash
git add cluster/apps/system/alloy/
git commit -m "feat(alloy): add DaemonSet for Kubernetes pod log collection"
```

---

### Task 3: Alloy Deployment — router syslog receiver

**Files:**
- Modify: `cluster/apps/system/alloy/app-config.yaml` (append second list entry)
- Create: `cluster/apps/system/alloy/router-syslog/Chart.yaml`
- Create: `cluster/apps/system/alloy/router-syslog/values.yaml`

**Interfaces:**
- Consumes: Loki write endpoint from Task 1 (same URL as Task 2).
- Produces: a `LoadBalancer` Service on `192.168.48.24:1514/udp` — this is the address the Asus router's Merlin firmware will be pointed at (manual step, Task 6/router side, not part of this repo).

- [ ] **Step 1: Confirm `192.168.48.24` is still unallocated**

```bash
grep -rh "192\.168\.48\.\(2[0-9]\|3[0-9]\|4[0-9]\|50\)" cluster/apps --include="*.yaml"
```

Expected: no line shows `.24`. (As of design time, used IPs in the `192.168.48.20`-`.50` Cilium LB-IPAM pool were `.20`-`.23`, `.27`-`.29`.) If `.24` now appears, pick the next free IP in the pool and use it consistently in Step 3 below.

- [ ] **Step 2: Append to `cluster/apps/system/alloy/app-config.yaml`**

```yaml
- enabled: "true"
  appSubfolder: router-syslog
  namespace: monitoring
  syncWave: "1"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

The file must remain a single YAML list with both this entry and the `k8s-logs` entry from Task 2.

- [ ] **Step 3: Create `cluster/apps/system/alloy/router-syslog/Chart.yaml`**

```yaml
apiVersion: v2
name: alloy-router-syslog-subchart
type: application
version: 1.0.0
appVersion: "v1.18.0"
dependencies:
  - name: alloy
    version: 1.11.0
    repository: https://grafana.github.io/helm-charts
```

- [ ] **Step 4: Create `cluster/apps/system/alloy/router-syslog/values.yaml`**

```yaml
alloy:
  alloy:
    configMap:
      content: |
        loki.source.syslog "router" {
          listener {
            address       = "0.0.0.0:1514"
            protocol      = "udp"
            syslog_format = "rfc3164"
            labels        = { source = "asus-router" }
          }

          forward_to = [loki.write.loki.receiver]
        }

        loki.write "loki" {
          endpoint {
            url = "http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push"
          }
        }
    extraPorts:
      - name: syslog-udp
        port: 1514
        targetPort: 1514
        protocol: UDP
  controller:
    type: deployment
    replicas: 1
  service:
    enabled: true
    type: LoadBalancer
    annotations:
      lbipam.cilium.io/ips: "192.168.48.24"
```

`syslog_format = "rfc3164"` targets Asuswrt-Merlin's BusyBox syslogd, which emits legacy BSD syslog (RFC3164), not the modern structured RFC5424 format. If Task 6's live test shows malformed/unparsed entries, check the router's actual wire format and switch to `syslog_format = "raw"` (requires `stability.level = "experimental"` on the Alloy component — see `loki.source.syslog` docs) as a fallback.

- [ ] **Step 5: Render and verify**

```bash
cd cluster/apps/system/alloy/router-syslog
helm dependency update .
helm template alloy-router-syslog . -n monitoring -f values.yaml > /tmp/alloy-router-syslog-rendered.yaml
grep -B2 -A15 "type: LoadBalancer" /tmp/alloy-router-syslog-rendered.yaml
```

Expected: shows `lbipam.cilium.io/ips: 192.168.48.24` annotation and a `syslog-udp` port `1514/UDP` in the same Service block.

- [ ] **Step 6: Commit**

```bash
git add cluster/apps/system/alloy/
git commit -m "feat(alloy): add router syslog receiver (LoadBalancer, UDP 1514)"
```

---

### Task 4: Grafana Loki datasource

**Files:**
- Modify: `cluster/apps/system/prometheus-stack/values.yaml`

**Interfaces:**
- Consumes: Loki Service from Task 1 (`http://loki.monitoring.svc.cluster.local:3100`).

- [ ] **Step 1: Insert `additionalDataSources` into the existing `grafana:` block**

In `cluster/apps/system/prometheus-stack/values.yaml`, the `grafana:` block runs from the `grafana:` key to just before the `alertmanager:` key (confirmed at lines 13-139 as of this writing). Insert this immediately before the `  alertmanager:` line, at the same 4-space indent as `dashboardProviders:`:

```yaml
    additionalDataSources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.monitoring.svc.cluster.local:3100
        isDefault: false
```

- [ ] **Step 2: Render and verify**

```bash
cd cluster/apps/system/prometheus-stack
helm dependency update .
helm template prometheus-stack . -n monitoring -f values.yaml > /tmp/prom-rendered.yaml
sed -n '/name: prometheus-stack-kube-prom-grafana-datasource/,/^---/p' /tmp/prom-rendered.yaml | grep -i "loki"
```

Expected: three matching lines — `name: Loki`, `type: loki`, `url: http://loki.monitoring.svc.cluster.local:3100` — inside the rendered `ConfigMap`.

- [ ] **Step 3: Commit**

```bash
git add cluster/apps/system/prometheus-stack/values.yaml
git commit -m "feat(prometheus-stack): add Loki as a Grafana datasource"
```

---

### Task 5: Docs and backlog cleanup

**Files:**
- Modify: `docs/src/index.md`
- Modify: `.plans/TODO.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Add a Tech Stack row in `docs/src/index.md`**

Insert immediately after the `kube-prometheus-stack` row (line 36 as of this writing) in the "Kubernetes" table:

```markdown
| [Grafana Loki + Alloy](https://grafana.com/oss/loki/) | Log aggregation — Kubernetes pod logs + Asus router syslog |
```

- [ ] **Step 2: Remove the completed backlog item from `.plans/TODO.md`**

Delete the entire `## Infrastructure — Logging` section (the heading and its bullet), since it's now implemented via `docs/superpowers/specs/2026-07-27-logging-design.md` and this plan.

- [ ] **Step 3: Commit**

```bash
git add docs/src/index.md .plans/TODO.md
git commit -m "docs: document centralized logging, close logging backlog item"
```

- [ ] **Step 4: Push all commits**

```bash
git push
```

---

### Task 6: Live verification (requires explicit user confirmation before merging/syncing)

This task is **not** for a subagent to execute unattended — merging the PR and letting ArgoCD sync mutates the live cluster, which requires the user's explicit go-ahead per this repo's hard rules. Once the user confirms:

- [ ] Confirm the PR (#4698) is reviewed and merge it.
- [ ] After ArgoCD syncs, confirm the Loki pod is `Running` in `monitoring`.
- [ ] Confirm the `alloy-k8s-logs` DaemonSet shows `4/4` ready (`mc1`, `mc2`, `mc3`, `nv1`).
- [ ] Generate a test log line from any pod (e.g. `kubectl -n monitoring logs deploy/loki-0` or restart any small pod) and confirm it appears in Grafana → Explore → Loki datasource within a few seconds.
- [ ] On the Asus router: Administration → System → enable "Enable Remote System Log Server", pointing at `192.168.48.24:1514` (or whichever IP Task 3 Step 1 confirmed).
- [ ] Confirm a router log line appears in Grafana Explore with label `source="asus-router"`. If entries look garbled, revisit the `syslog_format` fallback noted in Task 3 Step 4.

---

## Self-Review Notes

- **Spec coverage:** all three design-doc goals (durable K8s logs, router syslog ingestion, single Grafana query surface) are covered by Tasks 1-4; all explicit non-goals (ruler, dashboards, S3 backend, router-side scripting) are respected — none are implemented here.
- **Type/naming consistency:** the Loki write URL (`http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`) is identical across Tasks 2 and 3; the `source="asus-router"` label from Task 3 matches what Task 6's verification checks for.
- **No placeholders:** every file in Tasks 1-4 is a complete, already-rendered-and-verified values file — none are sketches.
