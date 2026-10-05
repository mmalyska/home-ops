# Talos kube-apiserver Config Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `cluster.apiServer` from the deprecated v1alpha1 block to `KubeAPIServerConfig`, `KubeAuthenticationConfig`, `KubeAuthorizerConfig`, `KubeAdmissionControlConfig` and `KubeAuditPolicyConfig` documents, drop the API server OIDC, and apply it node by node without losing API access.

**Architecture:** Two stages, each its own PR, each applied one node at a time. Stage 1 moves admission control and audit policy (independent of the rest). Stage 2 moves the core: the API server document, authentication and the two authorizers, and deletes the whole legacy block. Verification uses live `talosctl get` reads that do not need the Kubernetes API, then Kubernetes-level checks. Recovery goes through `talosctl apply-config`.

**Tech Stack:** Talos v1.14.2, `talosctl`, the layered patch pipeline in `provision/talos/`, yq (mikefarah v4), go-task.

**Spec:** `docs/superpowers/specs/2026-10-05-talos-apiserver-documents-design.md`

## Global Constraints

- Never write the private cluster domain literally in any file, comment or message: use the variable `${TALHELPER_CLUSTERDOMAIN}` and say "cluster domain".
- Never commit secrets (gitleaks runs on commit). Do not print environment variables.
- Never mutate the cluster (`task talos:apply`, `talosctl apply-config` without `--dry-run`) without the user's explicit confirmation, per node. `talosctl reboot` is blocked for Claude and is not needed here.
- Never push to `main`; branch prefixes `feat/`, `fix/`, `chore/`, `docs/`; every branch is pushed and gets a PR.
- Apply order: mc1 alone, run the checks, then mc2, then mc3. nv1 has no kube-apiserver and nothing to apply from this plan.
- Patch files follow the layout rules checked by `scripts/check-patches.sh`: name `NN-some-name.yaml[.tpl]`, four header lines (`# What:`, `# Why:`, `# Nodes:`, `# Apply:`), one YAML document per file, `${...}` only in `.tpl` files and only variables from `TPL_VARS`.
- `docs/src/talos/config-map.md` is generated: run `task talos:config-map` after any patch header or file change.
- Rendering and `task talos:diff` need the Bitwarden-derived environment (`.envrc`) and `TALOS_VERSION` and `KUBERNETES_VERSION` from `.taskfiles/talos/Taskfile.yaml`:

  ```bash
  export TALOSCONFIG="$PWD/provision/talos/clusterconfig/talosconfig"
  export TALOS_VERSION="$(yq '.vars.TALOS_VERSION' .taskfiles/talos/Taskfile.yaml)"
  export KUBERNETES_VERSION="$(yq '.vars.KUBERNETES_VERSION' .taskfiles/talos/Taskfile.yaml)"
  ```

- Node IPs: mc1 `192.168.48.2`, mc2 `192.168.48.3`, mc3 `192.168.48.4`.

## Review Focus

The spec implies these inputs and failure modes that no task's file-level checks cover:

1. **Authorizer order.** `node` must precede `rbac`; `talosctl get authorizationconfig` must show exactly that. Pinned by Task 2 Step 3 and Task 4 Step 3.
2. **PodSecurity exemption.** `kube-system` must stay exempt; if it is lost, system pods that need privileges are blocked. Pinned by the `get admissioncontrolconfig` comparison (Task 2, Task 4).
3. **Certificate SANs.** `certExtraSANs` must produce the same names as the legacy `certSANs`; clients using the VIP or the cluster domain would fail TLS verification otherwise. Pinned by the before and after SAN comparison (Task 4 Step 3).
4. **Anonymous access.** The new default allows anonymous requests only on `/livez`, `/readyz` and `/healthz`; today anonymous `/version` works. This tightening is intended; any other anonymous probe now gets 401. Pinned by Task 4 Step 3.
5. **Unset template variable.** Removing the OIDC variables must not leave a `.tpl` file that references them: `check-patches.sh` and the render test fail if one does. Pinned by Task 3 Step 6.

---

