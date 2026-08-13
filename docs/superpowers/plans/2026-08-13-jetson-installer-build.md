# Jetson Installer Build (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish Jetson installer images from an account we control, fix the broken automation seam that stops upstream publishing them, and move nv1 off its Talos v1.13.0 pin.

**Architecture:** A near-mirror fork of `schwankner/talos-jetson-orin` with exactly two divergences. Upstream's CI already builds and publishes on `ubuntu-24.04-arm` to `ghcr.io/<repository_owner>/…`, so the fork needs no new pipeline — only a fix to the `auto-tag` → `release` trigger, plus signing-key secrets. home-ops then consumes the fork's image.

**Tech Stack:** GitHub Actions (`ubuntu-24.04-arm`), ghcr.io, Talos Linux v1.13.x, `talosctl`, `gh` CLI, Renovate.

**Design spec:** `docs/superpowers/specs/2026-08-13-jetson-installer-build-design.md`

## Global Constraints

- **Never mutate cluster state without explicit user confirmation.** Steps marked **⚠ CONFIRM** must stop and ask first — this covers `talosctl upgrade` and `task talos:apply`.
- **Never push to `main`** in home-ops. All changes via PR; `feat/`, `fix/`, `chore/` prefixes.
- **Never commit secrets.** The signing key goes to Bitwarden and GitHub secrets only. `keys/` is gitignored upstream — keep it that way.
- **The signing key must never change once nv1 runs modules signed with it.** A running node rejects modules signed by a different key. Generate once, store durably.
- Fork repo: `mmalyska/talos-jetson-orin`. Image consumed by home-ops: `ghcr.io/mmalyska/custom-installer:<talos>-<kernel>-nvgpu<nvgpu>`.
- Upstream `common.sh` currently holds `TALOS_VERSION=1.13.8` (**no `v` prefix**) and `PKGS_COMMIT=f3829f74` (kernel **6.18.24**).
- Build cost: **~90 min cold cache, ~5 min cache hit** for extensions, plus ~30 min USB/UKI assembly. The first build in a fresh namespace is always cold.
- `TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig` for all `talosctl` calls.
- Non-interactive shell: use `-f`/`-rf` with `cp`/`mv`/`rm`.
- Run `npx prettier --write <file>` on any Markdown/YAML touched in home-ops before committing.
- **YAML snippets below render at column 0.** Prettier normalizes fenced YAML, so indentation does not reflect nesting depth. Place each at the depth the prose describes and confirm with the verify step that follows.

---

### Task 1: Fork, enable Actions, and install the signing key

**Files:** none in home-ops (all work is on the fork).

**Interfaces:**

- Consumes: nothing.
- Produces: `mmalyska/talos-jetson-orin` with Actions enabled and `SIGNING_KEY_PEM` / `SIGNING_KEY_X509` set. Task 2 runs the first build against it.

- [ ] **Step 1: Fork the repository**

```bash
gh repo fork schwankner/talos-jetson-orin --clone=false --remote=false
gh repo view mmalyska/talos-jetson-orin --json name,isFork,parent \
  --jq '"\(.name) fork=\(.isFork) parent=\(.parent.nameWithOwner)"'
```

Expected: `talos-jetson-orin fork=true parent=schwankner/talos-jetson-orin`.

- [ ] **Step 2: Confirm the v1.13.8 tag came across**

The fork must carry the existing tag, because Task 2 builds against it rather than waiting for a Renovate bump.

```bash
gh api repos/mmalyska/talos-jetson-orin/tags --jq '.[].name' | grep 1.13.8
```

Expected: `v1.13.8-nvgpu5.11.1-drm-noshim`. If absent, push it from a local clone of upstream.

- [ ] **Step 3: Enable Actions on the fork**

GitHub disables Actions on forks by default — without this nothing runs at all, silently.

```bash
gh api -X PUT repos/mmalyska/talos-jetson-orin/actions/permissions \
  -f enabled=true -f allowed_actions=all
gh api repos/mmalyska/talos-jetson-orin/actions/permissions --jq '.enabled'
```

Expected: `true`.

- [ ] **Step 4: Generate the signing key**

```bash
cd /tmp
rm -rf tjo-keys && git clone --depth 1 https://github.com/mmalyska/talos-jetson-orin.git tjo-keys
cd tjo-keys && ./scripts/setup-keys.sh
ls -l keys/
openssl x509 -in keys/signing_key.x509 -noout -serial -subject
```

