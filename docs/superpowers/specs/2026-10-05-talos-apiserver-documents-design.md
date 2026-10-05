# Talos kube-apiserver Config Documents — Design

## Context

Talos 1.14 deprecates the legacy `cluster.apiServer` block in favour of
dedicated documents. This is the Tier 2 item "apiServer" in `.plans/TODO.md`,
the last one that carries real lock-out risk, so it gets its own spec. The
other Tier 2 migrations (kubelet, controller manager, scheduler, proxy,
CoreDNS, network) are done and applied; `machine.install` follows after this.

Read the layered layout spec first
(`2026-10-05-talos-config-layout-design.md`): patch files live in
`provision/talos/patches/`, one YAML document per file, `.yaml.tpl` for files
that need variables, and a `$patch: delete` file removes a legacy block that
`talosctl gen config` adds to the base.

### Current state (verified 2026-10-05)

`cluster.apiServer` is written in three patch files
(`provision/talos/patches/controlplane/`):

- `20-apiserver-oidc.yaml.tpl`: Keycloak OIDC as `extraArgs` (`oidc-client-id`,
  `oidc-issuer-url`, groups and username claim and prefix) and `certSANs`
  (control-plane VIP, cluster domain, `127.0.0.1`).
- `21-apiserver-pod-security.yaml`: `admissionControl` with the
  `PodSecurity` plugin (enforce baseline, audit and warn restricted). The
  `kube-system` namespace exemption is not in this file: the generated base
  adds it, and lists append.
- `22-apiserver-audit-policy.yaml`: `auditPolicy`, every request at
  `Metadata` level.

The rendered legacy block also carries `image:
registry.k8s.io/kube-apiserver:<KUBERNETES_VERSION>` from the base. Live,
`talosctl get authorizationconfig` shows two authorizers, `node` then `rbac`,
which Talos injects in legacy mode. `talosctl get authenticationconfig` does
not exist, because legacy mode passes flags.

OIDC for kubectl is not in use: the only kubectl access is the
Talos-generated kubeconfig (client certificate). No manifest in `cluster/`
binds an `oidc:` user or group; ArgoCD's own Keycloak login is separate and
untouched.

### What the Talos v1.14.2 source says

(`pkg/machinery/config/types/k8s`, read on 2026-10-05.)

- A `KubeAPIServerConfig` document makes kube-apiserver run with
  `--authentication-config`, and kube-apiserver refuses every `--oidc-*` flag
  then. `UseAuthenticationConfig()` is always true for the document.
- `InjectDefaultAuthorizers()` is false for the document: the `Node` and
  `RBAC` authorizers must be declared as `KubeAuthorizerConfig` documents.
- `image` is required and validated (`kube-apiserver image cannot be empty`).
- `KubeAdmissionControlConfig` (named plugin) and `KubeAuditPolicyConfig` conflict
  only with their own legacy fields (`admissionControl`, `auditPolicy`), not
  with the rest of `cluster.apiServer`.
- `KubeAPIServerConfig` conflicts with the whole legacy `cluster.apiServer`
  block and with `cluster.controlPlane.localAPIServerPort`.
- `KubeAuthenticationConfig` holds the literal Kubernetes
  `AuthenticationConfiguration` under `configuration:`; its default is
  anonymous access limited to `/livez`, `/readyz` and `/healthz` and an empty
  `jwt` list.

## Decisions

1. **Drop the API server OIDC.** Not in use, so no `jwt[]` entry is written.
   The Bitwarden items and `.envrc` stay, so OIDC can return later as one
   `jwt[]` entry in `KubeAuthenticationConfig`.
2. **Explicit documents over defaults.** `KubeAuthenticationConfig` and both
   `KubeAuthorizerConfig` documents are written out even though Talos has
   defaults, so the repo shows what the API server runs with.
3. **Two PRs, each applied node by node:** stage 1 (admission and audit,
   independent of the rest) and stage 2 (the core, which cannot be split).
4. **Recovery goes through the Talos API**, not through kubectl (see
   Rollback).

## Design

### Stage 1: admission control and audit policy (PR 1)

- `controlplane/21-apiserver-pod-security.yaml` becomes a
  `KubeAdmissionControlConfig` document, `name: PodSecurity`, with the same
  `configuration`. The `kube-system` exemption must now be written into the
  document (`exemptions.namespaces: [kube-system]`), because the base's copy
  goes away with the legacy key.
- `controlplane/22-apiserver-audit-policy.yaml` becomes a
  `KubeAuditPolicyConfig` document with the same policy.
- A `$patch: delete` file removes `cluster.apiServer.admissionControl` and
  `cluster.apiServer.auditPolicy` from the base (Talos refuses both forms
  together).