## Task 1: Stage 1 files, admission control and audit policy (PR 1)

Branch from `main` once the spec PR is merged: `git fetch origin && git switch -c chore/talos-apiserver-admission-audit origin/main`.

**Files:**

- Modify: `provision/talos/patches/controlplane/21-apiserver-pod-security.yaml`
- Modify: `provision/talos/patches/controlplane/22-apiserver-audit-policy.yaml`
- Create: `provision/talos/patches/controlplane/23-apiserver-legacy-admission-audit-delete.yaml`
- Modify: `docs/src/talos/config-map.md` (regenerated), `.plans/TODO.md`

**Interfaces:**

- Consumes: the layered pipeline (`render.sh`, `check-patches.sh`, `task talos:diff`, `task talos:config-map`).
- Produces: `KubeAdmissionControlConfig` (name `PodSecurity`) and `KubeAuditPolicyConfig` documents on control planes; the legacy `cluster.apiServer.admissionControl` and `auditPolicy` removed from the rendered config. `cluster.apiServer.image`, `extraArgs` and `certSANs` stay legacy until Task 3. File `23-` is replaced in Task 3.

- [ ] **Step 1: Replace the three files**

`provision/talos/patches/controlplane/21-apiserver-pod-security.yaml` (replace the whole file):

```yaml
# What:   PodSecurity admission: enforce baseline, audit and warn on restricted, kube-system exempt
# Why:    Baseline blocks the dangerous pod settings without breaking existing workloads; restricted is reported only.
#         kube-system runs privileged system pods, so it is exempt (the generated base used to add this exemption to
#         the legacy field, which 23-apiserver-legacy-admission-audit-delete.yaml removes)
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAdmissionControlConfig
name: PodSecurity
configuration:
  apiVersion: pod-security.admission.config.k8s.io/v1alpha1
  kind: PodSecurityConfiguration
  defaults:
    audit: restricted
    audit-version: latest
    enforce: baseline
    enforce-version: latest
    warn: restricted
    warn-version: latest
  exemptions:
    namespaces:
      - kube-system
    runtimeClasses: []
    usernames: []
```

`provision/talos/patches/controlplane/22-apiserver-audit-policy.yaml` (replace the whole file):

```yaml
# What:   API audit log: every request at Metadata level
# Why:    Who did what is recorded without storing request or response bodies
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAuditPolicyConfig
configuration:
  apiVersion: audit.k8s.io/v1
  kind: Policy
  rules:
    - level: Metadata
```

`provision/talos/patches/controlplane/23-apiserver-legacy-admission-audit-delete.yaml` (new):

```yaml
# What:   Remove the cluster.apiServer admissionControl and auditPolicy blocks that talosctl gen config adds
# Why:    Talos refuses the legacy blocks next to the KubeAdmissionControlConfig and KubeAuditPolicyConfig documents
#         (21-apiserver-pod-security.yaml, 22-apiserver-audit-policy.yaml)
# Nodes:  control plane
# Apply:  live
cluster:
  apiServer:
    admissionControl:
      - name: PodSecurity
        $patch: delete
    auditPolicy:
      $patch: delete
```

- [ ] **Step 2: Check, render and validate**

```bash
provision/talos/scripts/check-patches.sh                       # Expected: check-patches: ok
task talos:generate
for n in mc1 mc2 mc3 nv1; do talosctl validate --config provision/talos/clusterconfig/home-$n.yaml --mode metal 2>&1 | grep -v WARNING; done
# Expected: four lines "... is valid for metal mode"
yq 'select(.cluster != null) | .cluster.apiServer | keys' provision/talos/clusterconfig/home-mc1.yaml
# Expected: image, extraArgs, certSANs only (no admissionControl, no auditPolicy)
```

- [ ] **Step 3: Read the diff against the live node and dry-run**

```bash
out="$(mktemp)"; task talos:diff -- mc1 2>&1 | grep -v "^task:" | tee "$out"
talosctl -n 192.168.48.2 apply-config --file provision/talos/clusterconfig/home-mc1.yaml --mode auto --dry-run 2>&1 | grep -E "Applied|reboot"
```

