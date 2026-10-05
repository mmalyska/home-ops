# Talos Discovery Documents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `cluster.id`, `cluster.secret` and `cluster.discovery` from the v1alpha1 config to `DiscoveryIdentityConfig` and `DiscoveryServiceConfig`, without changing the cluster id, the secret or the discovery settings.

**Architecture:** Same pattern as Tier 2. The generated base (`talosctl gen config`, contract v1.13) still carries the legacy fields, so one patch deletes them and two patches add the documents. `clusterID` and `clusterSecret` are rendered by a `.yaml.tpl` patch from the same `TALHELPER_CLUSTERNAME` and `TALHELPER_CLUSTERSECRET` variables that already feed `secrets.yaml.tpl`. `mask.sh` learns the two new key names so `task talos:diff` does not print them.

**Tech Stack:** Talos 1.14.2 patches (strategic merge), bash, yq, `envsubst`, the shell tests under `provision/talos/tests/`.

**Spec:** `docs/superpowers/specs/2026-10-05-talos-discovery-documents-design.md`

## Global Constraints

- Never write secret values into any tracked file (gitleaks blocks the commit). The patch uses `${TALHELPER_CLUSTERNAME}` and `${TALHELPER_CLUSTERSECRET}`, never the values.
- Every patch file starts with the header lines `# What:`, `# Why:`, `# Nodes:`, `# Apply:` (`scripts/check-patches.sh` enforces it). Files with variables end in `.yaml.tpl` and use the `${VAR}` form.
- `TALOS_CONTRACT` stays `v1.13`. `secrets.yaml.tpl` is not changed.
- Discovery endpoint stays the default `https://discovery.talos.dev/`; the Kubernetes registry stays off.
- Never apply config to a node, or run any mutating `talosctl`/`kubectl` command, without explicit user confirmation (Task 4 is a gated manual rollout).
- Never push to `main`; branch `chore/talos-discovery-documents`, then PR.
- Do not write the private cluster domain literally anywhere (comments, docs, memory).
- Run `task talos:check` before each commit that touches `provision/talos/`.

## Review Focus

1. **Secret leakage in `task talos:diff`:** `mask.sh` masks `id` and `secret` but not `clusterID` / `clusterSecret`; unmasked, the diff prints the cluster secret (Task 1).
2. **Variable unset or empty:** an unset or empty `TALHELPER_CLUSTERSECRET` / `TALHELPER_CLUSTERNAME` must fail the render, never produce an identity document with an empty value that would split the discovery group (Task 2).
3. **Legacy fields left next to the documents:** Talos rejects both together ("cluster identity is already configured in .cluster.id/.cluster.secret"). Every node, control plane and worker (nv1), must validate (Task 2).
4. **Changed values:** the rendered `clusterID`/`clusterSecret` must equal what the live nodes run, compared by hash, because the masked diff cannot show a changed value (Task 4).
5. **Kubernetes registry default on 1.14:** with no registry document, the Kubernetes registry must stay off; checked on the live node after the first apply (Task 4).

---

### Task 1: Mask the new secret key names

**Files:**
- Modify: `provision/talos/scripts/mask.sh`
- Test: `provision/talos/tests/test_normalize_mask.sh`

**Interfaces:**
- Produces: `mask.sh` replaces the value of `clusterID` and `clusterSecret` keys with `<masked>`, keeping the diff marker and indentation. Task 4 relies on it.

- [ ] **Step 1: Write the failing test**

In `provision/talos/tests/test_normalize_mask.sh`, add two input lines to the `printf` list (after the `secretboxEncryptionSecret` line) and two assertions after the `xyz` assertion:

```bash
  '+  secretboxEncryptionSecret: xyz' \
  '+clusterID: c2lkLXZhbHVl' \
  '-clusterSecret: c2VjLXZhbHVl' \
```