Expected: `keys/signing_key.pem` and `keys/signing_key.x509` exist, and the cert prints a serial.

- [ ] **Step 5: Store the key in Bitwarden as the source of truth**

Before it goes anywhere else. Losing this pair means regenerating, rebuilding everything, and reinstalling nv1.

Store both files' full contents as a Bitwarden Secrets Manager entry (suggested name `jetson-installer-signing-key`), then confirm both are retrievable before continuing.

- [ ] **Step 6: Set the fork's Actions secrets**

```bash
cd /tmp/tjo-keys
gh secret set SIGNING_KEY_PEM  --repo mmalyska/talos-jetson-orin < keys/signing_key.pem
gh secret set SIGNING_KEY_X509 --repo mmalyska/talos-jetson-orin < keys/signing_key.x509
gh secret list --repo mmalyska/talos-jetson-orin
```

Expected: both secrets listed. No PAT is needed — the dispatch fix in Task 3 uses `GITHUB_TOKEN`.

- [ ] **Step 7: Remove the local key copy**

```bash
cd /tmp && rm -rf tjo-keys
```

The key now lives in Bitwarden and GitHub secrets only.

---

### Task 2: First build, publish, and make the image pullable

**⚠ Long-running:** cold cache, so expect ~2h total (~90 min extensions + ~30 min assembly).

**Files:** none.

**Interfaces:**

- Consumes: the fork and secrets from Task 1.
- Produces: `ghcr.io/mmalyska/custom-installer:1.13.8-6.18.24-nvgpu5.11.1-drm-noshim`, **publicly pullable**. Task 4 references it.

- [ ] **Step 1: Dispatch the release build against the existing tag**

No `auto-tag` fix is needed yet — dispatching manually is exactly what Task 3 automates.

```bash
gh workflow run release.yaml --repo mmalyska/talos-jetson-orin \
  --ref v1.13.8-nvgpu5.11.1-drm-noshim
sleep 20
gh run list --repo mmalyska/talos-jetson-orin --limit 3 \
  --json name,status,headBranch --jq '.[] | "\(.name) \(.status) (\(.headBranch))"'
```

Expected: a `Build USB Image` run in progress against that tag.

- [ ] **Step 2: Watch it to completion**

```bash
gh run watch --repo mmalyska/talos-jetson-orin \
  "$(gh run list --repo mmalyska/talos-jetson-orin --limit 1 --json databaseId --jq '.[0].databaseId')"
```

Expected: success. On failure, read the logs — the most likely causes are a missing/malformed secret or an upstream build break, not the fork itself.

- [ ] **Step 3: Confirm the expected tag was produced**

The tag is `${TALOS_VERSION}-${KERNEL_VERSION}-nvgpu${NVGPU_VERSION}`, and `TALOS_VERSION` has **no `v` prefix** in current `common.sh`.

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:mmalyska/custom-installer:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://ghcr.io/v2/mmalyska/custom-installer/tags/list | jq -r '.tags[]?'
```

Expected to include `1.13.8-6.18.24-nvgpu5.11.1-drm-noshim`.

- [ ] **Step 4: Make the packages public**

**This is the step most likely to be missed.** GHCR packages default to **private**, and nv1 pulls its installer anonymously — a private image means the upgrade fails to pull with no obvious clue.

Set visibility to public for `custom-installer` (required) and the three supporting packages (`kernel-modules-clang`, `nvidia-tegra-nvgpu`, `nvidia-firmware-ext`), via the package settings UI or:

```bash
for p in custom-installer kernel-modules-clang nvidia-tegra-nvgpu nvidia-firmware-ext; do
  gh api -X PATCH "user/packages/container/$p" -f visibility=public 2>&1 | head -2