Expected: the `+` side has a `KubeAdmissionControlConfig` document (name `PodSecurity`, the same `configuration`, `kube-system` in `exemptions.namespaces`) and a `KubeAuditPolicyConfig` document (the same policy); the `-` side has the `admissionControl` and `auditPolicy` blocks under `cluster.apiServer` with the same content; nothing else differs; the dry run prints `Applied configuration without a reboot`. Anything else: stop and investigate.

- [ ] **Step 4: Config map, TODO, tests**

```bash
task talos:config-map
task talos:check                                              # Expected: check-patches: ok, config-map: up to date, 0 failed
```

In `.plans/TODO.md`, in the Tier 2 bullet, change the `cluster.apiServer` sentence to start with: "Stage 1 done: PodSecurity admission and audit policy as `KubeAdmissionControlConfig` and `KubeAuditPolicyConfig` (apiServer stage 2 follows, see `docs/superpowers/specs/2026-10-05-talos-apiserver-documents-design.md`)."

- [ ] **Step 5: Commit, push, open PR 1**

```bash
git add -A
git commit -m "feat(talos): admission control and audit policy as config documents"
git push -u origin HEAD
gh pr create --title "feat(talos): migrate apiServer admission control and audit policy to documents" --body "$(cat <<BODY
Stage 1 of docs/superpowers/specs/2026-10-05-talos-apiserver-documents-design.md: the PodSecurity admission config and the audit policy become KubeAdmissionControlConfig and KubeAuditPolicyConfig documents with the same content; the kube-system exemption the generated base used to carry is written into the document. The generated legacy admissionControl and auditPolicy keys are deleted. Image, extraArgs and certSANs stay legacy until stage 2.

task talos:diff -- mc1 (live vs repo):

$(cat "$out")

Apply one node at a time (the kube-apiserver static pod restarts), mc1 first, with the live comparisons of Task 2 of the plan.
BODY
)"
rm -f "$out"
```

---

## Task 2: Apply stage 1, node by node (after PR 1 is merged)

Needs the user's go-ahead per node. Steps are run natively because they use the live cluster.

**Files:** none changed (a scratch directory for before and after captures, outside git).

**Interfaces:**

- Consumes: PR 1 merged and `main` pulled; the exports from Global Constraints.
- Produces: stage 1 live on mc1, mc2, mc3 and verified; the capture and compare commands reused by Task 4.

- [ ] **Step 1: Baseline, once**

```bash
git switch main && git pull --ff-only origin main
task talos:generate
cap="$(mktemp -d)"; echo "$cap"
kubectl get applications -A --no-headers | awk '$3!="Synced" || $4!="Healthy"' | tee "$cap/argocd-baseline.txt"   # note what is not Synced/Healthy today
```

- [ ] **Step 2: Capture, apply and capture for one node (mc1 first)**

```bash
N=mc1; IP=192.168.48.2
for r in apiserverconfig authorizationconfig admissioncontrolconfig auditpolicyconfig; do
  talosctl -n $IP get $r -o yaml | yq '.spec' > "$cap/$N-$r.before.yaml"
done
task talos:diff -- $N | grep -E "^[+-] |^$N"                   # read it: only the stage 1 move
task talos:apply N=$N                                           # needs the user's go-ahead; runs the health gate first
for r in apiserverconfig authorizationconfig admissioncontrolconfig auditpolicyconfig; do
  talosctl -n $IP get $r -o yaml | yq '.spec' > "$cap/$N-$r.after.yaml"
  echo "== $r: $(diff -q "$cap/$N-$r.before.yaml" "$cap/$N-$r.after.yaml" >/dev/null && echo identical || echo DIFFERENT)"
done
```

- [ ] **Step 3: Verify the node**

Expected: all four resources `identical`.

