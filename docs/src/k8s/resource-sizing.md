# Resource requests and limits

Every container gets CPU and memory **requests** and a memory **limit**. No CPU limits.

| Setting        | Rule                                                                                         |
| -------------- | -------------------------------------------------------------------------------------------- |
| CPU request    | Typical use (p95), rounded up. It sets CPU share under contention, so keep it honest.        |
| Memory request | Typical working set (p95), rounded up.                                                       |
| Memory limit   | About 2-3x the request, above the 7-day max. A hit means an OOM kill, so leave headroom.     |
| CPU limit      | None. A CPU limit throttles bursts (ArgoCD renders, Prometheus compaction) for no real gain. |

Exceptions: `kube-system` (Talos static pods, cilium) has requests only or nothing, and the rook-ceph operator-generated
containers (`log-rotator`, `rook-discover`) cannot be set from git. nv1 sizing follows `nv1-jetson.md`.

## Autoscaling: deliberately none

- **HPA**: not used. Nearly every workload is a single replica on an RWO volume, the node count is fixed and there is
  no cluster autoscaler, so extra replicas have nowhere to go.
- **VPA**: not used in `Auto`/`Recreate` mode. It restarts pods to resize them, fights GitOps and breaks the nv1 memory
  budget. Sizing is a human decision made from the recorded data below.

## Finding the right numbers

The `resource-sizing` PrometheusRule (`prometheus-stack/templates/prometheusrule-resources.yaml`) records 7-day usage
every 30 minutes (Prometheus keeps 10 days, so 7 is the longest complete window):

| Series                                                     | Meaning                      |
| ---------------------------------------------------------- | ---------------------------- |
| `resource_audit:container_memory_working_set_bytes:p95_7d` | p95 memory per container     |
| `resource_audit:container_memory_working_set_bytes:max_7d` | peak memory                  |
| `resource_audit:container_cpu_usage_cores:p95_7d`          | p95 CPU                      |
| `resource_audit:container_memory_p95_vs_request:ratio`     | below ~0.3: request too high |
| `resource_audit:container_memory_max_vs_limit:ratio`       | above ~0.8: limit too tight  |
| `resource_audit:container_cpu_p95_vs_request:ratio`        | above 1: request too low     |

In Grafana Explore, sort descending, for example:

```promql
topk(15, resource_audit:container_memory_max_vs_limit:ratio)
```

Rows are per pod name, so a pod that was replaced in the window shows up twice; compare the current one.

## Alerts (all go to Discord)

- `ContainerMemoryNearLimit`: over 90% of the limit for 15 minutes. Covers every container; `llama-server` was excluded until 2026-10-29 (Gemma sat near its limit, LFM3-VL-2B peaks around 54% of 8Gi).
- `ContainerOOMKilled`: a restart whose last termination reason is `OOMKilled`.
- `ContainerMissingMemoryLimit`: a running container with no memory limit for 24 hours (catches new apps).
- `NodeMemoryLimitsOvercommitted`: limits on a node above 2.5x its allocatable memory.
- From the chart defaults: `CPUThrottlingHigh`, `KubeMemoryOvercommit`, `KubeCPUOvercommit`.

## Admission warning

`cluster/apps/system/resource-guardrails` is a `ValidatingAdmissionPolicy` that **warns** (never denies) when a Pod is
created without CPU/memory requests or a memory limit; `kube-system` is excluded. It prints in `kubectl` output and
lands in the API audit annotations. Do not switch the binding to `Deny`: that would block pod restarts for any app
missing a value, including cilium-adjacent and operator-generated pods.

## Where the values go

| App type                  | Where                                                                                               |
| ------------------------- | --------------------------------------------------------------------------------------------------- |
| Helm chart                | `values.yaml`, under the subchart key. Check the chart's `resources:` keys with `helm show values`. |
| Kustomize (argocd, certs) | One inline patch per workload in `kustomization.yaml`, with a `target:` (see below).                |
| CNPG database             | `pgsql-cnpg.resources` in the app's `values.yaml`.                                                  |
| Local chart (anytype)     | The container in `charts/<name>/templates/`.                                                        |

## Gotchas

- **Kustomize patches must be one document each.** ArgoCD's `secret-replacer-plugin-kustomize` runs kustomize v4.5.7,
  which rejects a multi-document file under `patches: - path:` ("unable to parse SM or JSON patch"). The plugin then
  returns no output and the app looks empty, so a sync would want to prune everything. A newer local
  `kubectl kustomize` accepts the same file, so a clean local render does not prove it works. Use inline
  `patch:` blocks with a `target:`, as in `core/argocd/kustomization.yaml`.
- **`ignoreDifferences` on `.resources` blocks the values.** With `RespectIgnoreDifferences=true` ArgoCD keeps the live
  value on sync, so the new requests are silently never applied. Do not add it unless a controller really rewrites
  resources at runtime.
- **CNPG rolls the database on any resources change.** The replica restarts first, then the primary; the app
  briefly loses its connection.
- **Verify live, not just rendered:** `kubectl get <kind> <name> -o jsonpath='{.spec.template.spec.containers[*].resources}'`.