done
```

- [ ] **Step 5: Verify an anonymous pull works**

This is the check that actually matters — it proves nv1 can fetch the image.

```bash
IMG=ghcr.io/mmalyska/custom-installer:1.13.8-6.18.24-nvgpu5.11.1-drm-noshim
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:mmalyska/custom-installer:pull&service=ghcr.io" | jq -r .token)
curl -s -o /dev/null -w "manifest HTTP %{http_code}\n" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/mmalyska/custom-installer/manifests/1.13.8-6.18.24-nvgpu5.11.1-drm-noshim"
```

Expected: `manifest HTTP 200`. A `401`/`403` means the package is still private — fix before Task 4.

---

### Task 3: Fix the auto-tag → release seam

**Files:**

- Modify (fork): `.github/workflows/auto-tag.yaml`

**Interfaces:**

- Consumes: nothing from Task 2.
- Produces: an automated chain so a merged Renovate bump yields an image with no manual dispatch. Task 6 sends this same patch upstream.

- [ ] **Step 1: Record the defect**

`release.yaml` triggers on `push: tags: ['v*']`, and the tag matches — but `auto-tag.yaml` pushes it using the default `GITHUB_TOKEN`, and GitHub does not let events created by that token start workflow runs. Upstream has no `Build USB Image` run in its entire history despite `auto-tag` succeeding on 2026-08-04.

`workflow_dispatch` is the documented exception to that restriction.

- [ ] **Step 2: Add the `actions: write` permission**

In the fork's `.github/workflows/auto-tag.yaml`, extend the top-level block:

```yaml
permissions:
  contents: write
  actions: write # required to dispatch release.yaml
```

- [ ] **Step 3: Give the tag step an id and an output**

Replace the existing `Create and push tag (skip if already exists)` step — which currently has no `id` and only echoes — with:

```yaml
- name: Create and push tag (skip if already exists)
  id: tag
  env:
    TAG: ${{ steps.versions.outputs.tag }}
  run: |
    if git rev-parse "${TAG}" >/dev/null 2>&1; then
      echo "✓ Tag ${TAG} already exists — nothing to do"
      echo "created=false" >> "$GITHUB_OUTPUT"
    else
      git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
      git config user.name  "github-actions[bot]"
      git tag "${TAG}"
      git push origin "${TAG}"
      echo "✓ Created tag: ${TAG}"
      echo "created=true" >> "$GITHUB_OUTPUT"
    fi
```

- [ ] **Step 4: Dispatch the release build**

Append as a new final step:

```yaml
- name: Trigger release build for the new tag
  if: steps.tag.outputs.created == 'true'
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    TAG: ${{ steps.versions.outputs.tag }}
  run: |
    gh workflow run release.yaml --ref "${TAG}"
    echo "✓ Dispatched release.yaml for ${TAG}"
```

- [ ] **Step 5: Verify the workflow parses**

```bash
cd /tmp && rm -rf tjo-fix && git clone --depth 1 https://github.com/mmalyska/talos-jetson-orin.git tjo-fix
cd tjo-fix
python3 -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/auto-tag.yaml'));
print('permissions:', d['permissions']);
steps=d['jobs']['create-tag']['steps'];
print('step ids:', [s.get('id') for s in steps]);
print('last step:', steps[-1]['name'])"
```

Expected: `permissions` includes `actions: write`; a step with `id: tag` exists; the last step is the dispatch.

- [ ] **Step 6: Commit to the fork**

```bash
cd /tmp/tjo-fix
git checkout -b fix/dispatch-release-after-autotag
git add .github/workflows/auto-tag.yaml
git commit -m "fix(ci): dispatch release.yaml after auto-tagging

auto-tag pushes the release tag using the default GITHUB_TOKEN, and
GitHub does not let events created by that token start workflow runs -
so release.yaml never fires and no image is ever published. Dispatch it
explicitly instead; workflow_dispatch is the documented exception to
that restriction, so no PAT is required."
git push -u origin fix/dispatch-release-after-autotag
```

Merge it into the fork's `main` (a PR within the fork, or push directly — it is your repo).

---

### Task 4: Point nv1 at the fork's image and collapse the version duplicate

**Files:**

- Modify: `provision/talos/nodes/nv1.yaml`
- Modify: `provision/talos/nodes.yaml`
- Modify: `.taskfiles/talos/Taskfile.yaml`

**Interfaces:**

- Consumes: the publicly pullable image from Task 2.
- Produces: a generated `home-nv1.yaml` referencing the fork image. Task 5 installs it.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops
git checkout main && git pull
git checkout -b feat/nv1-fork-installer
```

- [ ] **Step 2: Point nv1 at the fork image**

In `provision/talos/nodes/nv1.yaml`, change `machine.install.image` to:

```yaml
image: ghcr.io/mmalyska/custom-installer:1.13.8-6.18.24-nvgpu5.11.1-drm-noshim
```

Note the absent `v` prefix — the tag is built from `TALOS_VERSION=1.13.8` in `common.sh`.

- [ ] **Step 3: Delete the duplicated version key**

In `provision/talos/nodes.yaml`, remove the `talosVersion: v1.13.0` line from the nv1 entry, leaving:

```yaml
- name: nv1
  ip: 192.168.48.5
  type: worker
```

- [ ] **Step 4: Derive the version from the image tag instead**

In `.taskfiles/talos/Taskfile.yaml`, replace the `NODE_TALOS_VERSION` var added in Phase 1 with:

```yaml
NODE_TALOS_VERSION:
  sh: |
    v=$(yq '.machine.install.image' {{.TALOS_DIR}}/clusterconfig/home-{{.N}}.yaml \
          | sed -n 's|.*custom-installer:v\{0,1\}\([0-9.]*\)-.*|v\1|p')
    echo "${v:-{{ .TALOS_VERSION }}}"
```

Two behaviours this depends on, both verified: `sed -n …p` **exits 0 even when nothing matches**, so a `|| echo` fallback would silently produce an empty version — the fallback must test the captured value. And the `v` prefix is optional, because published tags use `v1.13.0-…` while new ones read `1.13.8-…`.

- [ ] **Step 5: Verify version resolution for every node**

```bash
cd /workspaces/home-ops
task talos:generate
for n in mc1 mc2 mc3 nv1; do
  img=$(yq '.machine.install.image' provision/talos/clusterconfig/home-$n.yaml)
  v=$(echo "$img" | sed -n 's|.*custom-installer:v\{0,1\}\([0-9.]*\)-.*|v\1|p')
  printf "%-4s -> %s\n" "$n" "${v:-<global TALOS_VERSION>}"
done
```

Expected: `mc1`/`mc2`/`mc3` → `<global TALOS_VERSION>` (they use the stock factory installer), `nv1` → `v1.13.8`.

- [ ] **Step 6: Verify the generated nv1 config**

```bash
yq '.machine.install.image' provision/talos/clusterconfig/home-nv1.yaml
yq '.machine.kernel.modules[].name' provision/talos/clusterconfig/home-nv1.yaml | tr '\n' ' '; echo
yq '.machine.files[].path' provision/talos/clusterconfig/home-nv1.yaml
```

Expected: the fork image; all eight GPU modules still present; both `/etc/cri/conf.d/20-customization.part` and `/etc/cri/containerd.toml` still present.

- [ ] **Step 7: Commit, push, PR**

```bash
cd /workspaces/home-ops
npx --yes prettier --write provision/talos/nodes/nv1.yaml provision/talos/nodes.yaml
task lint:yaml
git add provision/talos/nodes/nv1.yaml provision/talos/nodes.yaml .taskfiles/talos/Taskfile.yaml
git commit -m "feat(nv1): use our own Jetson installer image

Moves nv1 off the upstream-published v1.13.0 image and onto
ghcr.io/mmalyska/custom-installer, built from our fork. Also collapses
the talosVersion key into the install image tag, which already contains
the version - one source of truth instead of two that can desync."
git push -u origin feat/nv1-fork-installer
gh pr create --fill
```

---

### Task 5: Upgrade nv1 and re-verify the GPU

**⚠ CONFIRM** — replaces nv1's boot image. Physical USB rescue is available if it fails to boot.

**Files:** none.

**Interfaces:**

- Consumes: merged Task 4.
- Produces: nv1 on Talos v1.13.8 with a working GPU.

- [ ] **Step 1: Record the pre-state**

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
kubectl get node nv1 -o wide --no-headers
kubectl get node nv1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'; echo
talosctl -n 192.168.48.5 ls /dev/dri
```

Expected now: Talos v1.13.0, kernel 6.18.24-talos, GPU `1`, `renderD128` present.

- [ ] **Step 2: ⚠ CONFIRM — apply config and upgrade**

Ask the user before running.

```bash
cd /workspaces/home-ops
task talos:apply N=nv1
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 upgrade \
  --image ghcr.io/mmalyska/custom-installer:1.13.8-6.18.24-nvgpu5.11.1-drm-noshim \
  --wait=false