```bash
yq '.config[].name' "$cap/$N-authorizationconfig.after.yaml" | tr '\n' ' '    # Expected: node rbac
yq '.config' "$cap/$N-admissioncontrolconfig.after.yaml" | grep -c kube-system   # Expected: 1 or more (the exemption)
kubectl get node $N --no-headers | awk '{print $1,$2,$5}'                       # Expected: Ready v1.35.9
kubectl -n kube-system get pod kube-apiserver-$N --no-headers | awk '{print $1,$2,$3}'   # Expected: 1/1 Running
echo "pods not Running: $(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | wc -l)"   # Expected: 0
task talos:diff -- $N | grep -E "^$N"                                           # Expected: no differences
```

If any resource differs, stop: restore with the rollback in Task 4 and report.

- [ ] **Step 4: Repeat Steps 2 and 3 for mc2 (`N=mc2; IP=192.168.48.3`) and mc3 (`N=mc3; IP=192.168.48.4`)**

Ask the user before each node. After mc3:

```bash
kubectl get applications -A --no-headers | awk '$3!="Synced" || $4!="Healthy"' | diff - "$cap/argocd-baseline.txt" && echo "ArgoCD same as baseline"
task talos:diff | grep -E "^(mc|nv)[0-9]"                                       # Expected: no differences on all four
rm -rf "$cap"
```

---

## Task 3: Stage 2 files, the API server core (PR 2)

Branch from `main` after Task 2 is complete and verified. Do not merge or apply PR 2 earlier: stage 1 must be live and verified first.

**Files:**

- Create: `provision/talos/patches/controlplane/20-apiserver.yaml.tpl`, `24-apiserver-authentication.yaml`, `25-apiserver-authorizer-node.yaml`, `26-apiserver-authorizer-rbac.yaml`, `23-apiserver-legacy-delete.yaml` (all in `provision/talos/patches/controlplane/`)
- Delete: `provision/talos/patches/controlplane/20-apiserver-oidc.yaml.tpl`, `23-apiserver-legacy-admission-audit-delete.yaml`
- Modify: `provision/talos/scripts/lib.sh` (`TPL_VARS`), `provision/talos/tests/test_render.sh`, `docs/src/k8s/oidc/Readme.md`, `.claude/skills/cluster-reference/SKILL.md`, `docs/src/talos/config-map.md` (regenerated), `.plans/TODO.md`

**Interfaces:**

- Consumes: Task 1 and 2 results (the `21-` and `22-` documents are unchanged here).
- Produces: `KubeAPIServerConfig`, `KubeAuthenticationConfig` and two `KubeAuthorizerConfig` documents (`node`, `rbac`) on control planes; no `cluster.apiServer` in the rendered config; `TALHELPER_OIDCCLIENTID` and `TALHELPER_OIDCISSUERURL` no longer in `TPL_VARS`.

- [ ] **Step 1: Replace the legacy API server file and the delete file**

```bash
git switch -c chore/talos-apiserver-core origin/main
git rm provision/talos/patches/controlplane/20-apiserver-oidc.yaml.tpl provision/talos/patches/controlplane/23-apiserver-legacy-admission-audit-delete.yaml
```

`provision/talos/patches/controlplane/20-apiserver.yaml.tpl` (new):

```yaml
# What:   kube-apiserver image at the Kubernetes version and the extra names its certificate is valid for
# Why:    The document needs the image explicitly (the generated base carried it); the SANs let clients use the VIP and
#         the cluster domain. Authentication, authorization, admission and audit are separate documents (21 to 26).
#         The API server OIDC is not configured: kubectl uses the Talos-generated kubeconfig
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAPIServerConfig
image: registry.k8s.io/kube-apiserver:${KUBERNETES_VERSION}
certExtraSANs:
  - ${TALHELPER_CLUSTERENDPOINTIP}
  - ${TALHELPER_CLUSTERDOMAIN}
  - 127.0.0.1
```

`provision/talos/patches/controlplane/23-apiserver-legacy-delete.yaml` (new):

```yaml
# What:   Remove the cluster.apiServer block that talosctl gen config adds
# Why:    Talos refuses the legacy block next to the KubeAPIServerConfig document and the documents that replace its
#         parts (20 to 22 and 24 to 26); the generated image, admission and audit values are carried by those documents
# Nodes:  control plane
# Apply:  live
cluster:
  apiServer:
    $patch: delete
```