```bash
assert_not_contains "$masked" "xyz" "secretboxEncryptionSecret value is masked"
assert_not_contains "$masked" "c2lkLXZhbHVl" "clusterID value is masked"
assert_not_contains "$masked" "c2VjLXZhbHVl" "clusterSecret value is masked"
assert_contains "$masked" "-clusterSecret: <masked>" "the key name and diff marker of clusterSecret stay visible"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `provision/talos/tests/test_normalize_mask.sh`
Expected: FAIL on the three new assertions (`clusterID value is masked`, `clusterSecret value is masked`, the marker one).

- [ ] **Step 3: Write the minimal implementation**

In `provision/talos/scripts/mask.sh`, extend the key alternation:

```bash
  s/^([ +-]*(- )?)(crt|key|token|secret|secretboxEncryptionSecret|aescbcEncryptionSecret|password|id|bootstraptoken|clusterID|clusterSecret):[ ]*.*/\1\3: <masked>/
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `provision/talos/tests/test_normalize_mask.sh`
Expected: PASS, `N tests, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add provision/talos/scripts/mask.sh provision/talos/tests/test_normalize_mask.sh
git commit -m "chore(talos): mask clusterID and clusterSecret in the diff output"
```

---

### Task 2: Discovery documents and the legacy delete patch

**Files:**
- Rename: `provision/talos/patches/all/90-discovery.yaml` to `provision/talos/patches/all/90-discovery-service.yaml` (then rewrite)
- Create: `provision/talos/patches/all/91-discovery-identity.yaml.tpl`
- Create: `provision/talos/patches/all/92-discovery-legacy-delete.yaml`
- Modify: `provision/talos/scripts/lib.sh` (the `TPL_VARS` line)
- Test: `provision/talos/tests/test_render.sh`

**Interfaces:**
- Consumes: `TPL_VARS` and the unset/empty variable check in `render.sh` (it dies with "needs $VAR, which is not set" for an unset or empty variable used in a `.tpl` patch).
- Produces: every rendered node config contains one `DiscoveryIdentityConfig` (`clusterID`, `clusterSecret`) and one `DiscoveryServiceConfig` (`name: primary`, `endpoint: https://discovery.talos.dev/`) and no `cluster.id`, `cluster.secret`, `cluster.discovery`.

Verified while planning (2026-10-05, Talos v1.14.2, `talosctl machineconfig patch` on a v1.13-contract base): `$patch: delete` on the scalar keys `id` and `secret` removes them; setting them to `""` does not; the base with the delete patch plus both documents passes `talosctl validate --mode metal`; with the legacy fields left in, validate fails with "cluster identity is already configured in .cluster.id/.cluster.secret".

- [ ] **Step 1: Write the failing tests**

In `provision/talos/tests/test_render.sh`:

Add the two variables to the exports at the top (after the `TALHELPER_UPSMON*` line). The values are generated low-entropy base64 (43 `A`/`B` characters plus `=`); `talosctl validate` needs valid base64, and a literal random-looking string would trip gitleaks:

```bash
export TALHELPER_CLUSTERNAME="$(printf "A%.0s" $(seq 43))=" TALHELPER_CLUSTERSECRET="$(printf "B%.0s" $(seq 43))="
```

In the `-- control plane (mc1)` block, after the `legacy machine.install` assertion, add:

```bash
assert_eq "$TALHELPER_CLUSTERNAME|$TALHELPER_CLUSTERSECRET" "$(yq 'select(.kind == "DiscoveryIdentityConfig") | .clusterID + "|" + .clusterSecret' "$TMP/mc1.yaml")" "the discovery identity is rendered from the TALHELPER variables"
assert_eq "primary|https://discovery.talos.dev/" "$(yq 'select(.kind == "DiscoveryServiceConfig") | .name + "|" + .endpoint' "$TMP/mc1.yaml")" "the discovery service document uses the default endpoint"
assert_eq "null|null|null" "$(yq 'select(.machine != null) | (.cluster.id | tostring) + "|" + (.cluster.secret | tostring) + "|" + (.cluster.discovery | tostring)' "$TMP/mc1.yaml")" "the legacy cluster.id, cluster.secret and cluster.discovery are removed"
```

In the `-- failure modes` block, after the first unset-variable assertion, add:

```bash
(unset TALHELPER_CLUSTERSECRET; assert_fails "an unset cluster secret fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/unset3.yaml")
(TALHELPER_CLUSTERNAME=""; export TALHELPER_CLUSTERNAME; assert_fails "an empty cluster id fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/empty.yaml")
```