```

- [ ] **Step 3: Gate — node returns on the new version**

```bash
talosctl -n 192.168.48.5 health --wait-timeout=15m --server=false
kubectl get node nv1 -o wide --no-headers
```

Pass: `Ready`, `Talos (v1.13.8)`, kernel still `6.18.24-talos` (the kernel comes from the pinned `PKGS_COMMIT`, not from the Talos version).

**Fail → stop.** Recovery: revert `nodes/nv1.yaml` to `ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim` and re-upgrade, or USB reflash.

- [ ] **Step 4: Gate — the GPU still works**

This is what proves our build is equivalent to upstream's.

```bash
talosctl -n 192.168.48.5 read /proc/modules | grep -E "nvgpu|tegra_drm|host1x"
talosctl -n 192.168.48.5 ls /dev/dri
kubectl get node nv1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'; echo
kubectl -n nvidia-system get pods -o wide --no-headers | awk '{print $1, $3, $7}'
kubectl -n ollama get pods --no-headers
```

Pass: `nvgpu` loaded; `renderD128` present; `nvidia.com/gpu: 1`; all three nvidia DaemonSets `Running` on nv1; ollama `Running`.

- [ ] **Step 5: Gate — inference still performs**

```bash
kubectl -n ollama exec deploy/ollama -- \
  ollama run qwen3.5:9b --verbose "Write a haiku about storage." 2>&1 | tail -8
```

Pass: `eval rate` within ~10% of the **GPU** figure in `docs/superpowers/plans/artifacts/2026-08-13-nv1-cpu-baseline.md` — that file holds both the CPU baseline and the Phase 1 GPU result, so compare against the GPU one, not the CPU one. A drop toward the CPU figure means the CUDA backend is not engaging; check `JETSON_JETPACK` reached the container before concluding the build is bad.

- [ ] **Step 6: Confirm the version guard behaves**

```bash
cd /workspaces/home-ops
task talos:upgrade N=nv1 --dry-run 2>&1 | tail -5
```

Pass: reports nv1 already at its version and skips. If it wants to upgrade, the Task 4 Step 4 derivation is wrong.

- [ ] **Step 7: Record the outcome**

Append an Outcome section to `docs/superpowers/specs/2026-08-13-jetson-installer-build-design.md`: which gates passed, the measured `eval rate`, and the image tag now in use. Commit and push.

---

### Task 6: Send the fix upstream

**Files:** none in home-ops.

- [ ] **Step 1: Open the PR against upstream**

From the fork branch created in Task 3:

```bash
gh pr create --repo schwankner/talos-jetson-orin \
  --head mmalyska:fix/dispatch-release-after-autotag \
  --title "fix(ci): dispatch release.yaml after auto-tagging" \
  --body "auto-tag.yaml pushes the release tag using the default GITHUB_TOKEN. GitHub does not let events created by that token start new workflow runs, so release.yaml never fires and no image is published.

Evidence: the tag \`v1.13.8-nvgpu5.11.1-drm-noshim\` was created by a successful auto-tag run on 2026-08-04, but there is no corresponding \`Build USB Image\` run and no \`custom-installer:1.13.8-*\` image on ghcr.

Fix: dispatch release.yaml explicitly after tagging. \`workflow_dispatch\` is the documented exception to the GITHUB_TOKEN restriction, so this needs no PAT and nothing changes for forks.

Verified equivalent to a tag push: release.yaml guards its GitHub Release step with \`startsWith(github.ref, 'refs/tags/')\`, and dispatching with \`--ref <tag>\` satisfies that."
```

- [ ] **Step 2: Report the unrelated bug separately**

Do not bundle it. Comment on their issue #36, or open a new one: `check-talos.yaml` compares `TALOS_VERSION` from `common.sh` (`1.13.8`, no prefix) against the API's `tag_name` (`v1.13.8`), so the equality test never matches and it reports an update against itself.

- [ ] **Step 3: Note the outcome**

If merged, drop the local patch on the next upstream sync so the fork's only divergence is `renovate.json`. If not, carry it — that is acceptable and expected.

---

### Task 7: Renovate on the fork

**Files:**

- Modify (fork): `renovate.json`

**Interfaces:**

- Consumes: the working dispatch chain from Task 3.
- Produces: the automated maintenance loop — merge a Renovate PR, get an image.

- [ ] **Step 1: Point assignees and reviewers at yourself**

In the fork's `renovate.json`, change:

```json
"assignees": ["mmalyska"],
"reviewers": ["mmalyska"]
```

Leave every `packageRule` as upstream has it — their policy is already correct: Talos **patch** updates require manual review (`automerge: false`), and **minor/major** auto-updates are disabled pending nvgpu compatibility testing.

- [ ] **Step 2: Enable Renovate on the fork**

Install/enable the Renovate app for `mmalyska/talos-jetson-orin`, then confirm it opens a Dependency Dashboard issue.

```bash
gh issue list --repo mmalyska/talos-jetson-orin --limit 5 \
  --json number,title --jq '.[] | "#\(.number) \(.title)"'
```