- [ ] **Step 2: Authentication and the two authorizers**

`provision/talos/patches/controlplane/24-apiserver-authentication.yaml` (new):

```yaml
# What:   kube-apiserver authentication: anonymous access only for the health endpoints, no JWT (OIDC) issuers
# Why:    A KubeAPIServerConfig document always runs the API server with an authentication config file. This is
#         Talos's default content, written out so the repo shows it. Client certificates (the Talos-generated
#         kubeconfig, the kubelets) are authenticated separately and are not affected. To bring Keycloak OIDC back,
#         add one entry to `jwt` (issuer url, audiences, claim mappings)
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAuthenticationConfig
configuration:
  anonymous:
    enabled: true
    conditions:
      - path: /livez
      - path: /readyz
      - path: /healthz
  jwt: []
```

`provision/talos/patches/controlplane/25-apiserver-authorizer-node.yaml` (new):

```yaml
# What:   kube-apiserver authorizer 1 of 2: Node
# Why:    The Node authorizer lets each kubelet read and write only what concerns its own node. A KubeAPIServerConfig
#         document does not inject the default authorizers, so they are declared here; the order of the files (25, 26)
#         is the order of the authorizers
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAuthorizerConfig
name: node
type: Node
```

`provision/talos/patches/controlplane/26-apiserver-authorizer-rbac.yaml` (new):

```yaml
# What:   kube-apiserver authorizer 2 of 2: RBAC
# Why:    Role-based access control for users and service accounts; follows the Node authorizer (25-apiserver-authorizer-node.yaml)
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAuthorizerConfig
name: rbac
type: RBAC
```

- [ ] **Step 3: Remove the OIDC variables and fix the render test**

In `provision/talos/scripts/lib.sh`, in the `TPL_VARS` line, remove ` ${TALHELPER_OIDCCLIENTID} ${TALHELPER_OIDCISSUERURL}` so it reads:

```bash
TPL_VARS='${TALHELPER_CLUSTERENDPOINTIP} ${TALHELPER_CLUSTERDOMAIN} ${TALHELPER_UPSMONHOST} ${TALHELPER_UPSMONUSER} ${TALHELPER_UPSMONPASSWD} ${TALOS_VERSION} ${KUBERNETES_VERSION}'
```

In `provision/talos/tests/test_render.sh`:

- Delete the line `export TALHELPER_OIDCCLIENTID=oidc-client TALHELPER_OIDCISSUERURL=https://sso.test/realms/x`.
- Replace the line asserting `oidc-client-id: oidc-client` with:

  ```bash
  assert_eq "192.0.2.1 cluster.test 127.0.0.1" "$(yq 'select(.kind == "KubeAPIServerConfig") | .certExtraSANs | join(" ")' "$TMP/mc1.yaml")" "template variables are substituted in .tpl patches"
  ```

- In the two unset-variable cases, replace `unset TALHELPER_OIDCISSUERURL` with `unset TALHELPER_UPSMONHOST` (both occurrences).

- [ ] **Step 4: Docs and skill**

- `docs/src/k8s/oidc/Readme.md`: add a first paragraph under the title: "The Kubernetes API server OIDC is **not configured** (since the apiServer migration, see `docs/superpowers/specs/2026-10-05-talos-apiserver-documents-design.md`): kubectl uses the Talos-generated kubeconfig. The steps below are the old manifest-based setup; to bring OIDC back, add a `jwt` entry to `provision/talos/patches/controlplane/24-apiserver-authentication.yaml` (issuer url, audiences, claim mappings) instead of API server flags."
- `.claude/skills/cluster-reference/SKILL.md`: replace the bullet "OIDC on kube-apiserver pointing to Keycloak" with: "kube-apiserver: no OIDC (kubectl uses the Talos-generated kubeconfig); authentication, authorizers (node, rbac), admission and audit are config documents in provision/talos/patches/controlplane/ (files 20 to 26)".
- `.plans/TODO.md`: in the Tier 2 bullet, replace the whole apiServer sentence by: "Done: `cluster.apiServer` -> `KubeAPIServerConfig`, `KubeAuthenticationConfig`, `KubeAuthorizerConfig` (node, rbac), `KubeAdmissionControlConfig`, `KubeAuditPolicyConfig`; the API server OIDC was dropped (re-add as a `jwt` entry)."

