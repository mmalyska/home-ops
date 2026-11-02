# Talos ServiceAccount mechanics (spike T12)

Question: what does a `talos.dev/v1alpha1` `ServiceAccount` give a pod, how long does it last, and what can `os:reader` do? Read on 2026-11-02, read-only means only: repository files and the Talos source at tag `v1.14.4` (the version in `.taskfiles/talos/Taskfile.yaml` and the tuppr `TalosUpgrade`). No cluster object was read; the live cluster was not changed.

Sources (all `siderolabs/talos`, tag `v1.14.4`):

- `internal/app/machined/pkg/controllers/kubeaccess/serviceaccount/crd_controller.go` (controller)
- `pkg/machinery/constants/constants.go` (names, paths)
- `pkg/machinery/role/role.go` (roles)
- `internal/app/machined/pkg/system/services/machined.go` (method-to-role table)
- `internal/app/resources/access.go` (resource API access policy)
- Repository: `cluster/apps/system/talos-backup/templates/cronjob.yaml`, `provision/talos/patches/controlplane/40-talos-api-access.yaml`

## How it works (verified in source)

- A controller on the control planes watches `ServiceAccount` (`talos.dev/v1alpha1`) resources. For each one it creates a Secret **with the same name and namespace**, owned by the resource (controller owner reference). If a Secret of that name already exists and is not owned by the resource, the resource gets `ErrResourceExists` and nothing is written.
- The resource needs `spec.roles` (non-empty, parsed by `role.Parse`). Otherwise `ErrRolesNotFound`.
- Two independent gates, both from `KubeTalosAPIAccessConfig`: the resource's **namespace** must be in `allowedKubernetesNamespaces` (else `ErrNamespaceNotAllowed`), and **every** requested role must be in `allowedRoles` (else `ErrRolesNotAllowed`). Failures are written to `status.failureReason` and as events; no Secret is created.
- Consequence for this plan (confirms the escalation risk in `plan.md`): any resource created in an allowed namespace can request any role in `allowedRoles`. With `os:admin` already in that list, the namespace must be locked down so that only GitOps can create `serviceaccounts.talos.dev` there.
- The Secret has one key, **`config`** (`constants.TalosconfigFilename`). It is a talosconfig with context `default`, a single endpoint **`talos.default`** (Service `talos` in namespace `default`), the cluster CA and a client certificate whose Organization is the role list.
- Default mount path used by the tooling: **`/var/run/secrets/talos.dev`**, so the file is `/var/run/secrets/talos.dev/config` (as in `talos-backup`).
- **Lifetime:** the client certificate is valid for **6 hours** (`certTTL`) and the controller regenerates it when less than **1 hour** remains (`certRenewThreshold`), when the CA or endpoint differ, or when the roles in the certificate no longer match `spec.roles`. Resources and Secrets are re-checked every minute (`informerResyncPeriod`).
- **Revocation:** removing a namespace or role from the allow-list only produces a failure status for the resource; the code does not delete the Secret. Deleting the resource removes the Secret through the owner reference, but a certificate that was already issued stays valid until it expires (at most 6 hours). I found no revocation list in this code; treat 6 hours as the worst-case exposure after a leak.

## Reference YAML for the workspace

```yaml
apiVersion: talos.dev/v1alpha1
kind: ServiceAccount
metadata:
  name: dev-workspace-talos # the Secret gets this name
  namespace: dev-workspace # must be in allowedKubernetesNamespaces
spec:
  roles:
    - os:reader # must be in allowedRoles
```

Pod side (same pattern as `talos-backup`): a `secret` volume with `secretName: dev-workspace-talos` mounted at `/var/run/secrets/talos.dev` as a directory (no `subPath`, so rotation reaches the pod), and `TALOSCONFIG=/var/run/secrets/talos.dev/config`. `talosctl` reads the file on each invocation, so rotation is invisible to it.

## What `os:reader` can do (verified in the method-to-role table)

Definition in source: "Reader … read-only APIs that do not expose secrets". Methods whose role set includes Reader (so `talosctl` commands that work):

- `Version`, `Hostname`, `Logs`, `LogsContainers`, `Dmesg`, `Events`, `Containers`, `ServiceList`, `Processes`, `Stats`, `SystemStat`, `Memory`, `LoadAvg`, `CPUInfo`, `CPUFreqStats`, `DiskStats`, `DiskUsage`, `Mounts`, `NetworkDeviceStats`, `Netstat`, `List` (directory listing), `ImageList`
- `EtcdStatus`, `EtcdMemberList`, `EtcdAlarmList`
- `cluster.ClusterService/HealthCheck`, `time.TimeService/Time`, `storage.StorageService/Disks`, `machine.ImageService/List`
- `cosi.resource.State/Get`, `List`, `Watch` (`talosctl get`), see the caveat below

Not allowed for Reader (Admin or Operator only):

- **`Kubeconfig`: Admin only.** `talosctl kubeconfig` cannot work with `os:reader`; this is why kubectl uses a Kubernetes ServiceAccount (D26) and not a kubeconfig.
- `Read` and `Copy` (file contents): Admin only.
- `Reboot`, `Restart`, `Shutdown`, `ServiceStart/Stop/Restart`, `EtcdSnapshot`, `PacketCapture`, `ImagePull`: Operator (and Admin); not Reader.
- `ApplyConfiguration`, `Upgrade`, `Reset`, `Bootstrap`, `Rollback`, `LifecycleService/*`, `EtcdRecover`, `GenerateClientConfiguration`: Admin only. (`ApplyConfiguration` lists Reader "for maintenance only, verified in the handler", so it is not available on a configured node.)
- Any method missing from the table falls back to **Admin only** (`FallbackRoles`).

Caveat for `talosctl get`: the resource API rejects all write verbs for every role, and a resource type marked `Sensitive` needs Admin (`AccessPolicy`). Which concrete types are sensitive was not enumerated here (machine config and secret resources are the expected ones). Verify in the live check.

## Consequences for the plan

1. `os:reader` is enough for the read-only Talos commands the repository's skills and audits use (version, health, logs, dmesg, services, `get` on non-sensitive types). It cannot read files, take etcd snapshots, restart anything or fetch a kubeconfig.
2. T13 adds `os:reader` to `allowedRoles` and `dev-workspace` to `allowedKubernetesNamespaces`. Existing resources (`talos-backup` with `os:etcd:backup`, tuppr with `os:admin`) are unaffected because each resource lists its own roles.
3. The talosconfig in the Secret has an endpoint but **no nodes list**, so `talosctl` needs `--nodes <ip>` (or `TALOSNODES` style flags) on each command. The local flow sets nodes with `talosctl config node` on a writable file. Check which `task talos:*` targets and skills assume nodes inside the talosconfig before relying on them in the workspace; the Secret mount is read-only, and copying the file would break rotation.
4. Revocation is by deleting the resource plus waiting up to 6 hours for the certificate to expire (no CRL found).
5. Kubernetes access is unaffected by this mechanism (D26).

## Not verified (to check in T7 or later)

- That a pod in `dev-workspace` can reach `talos.default` port 50000 (no cluster-wide egress policy was read; `talos-backup` and tuppr show pods can in general).
- The exact list of `Sensitive` resource types for `talosctl get`.
- The `ServiceAccount` resources and Secrets that exist now (the read was denied by the repository's `kubectl get serviceaccount*` rule, so none was read).
- Behaviour of `talosctl` client v1.14.5 (the version in `sandbox-devops`) against v1.14.4 nodes; the repository's `task talos:generate` requires an exact match with `TALOS_VERSION`, the workspace does not run it (D25).
