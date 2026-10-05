# Talos Install Document Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `machine.install` to the `UnattendedInstallConfig` document (installer image, disk selector, explicit `wipe: false`), teach the tooling that reads the install image to read the new document, and apply it node by node.

**Architecture:** Three file tasks in one PR (readers and their fixtures first, then the patch files with a render-test guard, then the docs), followed by a node-by-node apply. The document is inert on installed nodes, so the apply is `install-only` and needs no reboot. The disk selector (a CEL expression) is repeated in the last patch applied per node, because a later merge drops it.

**Tech Stack:** Talos v1.14.2, `talosctl`, the layered patch pipeline in `provision/talos/`, yq (mikefarah v4), go-task, bash tests under `provision/talos/tests/`.

**Spec:** `docs/superpowers/specs/2026-10-05-talos-install-document-design.md`

## Global Constraints

- Never write the private cluster domain literally. Never commit secrets (gitleaks runs on commit). Do not print environment variables.
- Never mutate the cluster (`task talos:apply`, `talosctl apply-config` without `--dry-run`) without the user's explicit confirmation, per node. Never run `task talos:upgrade` without `--dry`: if the reader misreads the version the task would start a real upgrade.
- Never push to `main`; branch prefix `chore/` or `docs/`; every branch is pushed and gets a PR.
- Patch files follow the layout rules of `scripts/check-patches.sh`: name `NN-some-name.yaml[.tpl]`, four header lines (`# What:`, `# Why:`, `# Nodes:`, `# Apply:`), one document per file, `${...}` only in `.tpl` files and only variables from `TPL_VARS`.
- `docs/src/talos/config-map.md` is generated: run `task talos:config-map` after any patch header or file change.
- Tests are bash files under `provision/talos/tests/`; run all with `provision/talos/tests/run.sh`. A test is written first and watched failing before the code that satisfies it.
- Rendering and `task talos:diff` need the Bitwarden-derived environment (`.envrc`) and:

  ```bash
  export TALOSCONFIG="$PWD/provision/talos/clusterconfig/talosconfig"
  export TALOS_VERSION="$(yq '.vars.TALOS_VERSION' .taskfiles/talos/Taskfile.yaml)"
  export KUBERNETES_VERSION="$(yq '.vars.KUBERNETES_VERSION' .taskfiles/talos/Taskfile.yaml)"
  ```

- Node IPs: mc1 `192.168.48.2`, mc2 `192.168.48.3`, mc3 `192.168.48.4`, nv1 `192.168.48.5`.
- Branch: cut from `origin/main` once the spec and plan PRs are merged (`git fetch origin && git switch -c chore/talos-install-document origin/main`); until then cut it from the plan branch (stacked).

## Review Focus

The spec implies these failure modes that no single task's file-level checks cover:

1. **Lost CEL selector.** A later merge drops `provisioning.diskSelector.match`. Pinned by the render-test guard (Task 2 Step 1) and by `talosctl validate` in Task 2 Step 4.
2. **`wipe` default.** The document's `wipe` defaults to true; every node must render `wipe: false`. Pinned by the render-test guard.
3. **Readers.** `expected-version.sh` and the `upgrade` task must read the new document, not the legacy field; a misread would make `task talos:upgrade` start a real upgrade. Pinned by the fixtures (Task 1) and by Task 4 Step 2 (`--dry` only).
4. **nv1 image.** nv1 must keep its custom installer image and its expected version `v1.14.0`. Pinned by the render-test guard and Task 4.
5. **No reboot.** The change must stay `install-only` with no reboot. Pinned by the dry run per node (Task 2 Step 4, Task 4).

---

## Task 1: Teach the readers the new document (RED, then GREEN)

**Files:**

- Modify: `provision/talos/tests/test_lib.sh` (the `expected-version.sh` fixture)
- Modify: `provision/talos/tests/test_diff_live.sh` (the rendered fixture and `custom.yaml`)
- Modify: `provision/talos/scripts/lib.sh` (`expected_version`)
- Modify: `.taskfiles/talos/Taskfile.yaml` (`upgrade` task, `TALOS_IMAGE`)

**Interfaces:**

- Consumes: nothing from earlier tasks.
- Produces: `expected_version <rendered-config>` and the `upgrade` task read `select(.kind == "UnattendedInstallConfig") | .installer.image`; Task 2 renders configs that carry that document.