- [ ] **Step 5: Check, render, validate, diff, dry-run**

```bash
provision/talos/scripts/check-patches.sh                       # Expected: check-patches: ok
task talos:generate
for n in mc1 mc2 mc3 nv1; do talosctl validate --config provision/talos/clusterconfig/home-$n.yaml --mode metal 2>&1 | grep -v WARNING; done
# Expected: four lines "... is valid for metal mode"
yq 'select(.cluster != null) | .cluster.apiServer' provision/talos/clusterconfig/home-mc1.yaml   # Expected: null
yq 'select(.kind == "KubeAuthorizerConfig") | .name' provision/talos/clusterconfig/home-mc1.yaml | grep -v '^---' | tr '\n' ' '   # Expected: node rbac
out="$(mktemp)"; task talos:diff -- mc1 2>&1 | grep -v "^task:" | tee "$out" | grep -E "^[+-] |^mc1" | grep -vE "^\+ {4,}|^- {6,}"
talosctl -n 192.168.48.2 apply-config --file provision/talos/clusterconfig/home-mc1.yaml --mode auto --dry-run 2>&1 | grep -E "Applied|reboot"
task talos:diff -- nv1 | grep -E "^nv1"                         # Expected: no differences
```

Expected diff for mc1: `+` documents `KubeAPIServerConfig` (image and `certExtraSANs`), `KubeAuthenticationConfig`, `KubeAuthorizerConfig` for `node` and `rbac` (and, if stage 1 is live, nothing for admission or audit); `-` the whole `cluster.apiServer` block; nothing else. The dry run prints `Applied configuration without a reboot`.

- [ ] **Step 6: Tests, config map, commit, push, open PR 2**

```bash
provision/talos/tests/run.sh                                   # Expected: every file "0 failed"
task talos:config-map
task talos:check                                               # Expected: check-patches: ok, config-map: up to date
prettier --ignore-unknown --config .github/linters/.prettierrc.yaml --check docs/src/k8s/oidc/Readme.md .claude/skills/cluster-reference/SKILL.md
grep -rn "OIDCCLIENTID\|OIDCISSUERURL" provision .taskfiles .claude docs/src ; echo "(nothing above = no leftover reference)"
git add -A
git commit -m "feat(talos): kube-apiserver, authentication and authorizers as config documents, drop the API server OIDC"
git push -u origin HEAD
gh pr create --title "feat(talos): migrate the kube-apiserver core to config documents" --body "$(cat <<BODY
Stage 2 of docs/superpowers/specs/2026-10-05-talos-apiserver-documents-design.md: KubeAPIServerConfig (pinned image, certExtraSANs), KubeAuthenticationConfig (Talos default content written out), KubeAuthorizerConfig node then rbac; the legacy cluster.apiServer block is deleted. The API server OIDC is dropped (not in use; kubectl uses the Talos-generated kubeconfig): the oidc-* arguments, the two Keycloak template variables and the test that used them are removed.

Do not apply before stage 1 is live and verified. Apply mc1 alone first, with the live comparisons of Task 4 of the plan (authorization order, certificate SANs, anonymous access); recovery is talosctl apply-config, not the kubectl-dependent task.

task talos:diff -- mc1 (live vs repo, long lines trimmed):

$(grep -E "^[+-] |^mc1" "$out" | grep -vE "^\+ {4,}|^- {6,}")
BODY
)"
rm -f "$out"
```

---

## Task 4: Apply stage 2, node by node (after PR 2 is merged)

Needs the user's go-ahead per node. Native, live cluster.

**Files:** none changed.

**Interfaces:**

- Consumes: PR 2 merged and `main` pulled; stage 1 live.
- Produces: stage 2 live on mc1, mc2, mc3 and verified; the rollback procedure.