Expected: a Dependency Dashboard issue appears (may take a scan cycle).

- [ ] **Step 3: Verify the full loop on the next Talos release**

This cannot be forced; it validates on the next real release. When Renovate opens a `TALOS_VERSION` PR, merge it and confirm the chain:

```bash
gh run list --repo mmalyska/talos-jetson-orin --limit 5 \
  --json name,conclusion --jq '.[] | "\(.name) → \(.conclusion)"'
```

Expected: `Auto-tag on version change` **and then** `Build USB Image`. Seeing auto-tag without the build means the Task 3 fix regressed.

---

### Task 8 (optional track): Kernel parity with mainline Talos

Independent of everything above. Only start when you want it; fully revertible.

**Files:**

- Modify (fork): `scripts/common.sh`

- [ ] **Step 1: Find the pkgs commit for the target Talos version**

Talos pins its pkgs build in its Makefile:

```bash
curl -fsSL https://raw.githubusercontent.com/siderolabs/talos/v1.13.8/Makefile | grep '^PKGS ?='
```

Expected: `PKGS ?= v1.13.0-55-gf677246` → pkgs commit `f677246`.

- [ ] **Step 2: Confirm which kernel that commit carries**

```bash
curl -fsSL https://raw.githubusercontent.com/siderolabs/pkgs/f677246a/Pkgfile | grep linux_version
```

Expected: `linux_version: 6.18.42` — versus `6.18.24` at the currently pinned `f3829f74`.

- [ ] **Step 3: Bump the pin**

In the fork's `scripts/common.sh`:

```bash
PKGS_COMMIT="${PKGS_COMMIT:-f677246a}"   # matches Talos v1.13.8 (kernel 6.18.42)
```

Commit and merge to the fork's `main`. Renovate's bump of `TALOS_VERSION` is unrelated — this is the kernel side of the pair.

- [ ] **Step 4: Build — expect the slow path**

Changing the kernel invalidates the extension cache (images are keyed by `${KERNEL_VERSION}`), so this is a full ~90 min extension build plus assembly, not the ~5 min cache hit.

```bash
gh workflow run release.yaml --repo mmalyska/talos-jetson-orin --ref main
gh run watch --repo mmalyska/talos-jetson-orin \
  "$(gh run list --repo mmalyska/talos-jetson-orin --limit 1 --json databaseId --jq '.[0].databaseId')"
```

**If the OE4T modules fail to compile against 6.18.42, stop.** That is the expected failure mode and the answer is to revert Step 3 — the pinned OE4T sources (`linux-nvgpu@d530a48d`, `linux-nv-oot@ea32e7f9`, `linux-hwpm@4d8a6998`) target kernel 6.18 generally, but a specific patch can still conflict.

- [ ] **Step 5: Verify the new tag, then repeat Task 5 against it**

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:mmalyska/custom-installer:pull&service=ghcr.io" | jq -r .token)
curl -s -H "Authorization: Bearer $TOKEN" \
  https://ghcr.io/v2/mmalyska/custom-installer/tags/list | jq -r '.tags[]?' | grep 6.18.42
```

Expected: `1.13.8-6.18.42-nvgpu5.11.1-drm-noshim`. Then update `nodes/nv1.yaml` to that tag and re-run **Task 5 in full** — the GPU gates matter more here than for a Talos-only bump, because the kernel actually changed.

- [ ] **Step 6: Confirm parity**

```bash
kubectl get nodes -o custom-columns='NODE:.metadata.name,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion' --no-headers
```

If PR #4503 (Talos v1.13.8 for the cluster) is also merged, all four nodes should report the same Talos version **and** `6.18.42-talos` — parity Phase 1 could not achieve.

---

### Task 9: Rollback reference (run only if a gate fails)

- [ ] **Step 1: Revert nv1 to the upstream image**

In `provision/talos/nodes/nv1.yaml`:

```yaml
image: ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim
```

- [ ] **Step 2: ⚠ CONFIRM — regenerate and reinstall**

```bash
cd /workspaces/home-ops
task talos:generate
task talos:upgrade N=nv1 FORCE=true
```

- [ ] **Step 3: Verify**

nv1 back on Talos v1.13.0, `Ready`, GPU allocatable `1`, ollama `Running`.

The version derivation from Task 4 keeps working — it reads `v1.13.0` from the reverted tag with no other change. The fork can be left in place or deleted; neither affects the cluster.