- [ ] **Step 1: Change the fixtures (the tests, written first)**

`provision/talos/tests/test_lib.sh`: replace the `r.yaml` heredoc

```bash
cat > "$TMP/r.yaml" <<'YAML'
version: v1alpha1
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
```

with

```bash
cat > "$TMP/r.yaml" <<'YAML'
version: v1alpha1
machine:
  token: sometoken
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
```

`provision/talos/tests/test_diff_live.sh`: replace the `rendered/home-mc1.yaml` heredoc

```bash
cat > "$TMP/rendered/home-mc1.yaml" <<'YAML'
version: v1alpha1
machine:
  token: sometoken
  install:
    image: factory.talos.dev/metal-installer/abc:v1.14.2
  sysctls:
    a: "1"
YAML
```

with

```bash
cat > "$TMP/rendered/home-mc1.yaml" <<'YAML'
version: v1alpha1
machine:
  token: sometoken
  sysctls:
    a: "1"
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/abc:v1.14.2
YAML
```

and replace the `custom.yaml` heredoc

```bash
cat > "$TMP/custom.yaml" <<'YAML'
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
```

with

```bash
cat > "$TMP/custom.yaml" <<'YAML'
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
```

- [ ] **Step 2: Run the tests and watch them fail (RED)**

```bash
bash provision/talos/tests/test_lib.sh 2>&1 | grep -E "FAIL|tests,"
bash provision/talos/tests/test_diff_live.sh 2>&1 | grep -E "FAIL|tests,"
```

Expected: `FAIL prints the leading Talos version of a custom tag` (`11 tests, 1 failed`) and, for `test_diff_live.sh`, `FAIL a Factory image tag is the version` and `FAIL a custom installer tag yields its leading Talos version` (`8 tests, 2 failed`). The failures are empty versions, because the reader still looks at `machine.install`.

- [ ] **Step 3: Change the readers (GREEN)**

In `provision/talos/scripts/lib.sh`, in `expected_version`, replace

```bash
  image="$(yq -N 'select(.machine != null) | .machine.install.image' "$1")"
```

with

```bash
  image="$(yq -N 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$1")"
```

In `.taskfiles/talos/Taskfile.yaml`, in the `upgrade` task, replace

```yaml
sh: yq ea '[.machine.install.image].[0]' < "{{.FILE}}"
```

with

```yaml
sh: yq -N 'select(.kind == "UnattendedInstallConfig") | .installer.image' "{{.FILE}}"
```

- [ ] **Step 4: Run the tests and lint (GREEN)**

```bash
bash provision/talos/tests/test_lib.sh 2>&1 | grep -E "FAIL|tests,"                # Expected: 11 tests, 0 failed
bash provision/talos/tests/test_diff_live.sh 2>&1 | grep -E "FAIL|tests,"          # Expected: 8 tests, 0 failed
yamllint -c .github/linters/.yamllint.yaml .taskfiles/talos/Taskfile.yaml && echo yamllint-ok
provision/talos/tests/run.sh 2>&1 | grep -E "tests,"                                # Expected: every file "0 failed"
```

- [ ] **Step 5: Commit**

```bash
git switch -c chore/talos-install-document
git add -A
git commit -m "feat(talos): read the installer image from the UnattendedInstallConfig document"
```

---

## Task 2: The patch files and the render guard (RED, then GREEN)

**Files:**

- Modify: `provision/talos/tests/test_render.sh`
- Modify: `provision/talos/patches/all/30-install.yaml`
- Create: `provision/talos/patches/all/31-install-legacy-delete.yaml`
- Modify: `provision/talos/patches/controlplane/05-install-image.yaml.tpl`, `provision/talos/patches/worker/05-install-image.yaml.tpl`, `provision/talos/patches/node/nv1/20-install-image.yaml`
- Modify: `docs/src/talos/config-map.md` (regenerated)

**Interfaces:**

- Consumes: Task 1 (the readers read `UnattendedInstallConfig`).
- Produces: every node renders one `UnattendedInstallConfig` document with `installer.image`, `provisioning.diskSelector.match` and `provisioning.wipe: false`, and no `machine.install`.

- [ ] **Step 1: Write the render guard (the tests, written first)**

In `provision/talos/tests/test_render.sh`, in the control-plane section, after the line
`assert_contains "$out" "ups.test 1 upsuser upspass secondary" "the nut-client secrets are substituted"` add:

```bash
assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/mc1.yaml")" "the install disk selector survives the merge and wipe is false"
assert_eq "null" "$(yq 'select(.machine != null) | .machine.install' "$TMP/mc1.yaml")" "the legacy machine.install block is removed"
```

and in the worker section, after
`assert_not_contains "$out" "kind: KubeAuthorizerConfig" "workers have no kube-apiserver authorizer documents"` add:

```bash
assert_eq 'disk.dev_path == "/dev/nvme0n1"|false' "$(yq 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match + "|" + (.provisioning.wipe | tostring)' "$TMP/nv1.yaml")" "nv1 keeps the disk selector and wipe false"
assert_eq "ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim" "$(yq 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$TMP/nv1.yaml")" "nv1's custom installer image is carried by the document"
```

- [ ] **Step 2: Run the test and watch it fail (RED)**

```bash
bash provision/talos/tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"
```

Expected: four failures (`install disk selector ... wipe is false`, `legacy machine.install block is removed`, `nv1 keeps the disk selector`, `nv1's custom installer image ...`) and `28 tests, 4 failed`, because the render still produces the legacy block.

- [ ] **Step 3: Write the patch files (GREEN)**

`provision/talos/patches/all/30-install.yaml` (replace the whole file):

```yaml
# What:   Install behaviour for every node: the system disk is never wiped
# Why:    The UnattendedInstallConfig document only acts when a node is not installed yet (a node booted from USB or PXE
#         in maintenance mode installs itself with it); on an installed node it is inert apart from naming the installer
#         image that upgrades use. wipe defaults to true in this document, so false is written explicitly: a deliberate
#         wipe is a manual decision. The installer image and the disk selector are set per role and per node
#         (controlplane/05, worker/05, node/nv1/20). The legacy grubUseUKICmdline has no counterpart: the nodes boot
#         with UKI, grub is not involved
# Nodes:  all nodes
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  wipe: false
```

`provision/talos/patches/all/31-install-legacy-delete.yaml` (new):

```yaml
# What:   Remove the machine.install block that talosctl gen config adds
# Why:    Talos refuses the legacy machine.install next to the UnattendedInstallConfig document (30-install.yaml)
# Nodes:  all nodes
# Apply:  install-only
machine:
  install:
    $patch: delete
```

`provision/talos/patches/controlplane/05-install-image.yaml.tpl` (replace the whole file):

```yaml
# What:   Installer image: Image Factory schematic with the i915, intel-ucode and nut-client extensions, at the Talos version; install disk /dev/nvme0n1
# Why:    Control-plane nodes are Lenovo M720q with Intel GPUs and a UPS; the version tag follows TALOS_VERSION.
#         The disk selector (CEL) is repeated in every file that is applied last for a node (controlplane/05, worker/05,
#         node/nv1/20) because talosctl machineconfig patch drops provisioning.diskSelector.match when a later patch
#         merges into the document; `talosctl validate` fails with "provisioning.diskSelector.match is required" if it is lost
# Nodes:  control plane
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
```

`provision/talos/patches/worker/05-install-image.yaml.tpl` (replace the whole file):

```yaml
# What:   Installer image: Image Factory schematic with kernel arguments only (no extensions), at the Talos version; install disk /dev/nvme0n1
# Why:    Default worker image; nv1 overrides it with its custom installer (node/nv1/20-install-image.yaml).
#         The disk selector (CEL) is repeated in every file that is applied last for a node (controlplane/05, worker/05,
#         node/nv1/20) because talosctl machineconfig patch drops provisioning.diskSelector.match when a later patch
#         merges into the document; `talosctl validate` fails with "provisioning.diskSelector.match is required" if it is lost
# Nodes:  workers
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/185266ddb5b9bb403289377302af1fd44575fe7f2864db5a7a96858837ccbcba:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
```

`provision/talos/patches/node/nv1/20-install-image.yaml` (replace the whole file):

```yaml
# What:   Custom installer image (OE4T nvgpu kernel modules for the Jetson Orin NX); install disk /dev/nvme0n1
# Why:    The Jetson GPU needs the matching kernel and out-of-tree modules, built by schwankner/talos-jetson-orin.
#         The tag is <talos>-<kernel>-nvgpu<version>; the kernel module ABI must match the image (see provision/talos/README.md).
#         The disk selector (CEL) is repeated in every file that is applied last for a node (controlplane/05, worker/05,
#         node/nv1/20) because talosctl machineconfig patch drops provisioning.diskSelector.match when a later patch
#         merges into the document; `talosctl validate` fails with "provisioning.diskSelector.match is required" if it is lost
# Nodes:  nv1
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
```