At the end of the file, before `finish`, add a loop over all nodes, mirroring the install-document loop:

```bash
echo "-- discovery documents on every node"
for n in $(yq '.nodes[].name' "$SCRIPTS/../nodes.yaml"); do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  assert_eq "1 1" "$(yq 'select(.kind == "DiscoveryIdentityConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ') $(yq 'select(.kind == "DiscoveryServiceConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')" "$n has exactly one identity and one service document"
  assert_ok "$n output is a valid metal config (a legacy field left next to the documents fails here)" talosctl validate --config "$TMP/$n.yaml" --mode metal
done
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `provision/talos/tests/test_render.sh`
Expected: FAIL on the new identity, service and legacy-removed assertions (the documents do not exist yet); the empty/unset-secret assertions also fail because the secret is not used by any `.tpl` patch yet.

- [ ] **Step 3: Write the implementation**

Rename and rewrite the service patch:

```bash
git mv provision/talos/patches/all/90-discovery.yaml provision/talos/patches/all/90-discovery-service.yaml
```

`provision/talos/patches/all/90-discovery-service.yaml`:

```yaml
# What:   Cluster member discovery through the discovery service only; the Kubernetes registry is off
# Why:    Members discover each other without depending on the Kubernetes API. With no Kubernetes registry document the
#         registry stays off; the default public endpoint is the one `service: {}` used before
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: DiscoveryServiceConfig
name: primary
endpoint: https://discovery.talos.dev/
```

`provision/talos/patches/all/91-discovery-identity.yaml.tpl`:

```yaml
# What:   Cluster identity used by the discovery service: the cluster id and the shared secret
# Why:    Same values as before (they come from the Bitwarden-derived TALHELPER_CLUSTERNAME and TALHELPER_CLUSTERSECRET
#         variables that also feed secrets.yaml.tpl), so the discovery group and node membership do not change
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: DiscoveryIdentityConfig
clusterID: ${TALHELPER_CLUSTERNAME}
clusterSecret: ${TALHELPER_CLUSTERSECRET}
```

`provision/talos/patches/all/92-discovery-legacy-delete.yaml`:

```yaml
# What:   Remove the cluster.id, cluster.secret and cluster.discovery fields that talosctl gen config adds
# Why:    Talos refuses the legacy fields next to the DiscoveryIdentityConfig and DiscoveryServiceConfig documents
#         (90-discovery-service.yaml, 91-discovery-identity.yaml.tpl)
# Nodes:  all nodes
# Apply:  live
cluster:
  id:
    $patch: delete
  secret:
    $patch: delete
  discovery:
    $patch: delete
```

In `provision/talos/scripts/lib.sh`, extend `TPL_VARS` (add the two variables at the end of the existing list):

```bash
TPL_VARS='${TALHELPER_CLUSTERENDPOINTIP} ${TALHELPER_CLUSTERDOMAIN} ${TALHELPER_UPSMONHOST} ${TALHELPER_UPSMONUSER} ${TALHELPER_UPSMONPASSWD} ${TALOS_VERSION} ${KUBERNETES_VERSION} ${TALHELPER_CLUSTERNAME} ${TALHELPER_CLUSTERSECRET}'
```

- [ ] **Step 4: Run the tests and the convention checks**

Run: `provision/talos/tests/test_render.sh && provision/talos/scripts/check-patches.sh`
Expected: PASS for all, including the four-node loop and the two failure modes.

Run: `provision/talos/tests/run.sh`
Expected: every test file passes (`explain`, `lib`, `diff_live` and others do not depend on the discovery files; if one fixture does, update it to the new file name).

- [ ] **Step 5: Commit**

The config map is regenerated in Task 3, so `task talos:check` fails on the stale map until then; run the other two checks here. Commit now, fix the map next.

```bash
git add provision/talos/patches/all provision/talos/scripts/lib.sh provision/talos/tests/test_render.sh
git commit -m "feat(talos): move discovery identity and service to config documents"
```

---

### Task 3: Docs, config map and the TODO entry

**Files:**
- Modify (generated): `docs/src/talos/config-map.md`
- Modify: `provision/talos/README.md` (the `## Secrets` section)
- Modify: `.plans/TODO.md` (the Tier 3 bullet and the Next-step line)
- Modify: `docs/superpowers/specs/2026-10-05-talos-config-layout-design.md` (the tier 3 non-goal at "Migrating the PKI, secret and discovery fields")