- [ ] **Step 1: Baseline, once**

```bash
git switch main && git pull --ff-only origin main
task talos:generate
cap="$(mktemp -d)"; echo "$cap"
kubectl get applications -A --no-headers | awk '$3!="Synced" || $4!="Healthy"' > "$cap/argocd-baseline.txt"
for p in "mc1 192.168.48.2" "mc2 192.168.48.3" "mc3 192.168.48.4"; do set -- $p
  openssl s_client -connect $2:6443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName > "$cap/$1-sans.before.txt"
  curl -sk -o /dev/null -w "$1 anonymous /version before: %{http_code}\n" https://$2:6443/version
done
```

- [ ] **Step 2: Capture the resources and apply mc1**

```bash
N=mc1; IP=192.168.48.2
for r in apiserverconfig authorizationconfig admissioncontrolconfig auditpolicyconfig; do
  talosctl -n $IP get $r -o yaml | yq '.spec' > "$cap/$N-$r.before.yaml"
done
task talos:diff -- $N | grep -E "^[+-] |^$N" | grep -vE "^\+ {4,}|^- {6,}"   # read it: only the stage 2 move
talosctl -n $IP apply-config --file provision/talos/clusterconfig/home-$N.yaml --mode auto --dry-run 2>&1 | grep -E "Applied|reboot"
task talos:apply N=$N                                                          # user's go-ahead first
```

- [ ] **Step 3: Verify mc1 (live reads first, then Kubernetes)**

```bash
for r in apiserverconfig authorizationconfig admissioncontrolconfig auditpolicyconfig authenticationconfig; do
  talosctl -n $IP get $r -o yaml | yq '.spec' > "$cap/$N-$r.after.yaml"
done
diff "$cap/$N-apiserverconfig.before.yaml" "$cap/$N-apiserverconfig.after.yaml"
# Expected: only the oidc-* arguments removed and useAuthenticationConfig now true; image still registry.k8s.io/kube-apiserver:v1.35.9
yq '.config[].name' "$cap/$N-authorizationconfig.after.yaml" | tr '\n' ' '     # Expected: node rbac (in this order)
for r in authorizationconfig admissioncontrolconfig auditpolicyconfig; do
  echo "== $r: $(diff -q "$cap/$N-$r.before.yaml" "$cap/$N-$r.after.yaml" >/dev/null && echo identical || echo DIFFERENT)"   # Expected: identical (authorizationconfig may differ only in the webhook placeholder; compare the type and name list)
done
yq '.' "$cap/$N-authenticationconfig.after.yaml" | head -12                    # Expected: anonymous only /livez, /readyz, /healthz; jwt empty
openssl s_client -connect $IP:6443 </dev/null 2>/dev/null | openssl x509 -noout -ext subjectAltName | diff - "$cap/$N-sans.before.txt" && echo "SANs identical"   # Expected: identical
kubectl get node $N --no-headers | awk '{print $1,$2,$5}'                      # Expected: Ready v1.35.9 (the kubelet is authorized through the Node authorizer)
kubectl -n kube-system get pod kube-apiserver-$N --no-headers | awk '{print $1,$2,$3}'   # Expected: 1/1 Running
kubectl auth can-i '*' '*'                                                      # Expected: yes (Talos admin)
curl -sk https://$IP:6443/livez; echo                                           # Expected: ok (anonymous health endpoint)
curl -sk -o /dev/null -w "anonymous /version after: %{http_code}\n" https://$IP:6443/version   # Expected: 401 (the intended tightening; before it was 200)
talosctl -n $IP logs kubelet 2>/dev/null | tail -300 | grep -ci "forbidden"    # Expected: 0 new lines
echo "pods not Running: $(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | wc -l)"   # Expected: 0
kubectl get applications -A --no-headers | awk '$3!="Synced" || $4!="Healthy"' | diff - "$cap/argocd-baseline.txt" && echo "ArgoCD same as baseline"
task talos:diff -- $N | grep -E "^$N"                                           # Expected: no differences
```

If a check fails, use the rollback below before anything else.

