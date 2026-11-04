# Dev workspace namespace

The `dev-workspace` app (`cluster/apps/system/dev-workspace`) owns everything a Coder development workspace needs
that the Coder provisioner must not create. Plan: `.plans/remote-dev-workspace/`.

## What it creates

| Object                                                                  | Purpose                                                                               |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| Namespace `dev-workspace`, Pod Security `baseline`                      | Home of the workspace pods                                                            |
| PVC `<workspace>-home` (5 Gi, `ceph-block`)                             | Logins, config, tools added with `mise use -g`; backed up every 6 h                   |
| PVC `<workspace>-src` (30 Gi, `ceph-block`)                             | Source code under `/workspaces`; backed up daily                                      |
| `ReplicationSource` and restic `ExternalSecret` per PVC                 | VolSync backups from `charts/volsync`, one restic repository per PVC                  |
| `ServiceAccount` `<workspace>` and `ClusterRole` `dev-workspace-reader` | Read-only Kubernetes access (explicit lists, no Secrets, no wildcard)                 |
| `serviceaccounts.talos.dev` `<workspace>-talos`                         | Talos credential with the `os:reader` role; Talos creates a Secret with the same name |
| `ExternalSecret` `<workspace>-bws` (off until configured)               | `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` for the workspace                             |
| `Role` `dev-workspace-provisioner`                                      | The Coder provisioner may manage Deployments here and nothing else                    |
| `NetworkPolicy` `default-deny-ingress`                                  | Ingress deny-all; egress stays open                                                   |

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

**Subresources need `--subresource`.** `kubectl auth can-i get pods/exec` does not ask about the `exec` subresource: it
reads `exec` as the name of a pod, and a rule on `pods` allows any name, so it answers `yes` and looks like a leak. Use
the flag:

```sh
A=--as=system:serviceaccount:dev-workspace:dev-workspace
kubectl auth can-i get pods --subresource=exec $A                 # no
kubectl auth can-i create pods --subresource=exec $A              # no
kubectl auth can-i get nodes --subresource=proxy $A               # no
kubectl auth can-i create serviceaccounts --subresource=token $A  # no
kubectl auth can-i get pods --subresource=log $A                  # yes
```

The same applies to `attach`, `portforward`, `ephemeralcontainers` and the `pods`, `services` and `nodes` `proxy`
subresources. Cluster-scoped resources print a harmless "not namespace scoped" warning.

## Argo CD account `dev-workspace`

The workspace gets its own Argo CD local account (`argocd-cm`: `accounts.dev-workspace: apiKey`, so a token and no password
login). SSO is not used from the workspace: the owner's identity and the `ArgoCDAdmins` group map to `role:admin` in
`argocd-rbac-cm`, so an SSO session in the workspace would give a compromised workspace admin rights.

| Capability                                                              | Granted            | Why                                                                                |
| ----------------------------------------------------------------------- | ------------------ | ---------------------------------------------------------------------------------- |
| Read applications, hard refresh                                         | all applications   | `get` is the only permission a refresh needs (checked in the v3.5.7 source)        |
| Sync, and prune as a sync option                                        | the allowlist only | `sync` is the only permission a prune needs; the allowlist holds only `sync-probe` |
| Sync to another revision than `targetRevision`                          | never              | needs `override`; `application.sync.requireOverridePrivilegeForRevisionSync` is on |
| Read projects (`projects, get`)                                         | all projects       | `argocd app get` fetches the project too; the response has no credentials          |
| Delete, create, update, actions, exec, repositories, clusters, accounts | never              | not in the policy                                                                  |
| Create, update or delete projects                                       | never              | not in the policy                                                                  |

Responses mask live Secret values (`get` does not expose them).

**Add an application to the allowlist** by a reviewed PR: one line in `argocd-rbac-cm`
(`p, dev-workspace, applications, sync, <project>/<application>, allow`) and `argocd.argoproj.io/sync-options: Prune=false`
on that application's PVCs and stateful owners (this stops Argo CD pruning those objects; it does not stop a destructive
update or a deletion by another controller). The first entry is `default/sync-probe`, a disposable application of two
ConfigMaps (`cluster/apps/default/sync-probe`); real applications follow, one reviewed PR each. Initial
exclusions: Argo CD itself, bootstrap and the ApplicationSets, access-control infrastructure, storage operators and the
`dev-workspace` app.

**Token.** The owner generates it (`argocd account generate-token --account dev-workspace`) and stores it, with the server
address, in the dev BWS project as `ARGOCD_AUTH_TOKEN` and `ARGOCD_SERVER` (the address contains the private domain, so it is a
secret value, not text in this repository). The agent never handles the token. Using it to sync or prune still needs the
owner's consent for each action.

**Checks after the sync of this change** (run by the owner, with the token, because they use the token):

```sh
argocd account can-i get applications '*/*'      # yes
argocd account can-i get projects '*'            # yes (also `argocd app get <name>` works)
argocd account can-i create projects '*'         # no
argocd account can-i sync applications 'default/sync-probe'  # yes
argocd account can-i sync applications 'default/<any other>' # no
argocd account can-i override applications '*/*' # no
argocd account can-i delete applications '*/*'   # no
argocd account can-i create applications '*/*'   # no
```

The live `argocd-cm` must show `application.sync.requireOverridePrivilegeForRevisionSync: "true"`.

**Sync test on `sync-probe`** (each sync is a RUNTIME_MUTATION: the owner runs it, or consents per action):

1. `argocd app sync sync-probe` succeeds.
2. `argocd app sync <a real application>` is refused (`permission denied`).
3. `argocd app sync sync-probe --revision <non-main branch>` is refused (needs `override`).
4. Prune: a later PR removes `probe-prune-me` from git. Auto-sync leaves it in the cluster (`prune: false`), the app shows
   `OutOfSync`; `argocd app sync sync-probe --prune` deletes it.