**Interfaces:**
- Consumes: the three patch files from Task 2 (the config map is generated from their headers).

- [ ] **Step 1: Regenerate the config map and check it**

Run: `task talos:config-map` then `provision/talos/scripts/config-map.sh --check`
Expected: the check exits 0. `git diff docs/src/talos/config-map.md` shows the `90-discovery.yaml` rows replaced by `90-discovery-service.yaml` (`DiscoveryServiceConfig/primary`), `91-discovery-identity.yaml.tpl` (`DiscoveryIdentityConfig`) and `92-discovery-legacy-delete.yaml` (`cluster.id`, `cluster.secret`, `cluster.discovery`) for each node section.

- [ ] **Step 2: Update the README**

In `provision/talos/README.md`, in `## Secrets`, append a paragraph:

```markdown
`TALHELPER_CLUSTERNAME` and `TALHELPER_CLUSTERSECRET` feed two places: the secrets bundle (`secrets.yaml.tpl`, as
`cluster.id` and `cluster.secret`) and the `DiscoveryIdentityConfig` document (`patches/all/91-discovery-identity.yaml.tpl`).
`patches/all/92-discovery-legacy-delete.yaml` removes the legacy `cluster.id`, `cluster.secret` and `cluster.discovery`
fields that `talosctl gen config` adds, because Talos refuses them next to the documents. `task talos:diff` masks both
document keys, so it cannot show a changed value; compare by hash (see the discovery spec) if you ever change them.
```

- [ ] **Step 3: Update `.plans/TODO.md`**

In the Tier 3 bullet, replace the text up to the PKI part so it reads that discovery is done and only the PKI part remains:

```markdown
  - **Tier 3, PKI and secrets, all-or-nothing, leave until upstream gives a timeline:** `cluster.ca`, `aggregatorCA`, `secretboxEncryptionSecret` -> `KubeAPIServerCAConfig`, `KubeAggregatorCAConfig`, `KubeEtcdEncryptionConfig`. These change how the talhelper `TALHELPER_*` environment variables are templated (`provision/talos/secrets.yaml.tpl`). Done: `cluster.id`/`secret`/`discovery` -> `DiscoveryIdentityConfig` / `DiscoveryServiceConfig` (spec and plan `2026-10-05-talos-discovery-documents`).
```

In the "Next in the migration entry below" line near the top of the file, keep it accurate (Tier 1 deprecated fields remain only if still true; do not invent new steps).

- [ ] **Step 4: Update the layout spec non-goal**

In `docs/superpowers/specs/2026-10-05-talos-config-layout-design.md`, replace:

```markdown
- Migrating the PKI, secret and discovery fields (tier 3 in
```

with the same sentence limited to what is still true, i.e. the PKI and encryption-secret fields; add "(the discovery fields moved separately, see `2026-10-05-talos-discovery-documents-design.md`)" at the end of that bullet. Read the bullet first and keep its remaining wording and line wrapping.

- [ ] **Step 5: Run the full check and commit**

Run: `task talos:check && task lint:all`
Expected: all pass.

