# Dev workspace namespace

The `dev-workspace` app (`cluster/apps/system/dev-workspace`) owns everything a Coder development workspace needs
that the Coder provisioner must not create. Plan: `.plans/remote-dev-workspace/`.

## What it creates

| Object | Purpose |
| ------ | ------- |
| Namespace `dev-workspace`, Pod Security `baseline` | Home of the workspace pods |
| PVC `<workspace>-home` (5 Gi, `ceph-block`) | Logins, config, tools added with `mise use -g`; backed up every 6 h |
| PVC `<workspace>-src` (30 Gi, `ceph-block`) | Source code under `/workspaces`; backed up daily |
| `ReplicationSource` and restic `ExternalSecret` per PVC | VolSync backups from `charts/volsync`, one restic repository per PVC |
| `ServiceAccount` `<workspace>` and `ClusterRole` `dev-workspace-reader` | Read-only Kubernetes access (explicit lists, no Secrets, no wildcard) |
| `serviceaccounts.talos.dev` `<workspace>-talos` | Talos credential with the `os:reader` role; Talos creates a Secret with the same name |
| `ExternalSecret` `<workspace>-bws` (off until configured) | `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` for the workspace |
| `Role` `dev-workspace-provisioner` | The Coder provisioner may manage Deployments here and nothing else |
| `NetworkPolicy` `default-deny-ingress` | Ingress deny-all; egress stays open |

The first workspace is `dev-workspace`. The Coder template only references these objects by name.

## Add a workspace

1. Add an entry to `workspaces` in `values.yaml`.
2. Add two aliased `volsync` dependencies to `Chart.yaml` (`volsync-<name>-home`, `volsync-<name>-src`) and the two matching
   blocks to `values.yaml`. `nameOverride` and `pvc.existingClaim` must both equal the PVC name; `nameOverride` also names the
   restic repository path.
3. Keep `restore.enabled: false` on both blocks: the claims hold live data, and the chart's restore-once destination would
   restore over the volume. Restore tests use a scratch PVC.

## Why not the built-in `view` role

`view` aggregates every rule that an operator labels `aggregate-to-view`, so it grows silently. It already includes the 18
external-secrets generator kinds, some of which can hold inline credentials. `dev-workspace-reader` lists each resource
by name instead. Add a CRD group only after reading its fields for credentials.

## Boundaries

- The workspace can read ExternalSecret specs, which contain Bitwarden references (identifiers, not values). It cannot read
  any Secret.
- Only GitOps may create `serviceaccounts.talos.dev` in this namespace: the namespace may request any role in the cluster-wide
  `KubeTalosAPIAccessConfig` list, `os:admin` included.
- Deleting a workspace, a template version or this app does not delete the PVCs (`Prune=false,Delete=false`).

## Checks after the first sync

Read-only, with `kubectl auth can-i --as=system:serviceaccount:dev-workspace:dev-workspace`: `get`, `list`, `watch` on
`pods`, `nodes`, `namespaces` answer `yes`; `get`, `list`, `watch` on `secrets`, `get` on `pods/exec`, `nodes/proxy`,
`create` on `serviceaccounts/token`, and every write verb on pods, deployments, configmaps, roles, clusterroles,
`externalsecrets` and `serviceaccounts.talos.dev` answer `no`. For the provisioner, `no` on `persistentvolumeclaims`,
`externalsecrets`, `replicationsources`, `roles` and `serviceaccounts.talos.dev` in `dev-workspace`.