- The rest of `cluster.apiServer` (`image`, `extraArgs`, `certSANs`) stays
  legacy until stage 2.

### Stage 2: API server core (PR 2)

One PR, because these documents depend on each other:

- `controlplane/20-apiserver.yaml.tpl`: `KubeAPIServerConfig` with `image:
  registry.k8s.io/kube-apiserver:${KUBERNETES_VERSION}` and
  `certExtraSANs` (`${TALHELPER_CLUSTERENDPOINTIP}`,
  `${TALHELPER_CLUSTERDOMAIN}`, `127.0.0.1`). No `extraArgs`.
- `KubeAuthenticationConfig` with the default content, in its own file.
- Two `KubeAuthorizerConfig` documents, `node` then `rbac`, each in its own
  file, named so the file order gives the authorizer order.
- A `$patch: delete` file removes the generated legacy `cluster.apiServer`
  block. The legacy `20-apiserver-oidc.yaml.tpl` is deleted.
- OIDC removal: `TALHELPER_OIDCCLIENTID` and `TALHELPER_OIDCISSUERURL` leave
  `TPL_VARS` in `scripts/lib.sh`; `tests/test_render.sh` uses another variable
  for its unset-variable cases; `docs/src/k8s/oidc/` is removed or reduced to a
  note that the API server OIDC is not configured.
- Docs and skills that mention the OIDC wiring are updated in the same PR.

### Verification, per node

Live reads that do not need the Kubernetes API, before and after each apply,
compared with the expectations below:

| Read | Expectation after the change |
|---|---|
| `talosctl get apiserverconfig -o yaml` | image `registry.k8s.io/kube-apiserver:v1.35.9`, no `oidc-*` arguments, `useAuthenticationConfig: true` |
| `talosctl get authorizationconfig -o yaml` | exactly `node` (Node) then `rbac` (RBAC) |
| `talosctl get authenticationconfig -o yaml` | the default content: anonymous only on the three health paths, empty `jwt` |
| `talosctl get admissioncontrolconfig -o yaml` | PodSecurity, same defaults, `kube-system` exempt, as before |
| `talosctl get auditpolicyconfig -o yaml` | the same `Metadata` policy |

Then Kubernetes-level checks:

- The node is Ready (the kubelet is authorized through the Node authorizer).
- `kubectl auth can-i '*' '*'` as the Talos admin returns yes.
- An anonymous `GET /livez` returns `ok`; an anonymous request to another path
  is refused (the intended tightening).
- `kube-apiserver-<node>` is Running at v1.35.9 and ArgoCD stays healthy.
- `task talos:diff` shows no differences.

### Rollout

Apply mc1 alone, run the checks, then mc2, then mc3, with the user's go-ahead
between nodes. The kube-apiserver static pod restarts on each node; with three
control planes the other two keep serving through the VIP. nv1 has no
kube-apiserver and nothing to apply.

### Rollback

- Revert the PR, render the previous config, and apply it with `talosctl
  apply-config --nodes <ip> --file ... --mode auto`. Do **not** use `task
  talos:apply` for recovery: its health gate needs kubectl, which may not work
  against a broken node.
- The Talos API (port 50000, client certificates) does not depend on the
  Kubernetes API and stays available if kube-apiserver on a node is broken.

## Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Authorizers missing or in the wrong order | Kubelet or users rejected, or the API server insecure | `get authorizationconfig` compared before the node can degrade; mc1 alone first |
| Anonymous access tighter than today | An external probe of a path other than `/livez`, `/readyz`, `/healthz` gets 401 | None found in the repo; accepted |
| `kube-system` exemption lost in stage 1 | PodSecurity would block system pods that need privileges | The exemption is written in the document and checked in `get admissioncontrolconfig` |
| `talosctl upgrade-k8s` does not understand the new documents | A later Kubernetes upgrade fails | Test `upgrade-k8s --dry-run` before relying on it (open item) |
| `certExtraSANs` does not replace `certSANs` exactly | Clients using the VIP or domain fail TLS verification | Compare the certificate SANs of the apiserver before and after (`openssl s_client`) |

## Out of scope

- Re-enabling OIDC (a later `jwt[]` entry).
- `machine.install` and `UnattendedInstallConfig` (next, own spec or plan).
- Webhook authorizers, authentication of other kinds, API server flags that
  are not in use today.

## Open items for the implementation plan

- Confirm on mc1 that `certExtraSANs` produces the same certificate SANs.
- Run `talosctl upgrade-k8s --to <current> --dry-run` against the new config.
- Decide the exact file names and numbers so the authorizer order is obvious
  from `task talos:explain`.