- [ ] **Step 4: Check, render, validate, dry-run and diff (GREEN)**

```bash
provision/talos/scripts/check-patches.sh                                          # Expected: check-patches: ok
bash provision/talos/tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"             # Expected: 28 tests, 0 failed
task talos:generate
for n in mc1 mc2 mc3 nv1; do talosctl validate --config provision/talos/clusterconfig/home-$n.yaml --mode metal 2>&1 | grep -v WARNING; done
# Expected: four lines "... is valid for metal mode"
for n in mc1 nv1; do echo "$n expected version: $(provision/talos/scripts/expected-version.sh provision/talos/clusterconfig/home-$n.yaml)"; done
# Expected: mc1 v1.14.2, nv1 v1.14.0
out="$(mktemp)"; echo "$out" > /tmp/inst-diff-path
for n in mc1 nv1; do task talos:diff -- $n 2>&1 | grep -v "^task:" | tee -a "$out" | grep -E "^[+-] |^$n"; done
for p in "mc1 192.168.48.2" "nv1 192.168.48.5"; do set -- $p; talosctl -n $2 apply-config --file provision/talos/clusterconfig/home-$1.yaml --mode auto --dry-run 2>&1 | grep -E "Applied|reboot"; done
```

Expected diff for each node: the `+` side has the `UnattendedInstallConfig` document (the node's `installer.image`, `provisioning.diskSelector.match`, `wipe: false`); the `-` side has `machine.install` (`disk`, `grubUseUKICmdline`, `image`, `wipe`); nothing else differs. Both dry runs print `Applied configuration without a reboot`.

- [ ] **Step 5: Config map and checks, commit**

```bash
task talos:config-map
task talos:check                                                                  # Expected: check-patches: ok, config-map: up to date, 0 failed
provision/talos/tests/run.sh 2>&1 | grep -E "tests,"                              # Expected: every file "0 failed" (render 28)
git add -A
git commit -m "feat(talos): install settings as an UnattendedInstallConfig document"
```

---

## Task 3: Docs, TODO and the PR

**Files:**

- Modify: `provision/talos/README.md`, `.claude/skills/talos-config-editing/SKILL.md`, `.plans/TODO.md`

**Interfaces:**

- Consumes: Tasks 1 and 2.
- Produces: docs that describe the document, the repeated selector, the explicit `wipe`, and the (untested) unattended reinstall; PR open.

- [ ] **Step 1: README**

In `provision/talos/README.md`:

- Replace `(the `machine.install` fields)` (line 58) with `(the `UnattendedInstallConfig` document)`.
- In "Nodes on a non-default Talos version", replace the nv1 code block

  ````markdown
  ```yaml
  machine:
    install:
      image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
  ```
  ````

  with

  ````markdown
  ```yaml
  apiVersion: v1alpha1
  kind: UnattendedInstallConfig
  installer:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
  provisioning:
    diskSelector:
      match: disk.dev_path == "/dev/nvme0n1"
  ```
  ````

  and add after the paragraph that follows it: "The disk selector is repeated in this file on purpose: `talosctl machineconfig patch` drops `provisioning.diskSelector.match` when a later patch merges into the document, so it must be in the last file applied for the node (see the header of the file)."

- Add a new section before "## Checks":

  ```markdown
  ## Install settings and reinstalling a node

  `patches/all/30-install.yaml` (explicit `wipe: false`), the role files `controlplane/05` and `worker/05` and
  `node/nv1/20` build one `UnattendedInstallConfig` document per node: installer image, disk selector
  (`disk.dev_path == "/dev/nvme0n1"`) and `wipe: false`. On an installed node the document is inert apart from
  naming the installer image that upgrades use. It is meant to act when a node is not installed yet: a node booted
  from USB or PXE in maintenance mode that is given this config should install itself to the matched disk, without a
  separate `talosctl install`. **That path is expected but untested here**; try it on the first real reinstall and
  record what you find. `wipe` defaults to true in this document and is set to false explicitly, so a wipe stays a
  deliberate manual step.
  ```

- [ ] **Step 2: Skill and TODO**

`.claude/skills/talos-config-editing/SKILL.md`:

- Replace `(`machine.install`)` in the `install-only` explanation with `(the `UnattendedInstallConfig` document)`.
- After the bullet about `KubeAPIServerConfig` and the authorizers, add:
  `- `UnattendedInstallConfig`has two traps:`provisioning.wipe`defaults to true (we write`wipe: false`in`all/30-install.yaml`), and `talosctl machineconfig patch`drops`provisioning.diskSelector.match`(a CEL expression) when a later patch merges into the document, so the selector is repeated in`controlplane/05`, `worker/05`and`node/nv1/20`; `tests/test_render.sh`guards it and`talosctl validate` fails with "match is required" if it is lost`.

`.plans/TODO.md`, in the Tier 2 bullet:

- Replace `` `machine.install` -> `UnattendedInstallConfig` (nv1 keeps its custom installer image, see `provision/talos/README.md`); `` with nothing, and add ``Done: `machine.install` -> `UnattendedInstallConfig` (installer image, CEL disk selector repeated per node, `wipe: false`).`` next to the other Done clauses.
- Remove the sentence that begins `` `machine.install` -> `UnattendedInstallConfig` also needs care `` if it is still present.
- Add a new item under the same Talos heading, to be reported upstream later (the text is the finding, so the report can be filed without redoing the investigation): "**Report upstream (siderolabs/talos): `talosctl machineconfig patch` drops the CEL `match` of `UnattendedInstallConfig` when a later patch merges into the document.** Found 2026-10-05 on v1.14.2. A limitation I found while prototyping: when a later patch merges into a document that already holds `provisioning.diskSelector.match`, the result has no `match`; it survives only in the last patch applied. `talosctl validate` then fails loudly (`provisioning.diskSelector.match is required`). Minimal reproduction with plain files: a base `kind: UnattendedInstallConfig` with `provisioning: {diskSelector: {match: 'disk.dev_path == "/dev/nvme0n1"'}, wipe: false}`, patched with `kind: UnattendedInstallConfig` + `installer: {image: example.test/installer:v1.14.2}`, via `talosctl machineconfig patch base.yaml --patch @patch.yaml`, prints `installer.image` and `wipe: false` but no `diskSelector`. The reverse order (the `match` in the patch, nothing merged afterwards) keeps it, and a single appended document keeps it. Our workaround: the selector is repeated in the last patch per node (`controlplane/05`, `worker/05`, `node/nv1/20`), guarded by `tests/test_render.sh`. Also try an unattended reinstall once and note the result in `provision/talos/README.md`."

- [ ] **Step 3: Lint and commit**

```bash
prettier --ignore-unknown --config .github/linters/.prettierrc.yaml --check provision/talos/README.md .claude/skills/talos-config-editing/SKILL.md
task talos:check                                                                  # Expected: check-patches: ok, config-map: up to date
grep -rn "machine.install" provision/talos/README.md .claude/skills/talos-config-editing/SKILL.md .plans/TODO.md ; echo "(only history or the explanation of the legacy field above)"
git add -A
git commit -m "docs(talos): describe the install document, its traps and the untested reinstall path"
```

- [ ] **Step 4: Push and open the PR**

```bash
git push -u origin HEAD
gh pr create --title "feat(talos): migrate machine.install to UnattendedInstallConfig" --body "$(cat <<BODY
Implements docs/superpowers/specs/2026-10-05-talos-install-document-design.md. machine.install becomes an UnattendedInstallConfig document (installer image per role and node, CEL disk selector, explicit wipe: false); the readers of the install image (expected-version.sh, the upgrade task) read the new document, their fixtures were changed first and failed for the right reason; the render test guards the selector, wipe and nv1's custom image. The disk selector is repeated in the last patch per node because talosctl machineconfig patch drops it on a later merge.

task talos:diff (live vs repo, mc1 and nv1):

$(cat "$(cat /tmp/inst-diff-path)")

install-only, dry run needs no reboot. Apply one node at a time with the checks of Task 4 of the plan.
BODY
)"
rm -f "$(cat /tmp/inst-diff-path)" /tmp/inst-diff-path
```

---

## Task 4: Apply to the nodes, one at a time (after the PR is merged)

Needs the user's go-ahead per node. Native, live cluster. Do not run `task talos:upgrade` without `--dry`.

**Files:** none changed.

**Interfaces:**

- Consumes: the PR merged and `main` pulled; the exports from Global Constraints.
- Produces: the install document live on mc1, mc2, mc3, nv1.

- [ ] **Step 1: Baseline, once**

```bash
git switch main && git pull --ff-only origin main
task talos:generate
talosctl -n 192.168.48.2 get rd 2>/dev/null | grep -i unattended      # note whether an unattended-install status resource exists on 1.14.2
```

- [ ] **Step 2: Apply and verify mc1 first**

```bash
N=mc1; IP=192.168.48.2
task talos:diff -- $N | grep -E "^[+-] |^$N"                         # read it: only the install block becoming the document
task talos:apply N=$N                                                 # user's go-ahead first
talosctl -n $IP get machineconfig v1alpha1 -o yaml | yq '.spec' | yq 'select(.kind == "UnattendedInstallConfig")'
# Expected: installer.image for the control plane at v1.14.2, provisioning.diskSelector.match, wipe: false
provision/talos/scripts/expected-version.sh provision/talos/clusterconfig/home-$N.yaml     # Expected: v1.14.2
yq -N 'select(.kind == "UnattendedInstallConfig") | .installer.image' provision/talos/clusterconfig/home-$N.yaml   # the Taskfile reader; Expected: the image above
task talos:upgrade N=$N --dry                                         # Expected: "up to date" (nothing is run); never without --dry
kubectl get node $N --no-headers | awk '{print $1,$2,$5}'             # Expected: Ready v1.35.9
echo "pods not Running: $(kubectl get pods -A --no-headers | awk '$4!="Running" && $4!="Completed"' | wc -l)"   # Expected: 0
task talos:diff -- $N | grep -E "^$N"                                 # Expected: no differences
```

If the unattended-install status resource exists (Step 1), read it and note the phase (`installed` expected).

- [ ] **Step 3: Repeat Step 2 for mc2 (`N=mc2; IP=192.168.48.3`), mc3 (`N=mc3; IP=192.168.48.4`) and nv1 (`N=nv1; IP=192.168.48.5`)**

Ask the user before each node. For nv1 expect the custom installer image, expected version `v1.14.0`, and check `nvidia.com/gpu` is still `1` before and after:

```bash
kubectl get node nv1 -o jsonpath='gpu={.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

After nv1:

```bash
task talos:diff | grep -E "^(mc|nv)[0-9]"                              # Expected: no differences on all four
```

- [ ] **Rollback (only if a check fails)**

Revert the PR, `task talos:generate`, `task talos:apply N=<node>`. The legacy block is accepted by Talos 1.14 for the legacy contract.

---

## Self-Review

**Spec coverage:**

| Spec                                                                                           | Task                                      |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------- |
| Decision 1 to 5 (migrate, `wipe: false`, CEL selector, no `grubUseUKICmdline`, `reboot` unset) | 2 (files; no `reboot` key)                |
| Design: `all/30`, role and node files with image and selector, `all/31` delete                 | 2                                         |
| Design: readers and fixtures RED then GREEN                                                    | 1                                         |
| Design: docs, skill, TODO                                                                      | 3                                         |
| Design: render test guard                                                                      | 2 (Steps 1 and 2)                         |
| Rollout table (diff, live document, expected version, upgrade check, node Ready, diff after)   | 4                                         |
| Rollback                                                                                       | 4                                         |
| Risks: lost CEL, readers, maintenance-mode install, tuppr, untested reinstall                  | Review Focus 1 to 5; README note (Task 3) |
| Open items: unattended status resource, reinstall note in the README                           | 4 Step 1, 3 Step 1                        |

**Placeholder scan:** none. Every file and every test edit is given in full.

**Name consistency:** `UnattendedInstallConfig`, `installer.image`, `provisioning.diskSelector.match` and `provisioning.wipe` are used identically in the files, tests and docs; the file numbers (`all/30`, `all/31`, `controlplane/05`, `worker/05`, `node/nv1/20`) match the spec.

**Verified before writing:** the whole change was prototyped in a scratch copy: all four nodes render and validate, the live diff is only the install block becoming the document, the dry runs for mc1 and nv1 need no reboot, `expected-version.sh` prints `v1.14.2` and `v1.14.0`, and the three fixtures were the only failing tests. The count `28` for the render test assumes the four new assertions on top of the current 24. Checks that need the live cluster (the live document read, the unattended status resource, `task talos:upgrade --dry`) are untested until Task 4.