```bash
git add docs/src/talos/config-map.md provision/talos/README.md .plans/TODO.md docs/superpowers/specs/2026-10-05-talos-config-layout-design.md
git commit -m "docs(talos): document the discovery documents and regenerate the config map"
```

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin chore/talos-discovery-documents
gh pr create --title "feat(talos): move discovery identity and service to config documents" --body "Implements docs/superpowers/specs/2026-10-05-talos-discovery-documents-design.md. Repo change only; the live rollout (task talos:diff, hash comparison, node-by-node apply) is a separate gated step in the plan."
```

---

### Task 4: Gated live rollout (manual, needs user confirmation per step)

**Files:** none (cluster operations). Do this only after the PR from Task 3 is merged and the user confirms each step. Read-only commands are free; `task talos:apply` is not.

**Interfaces:**
- Consumes: merged patches from Tasks 1 to 3; the repo environment (`.envrc` exports `TALHELPER_*`, `TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig`).

- [ ] **Step 1: Render and diff (read-only)**

Run: `task talos:generate && task talos:diff`
Expected: for each node the diff shows only: `-    id: <masked>`, `-    secret: <masked>`, `-    discovery:` block removed, and `+clusterID: <masked>`, `+clusterSecret: <masked>` plus the two new documents. No other line changes. Version lines say "running v1.14.x".

- [ ] **Step 2: Prove the values are unchanged (read-only)**

The masked diff cannot show a changed value. Compare hashes for each node IP (mc1 `192.168.48.2`, mc2 `.3`, mc3 `.4`, and nv1's IP from `provision/talos/nodes.yaml`):

```bash
cd /workspaces/home-ops/provision/talos
for n in mc1 mc2 mc3 nv1; do
  ip=$(yq ".nodes[] | select(.name == \"$n\") | .ip" nodes.yaml)
  live=$(talosctl get machineconfig v1alpha1 -n "$ip" -o yaml | yq '.spec | select(.machine != null) | .cluster.id + "|" + .cluster.secret' | sha256sum)
  repo=$(yq 'select(.kind == "DiscoveryIdentityConfig") | .clusterID + "|" + .clusterSecret' clusterconfig/home-$n.yaml | sha256sum)
  [ "$live" = "$repo" ] && echo "$n: identity unchanged" || echo "$n: IDENTITY DIFFERS"
done
```

Expected: `identity unchanged` for all four. If any says DIFFERS, stop: do not apply; the `TALHELPER_CLUSTERNAME`/`TALHELPER_CLUSTERSECRET` variables do not match what the cluster was built with.

- [ ] **Step 3: Apply to one node, ask the user first**

Ask the user to confirm, then apply to mc1 only: `task talos:apply N=mc1` (live, no reboot; the task runs generate, a health wait and a node health check).

- [ ] **Step 4: Verify membership and the Kubernetes registry**

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.2 get members
talosctl -n 192.168.48.2 get affiliates
talosctl -n 192.168.48.2 get machineconfig v1alpha1 -o yaml | yq '.spec | select(.kind == "DiscoveryServiceConfig")'
talosctl -n 192.168.48.2 get discoveryconfig -o yaml 2>/dev/null | head -30
```

Expected: all four nodes in `members`; the live config has the `DiscoveryServiceConfig`; the discovery config shows the service registry on and the Kubernetes registry off. If the Kubernetes registry shows on, add a `KubernetesRegistryConfig`-style document that disables it (check `talosctl docs --config` for the exact kind on 1.14) in a follow-up patch before applying further, and update the spec.

- [ ] **Step 5: Apply to the remaining nodes, one at a time**

After the user confirms each: `task talos:apply N=mc2`, then `mc3`, then `nv1`. After each apply repeat the `get members` check from Step 4. Never touch nv1's network config; this change does not.

- [ ] **Step 6: Final check**

Run: `task talos:diff`
Expected: `no differences` for every node. Then check the cluster is healthy: `kubectl get nodes` (all Ready).

- [ ] **Step 7: Rollback, only if needed**

Revert the PR on a branch, `task talos:generate`, and `task talos:apply N=<node>` per node. The legacy fields restore the same identity values, so membership is unaffected.

---

## Self-Review

- **Spec coverage:** goals 1 and 2 are Tasks 2 and 4 (documents present, legacy removed, hash proof); goal 3 is Task 4 Step 1 and 6; masking requirement is Task 1; unset/empty variable and per-node validation are Task 2; docs list in the spec is Task 3; Kubernetes registry confirmation and rollback are Task 4.
- **Placeholders:** none; the one wording-dependent edit (layout spec bullet, TODO "Next" line) says to read the text first because exact line wrapping is not copied here.
- **Names:** `90-discovery-service.yaml`, `91-discovery-identity.yaml.tpl`, `92-discovery-legacy-delete.yaml`, `TALHELPER_CLUSTERNAME`, `TALHELPER_CLUSTERSECRET` are used identically in every task.