- [ ] **Step 4: Repeat Steps 2 and 3 for mc2 (`N=mc2; IP=192.168.48.3`) and mc3 (`N=mc3; IP=192.168.48.4`)**

Ask the user before each node. After mc3:

```bash
task talos:diff | grep -E "^(mc|nv)[0-9]"                                       # Expected: no differences on all four
rm -rf "$cap"
```

- [ ] **Rollback (only if a check fails)**

Do not use `task talos:apply` for recovery: its health gate needs kubectl, which may not work against a broken node. The Talos API (port 50000, client certificates) does not depend on the Kubernetes API.

```bash
git switch -c fix/talos-apiserver-rollback origin/main
git revert --no-edit <the merge commit of the failing PR>           # or git checkout the previous commit's patches
task talos:generate
talosctl -n $IP apply-config --file provision/talos/clusterconfig/home-$N.yaml --mode auto
talosctl -n $IP get apiserverconfig -o yaml | yq '.spec.image'       # the API server static pod restarts; wait until kube-apiserver-$N is Running
```

Then open a PR with the revert and report what failed.

---

## Task 5: Open items from the spec

- [ ] **Step 1: Kubernetes upgrade dry run against the new config**

After Task 4 is complete:

```bash
talosctl --nodes 192.168.48.2 upgrade-k8s --to "${KUBERNETES_VERSION#v}" --dry-run
```

Expected: the pre-flight checks pass and no error about the new documents. If it fails, add the finding to `.plans/TODO.md` ("talosctl upgrade-k8s and the API server documents") and tell the user before the next Kubernetes upgrade.

- [ ] **Step 2: Close the work**

Move nothing else: the TODO entry was updated in Tasks 1 and 3. Report to the user: both PRs, the verification results per node, the `upgrade-k8s --dry-run` result, and that `machine.install` is the next Tier 2 migration.

---

## Self-Review

**Spec coverage:**

| Spec                                                                          | Task                               |
| ----------------------------------------------------------------------------- | ---------------------------------- |
| Decision 1, drop the API server OIDC (variables, test, docs)                  | 3 (Steps 1, 3, 4)                  |
| Decision 2, explicit documents                                                | 3 (Step 2)                         |
| Decision 3, two PRs applied node by node                                      | 1 and 3 (PRs), 2 and 4 (apply)     |
| Decision 4, recovery through the Talos API                                    | 4 (Rollback)                       |
| Stage 1 (admission with explicit `kube-system` exemption, audit, delete file) | 1                                  |
| Stage 2 (core document, authentication, authorizers, delete the legacy block) | 3                                  |
| Verification table, Kubernetes-level checks                                   | 2 (Step 3), 4 (Step 3)             |
| Rollout order mc1, mc2, mc3 with the user's go-ahead                          | 2, 4                               |
| Risks: authorizers, anonymous access, exemption, SANs                         | Review Focus 1 to 4, Task 4 Step 3 |
| Open item: `upgrade-k8s --dry-run`                                            | 5                                  |
| Open item: `certExtraSANs` equals the legacy SANs                             | 4 (Steps 1 and 3)                  |
| Open item: file numbers show the authorizer order                             | 3 (Step 2, files 25 and 26)        |

**Placeholder scan:** none. Every file is given in full; the rollback names `<the merge commit of the failing PR>` because it depends on the failure.

**Name consistency:** file numbers 20 to 26 are used the same way in the headers, the spec and the tasks; `23-` is created in Task 1 as `23-apiserver-legacy-admission-audit-delete.yaml` and replaced by `23-apiserver-legacy-delete.yaml` in Task 3.

**Verified before writing:** both stages were rendered, validated (`talosctl validate --mode metal`), diffed against the live mc1 and dry-run in a scratch copy: stage 1 moves the admission and audit content unchanged, stage 2 removes `cluster.apiServer` and adds the five document kinds, nv1 shows no difference, the dry runs report no reboot, and the full test suite passes with the changed render test (21 tests). The effective-config reads, the SAN comparison and the anonymous checks run only against the live cluster and are not exercised until Tasks 2 and 4.
