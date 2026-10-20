# Jetson Installer Build (Phase 2) — Design

## Context

Phase 1 gave nv1 a working GA10B iGPU by installing an upstream-published
Talos UKI carrying the OE4T DRM stack. It succeeded — `/dev/dri/renderD128`
exists, `nvidia.com/gpu: 1` is allocatable, and ollama runs at 2.75x the node's
CPU baseline. See `2026-08-13-jetson-igpu-design.md`.

It left one deliberate compromise: **nv1 is pinned to Talos v1.13.0** because
that is the only version
[schwankner/talos-jetson-orin](https://github.com/schwankner/talos-jetson-orin)
has ever published an installer image for, while the rest of the cluster runs
v1.13.5 (and PR #4503 proposes v1.13.8).

### What investigation actually found

The Phase 1 spec assumed Phase 2 meant building a CI pipeline from scratch —
~2h ARM64 builds, signing-key plumbing, a new workflow. That was wrong on every
count.

**1. The pipeline already exists and is fork-ready.** `release.yaml` runs on
`ubuntu-24.04-arm` (free for public repos), takes signing keys from
`secrets.SIGNING_KEY_PEM` / `SIGNING_KEY_X509`, and publishes to
`ghcr.io/${{ github.repository_owner }}/…`. Being parameterised by
`repository_owner`, **a fork publishes to the fork owner's namespace with zero
workflow edits**.

**2. The signing key never needed committing.** `keys/` is gitignored,
`setup-keys.sh` generates an RSA-4096 pair, and CI injects it from secrets.
Upstream's "commit the key for reproducible builds" note applies to local builds
only.

**3. Upstream is already on Talos 1.13.8.** Their Renovate bumped
`TALOS_VERSION` in `scripts/common.sh` (PR #21, 2026-08-04) and `auto-tag.yaml`
created the tag `v1.13.8-nvgpu5.11.1-drm-noshim`. **No image was ever
published for it.**

**4. Their automation is broken at one seam — this is the whole problem.**

```
Renovate bumps TALOS_VERSION ──► merge to main
   └─► auto-tag.yaml ✅ ran 2026-08-04, created v1.13.8-nvgpu5.11.1-drm-noshim
         └─► release.yaml ❌ NEVER RAN  ← the break
```

`release.yaml` triggers on `push: tags: ['v*']` and the tag matches. But
`auto-tag.yaml` pushes it via `actions/checkout@v7` with no `token:` override,
so the push is made with the default `GITHUB_TOKEN` — and GitHub deliberately
does not let events created by `GITHUB_TOKEN` start new workflow runs. No
Release run appears anywhere in upstream's history. Seven Talos-release tracking
issues (v1.13.2 → v1.13.8) sit open behind this.

**A plain fork reproduces the bug.** Fixing that seam _is_ Phase 2.

## Goals

- Publish Jetson installer images from an account we control, so nv1 is never
  blocked on someone else cutting a release.
- Make a Talos version bump routine: review one Renovate PR, get an image.
- Establish a documented, repeatable way to reach kernel parity with mainline
  Talos — pursued as a separate, optional track.
- Fix the same defect upstream, so the fork can converge back toward a mirror.

## Non-goals

- **Rewriting or restructuring the build.** The fork stays a near-mirror; the
  build system is upstream's and stays that way.
- **Automating the home-ops side.** Upgrading nv1 stays a deliberate act.
- **Mirroring the JetPack `.deb`s.** Still deferred; `cdi-setup` continues to
  fetch them at runtime.
- **Bumping the kernel as part of core Phase 2.** Separate track, own gate.

## Decisions

| Decision                  | Choice                              | Rationale                                                      |
| ------------------------- | ----------------------------------- | -------------------------------------------------------------- |
| Fork vs vendor            | Fork, kept a near-mirror            | Upstream CI already does everything; divergence is a liability |
| Trigger fix               | `workflow_dispatch` from `auto-tag` | No new secret, no expiry, and upstreamable — a PAT fix is not  |
| Upstream                  | Send the same patch as a PR         | If merged, divergence drops to `renovate.json` assignees       |
| Kernel currency           | Separate track, `PKGS_COMMIT` bump  | Expensive (cache invalidated) and independently revertible     |
| home-ops version tracking | Manual, deliberate                  | `provision/talos/**` is outside Renovate scope by design       |
| `talosVersion` key        | Delete; derive from the image tag   | Removes a two-place duplicate that can silently desync         |

## Architecture

### Fork topology

`mmalyska/talos-jetson-orin`, a fork of `schwankner/talos-jetson-orin`, with two
divergences and nothing else:

| File                              | Change                                |
| --------------------------------- | ------------------------------------- |
| `.github/workflows/auto-tag.yaml` | dispatch `release.yaml` after tagging |
| `renovate.json`                   | `assignees`/`reviewers` → `mmalyska`  |

Secrets on the fork:

| Secret             | Source                 | Notes                             |
| ------------------ | ---------------------- | --------------------------------- |
| `SIGNING_KEY_PEM`  | `make keys` → RSA-4096 | **Must never change** — see Risks |
| `SIGNING_KEY_X509` | same run               |                                   |
| `GITHUB_TOKEN`     | automatic              | No PAT is needed                  |

Two fork mechanics that fail silently if missed:

- GitHub **disables Actions on forks by default** — enable explicitly or nothing
  runs at all.
- **Scheduled workflows do not run on forks**, so `check-talos.yaml` stays
  dormant. Acceptable: Renovate in the fork does version tracking, and upstream's
  check has a comparison bug (`1.13.8` from `common.sh` vs `v1.13.8` from the
  API), which is their issue #36.

Published artifacts, of which home-ops consumes only the first:

```
ghcr.io/mmalyska/custom-installer:<talos>-<kernel>-nvgpu<nvgpu>   ← nv1's install.image
ghcr.io/mmalyska/kernel-modules-clang:<...>
ghcr.io/mmalyska/nvidia-tegra-nvgpu:<...>
ghcr.io/mmalyska/nvidia-firmware-ext:<...>
```

### The trigger fix

GitHub's restriction has a documented exception: events created with
`GITHUB_TOKEN` do not start workflow runs, **except `workflow_dispatch` and
`repository_dispatch`**. So `auto-tag` keeps pushing the tag exactly as it does
today, then explicitly dispatches the build:

```yaml
permissions:
  contents: write
  actions: write # + required to dispatch

# ...after: git push origin "${TAG}"
- name: Trigger release build for the new tag
  if: steps.tag.outputs.created == 'true'
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: gh workflow run release.yaml --ref "${{ steps.versions.outputs.tag }}"
```

This also requires adding a `created` output to the tag step, which today only
echoes.

**Dispatching is equivalent to a tag push here, not a degraded substitute.**
`release.yaml` uses `github.ref_name` for artifact naming and guards its GitHub
Release step with `if: startsWith(github.ref, 'refs/tags/')`. Dispatching with
`--ref <tag>` sets `github.ref` to `refs/tags/<tag>`, so the guard passes and the
run behaves identically.

Why not a PAT:

|                | PAT                                      | `workflow_dispatch` |
| -------------- | ---------------------------------------- | ------------------- |
| Extra secret   | yes                                      | **none**            |
| Silent failure | PAT expiry kills the chain quietly       | none                |
| Diff size      | 1 line                                   | ~8 lines            |
| Upstreamable   | poorly — forces every fork to mint a PAT | **cleanly**         |

### The maintenance loop

```
siderolabs releases Talos v1.13.9
  └─► Renovate (fork) → PR bumping TALOS_VERSION in scripts/common.sh
        └─► review + merge            ← the only manual step
              └─► auto-tag → v1.13.9-nvgpu5.11.1-drm-noshim
                    └─► dispatch → release.yaml on ubuntu-24.04-arm
                          └─► ghcr.io/mmalyska/custom-installer:1.13.9-<kernel>-nvgpu5.11.1-drm-noshim
```

Cost splits sharply on whether the kernel moves. `release.yaml` calls
`build-extensions.yaml` as a reusable workflow named _"Build extensions (skip if
cached)"_, and extension images are keyed by `${KERNEL_VERSION}`:

| Change                        | Extensions      | Wall clock         |
| ----------------------------- | --------------- | ------------------ |
| Talos patch, same kernel      | cached, skipped | ~30–45 min         |
| Kernel change (`PKGS_COMMIT`) | full rebuild    | hours (6h timeout) |

Upstream's `renovate.json` already encodes the right policy and is kept: Talos
**patch** updates require manual review; **minor/major** auto-updates are
disabled pending nvgpu compatibility testing.

## Consuming it in home-ops

Phase 1 expressed nv1's Talos version in two places that must agree:

```yaml
# provision/talos/nodes/nv1.yaml
image: ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim
# provision/talos/nodes.yaml
talosVersion: v1.13.0 # duplicated — can silently desync
```

The image tag already contains the Talos version, so the duplicate is deleted
and the value derived in `.taskfiles/talos/Taskfile.yaml`:

```yaml
NODE_TALOS_VERSION:
  sh: |
    v=$(yq '.machine.install.image' {{.TALOS_DIR}}/clusterconfig/home-{{.N}}.yaml \
          | sed -n 's|.*custom-installer:v\{0,1\}\([0-9.]*\)-.*|v\1|p')
    echo "${v:-{{ .TALOS_VERSION }}}"
```

Two details this encodes, both verified rather than assumed:

- **`sed -n …p` exits 0 even when nothing matches**, so a `|| echo` fallback
  never fires and would silently yield an empty version — breaking the guard
  open. The fallback must test the captured value (`${v:-…}`), not the exit code.
- **The `v` prefix is optional in the tag.** Published images use
  `custom-installer:v1.13.0-…`, but upstream's `common.sh` now holds `1.13.8`
  without the `v`, so future tags will read `custom-installer:1.13.8-…`. The
  pattern accepts both and always emits the `v` form that
  `talosctl version --short` reports.

Behaviour, confirmed against all three cases:

| `machine.install.image`                       | resolves to            |
| --------------------------------------------- | ---------------------- |
| `…/custom-installer:1.13.8-6.18.42-nvgpu…`    | `v1.13.8`              |
| `…/custom-installer:v1.13.0-6.18.24-nvgpu…`   | `v1.13.0`              |
| `factory.talos.dev/metal-installer/…:v1.13.5` | global `TALOS_VERSION` |

So mc1–mc3, on the stock factory installer, fall through to the global value and
are unaffected. This is a small cleanup of something Phase 1 built, in a file
this work already edits — not scope creep.

**Renovate deliberately does not track the installer image.**
`provision/talos/**` sits outside every manager's `fileMatch`
(`cluster/.+\.ya?ml$`), and that exclusion is what protects nv1 from a Talos bump
arriving without a matching built image. Pointing Renovate at our own ghcr
namespace would technically be safe — it only ever contains images that exist —
but it would auto-upgrade a node whose GPU depends on a hand-verified kernel.
Upgrading nv1 stays a deliberate two-line edit plus `task talos:upgrade N=nv1`.

## Kernel currency (separate, optional track)

Talos pins its pkgs build in its **Makefile**:

```
# siderolabs/talos @ v1.13.8
PKGS ?= v1.13.0-55-gf677246
#                     ^^^^^^^ pkgs commit f677246a → kernel 6.18.42
```

|                         | pkgs commit      | kernel      |
| ----------------------- | ---------------- | ----------- |
| Fork today              | `f3829f74` (Apr) | 6.18.24     |
| **Talos v1.13.8 stock** | **`f677246a`**   | **6.18.42** |
| mc1–mc3 today (v1.13.5) | —                | 6.18.36     |

The real defect is not an old kernel but a **desync**: `TALOS_VERSION` moved to
1.13.8 while `PKGS_COMMIT` stayed on an April commit. Matching them gives kernel
parity by construction.

The repeatable procedure, which is the durable answer for kernel currency:

```sh
curl -fsSL https://raw.githubusercontent.com/siderolabs/talos/<tag>/Makefile | grep '^PKGS ?='
# v1.13.0-55-gf677246  →  PKGS_COMMIT=f677246
```

Risk is moderate, not high. The OE4T sources are pinned to fixed commits
(`linux-nvgpu@d530a48d`, `linux-nv-oot@ea32e7f9` on `patches-r36.5`,
`linux-hwpm@4d8a6998`) whose comments describe them as kernel-6.18 compatible
generally, not 6.18.24 specifically. Upstream's Bug 4 concerned the 6.3/6.4 API
breaks; 6.18.24 → 6.18.42 does not reopen it. Patches may still conflict — this
is a build-and-see, not a port.

If it works and PR #4503 is merged, mc1–mc3 and nv1 land on the same Talos
version **and** the same kernel — something Phase 1 explicitly could not achieve.

## Upstreaming

Send `schwankner` the dispatch fix as a standalone PR against `auto-tag.yaml`,
stated factually: the tag is created but `release.yaml` never fires, because tag
pushes made with `GITHUB_TOKEN` do not start workflow runs, and
`workflow_dispatch` is the documented exception. The evidence is their own
`v1.13.8-nvgpu5.11.1-drm-noshim` tag with no Release run and no published image.

Mention the `check-talos.yaml` comparison bug separately rather than bundling it.

If merged, our divergence drops to `renovate.json` assignees alone. If not, we
carry ~8 lines indefinitely, which is acceptable.

## Risks

| Risk                                                                                                                    | Mitigation                                                                                                                                          |
| ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Signing key lost                                                                                                        | Bitwarden is source of truth; recovery = regenerate + full rebuild + reinstall nv1                                                                  |
| Signing key **changed**                                                                                                 | Never rotate casually — a running node rejects modules signed with a different key                                                                  |
| Actions disabled on fork by default                                                                                     | Enable explicitly; nothing runs otherwise                                                                                                           |
| **GHCR packages default to private** — nv1 pulls anonymously, so a private image fails the upgrade with no obvious clue | Set `custom-installer` (and the three supporting packages) to public, then prove it with an unauthenticated manifest fetch before touching the node |
| Scheduled workflows do not run on forks                                                                                 | Accepted — Renovate covers version tracking                                                                                                         |
| Upstream diverges; merges conflict                                                                                      | Fork kept a near-mirror; only two files differ                                                                                                      |
| First fork build fails for an unrelated reason                                                                          | Builds are free and repeatable; nv1 keeps running v1.13.0 until an image exists                                                                     |
| Kernel bump breaks the OE4T build                                                                                       | Separate track, own gate, one-line revert                                                                                                           |
| Dispatch fires twice (tag push + dispatch)                                                                              | Cannot happen — the tag push uses `GITHUB_TOKEN`, which never triggers runs                                                                         |

## Rollback

nv1 keeps running its current v1.13.0 image throughout; nothing in home-ops
changes until a fork-built image exists and has been verified. To abandon Phase 2
entirely, point `nodes/nv1.yaml` back at
`ghcr.io/schwankner/custom-installer:v1.13.0-6.18.24-nvgpu5.11.1-drm-noshim` and
`talosctl upgrade`. The fork can be deleted without touching the cluster.

## Outcome (2026-08-15)

**Phase 2 succeeded.** nv1 runs an installer image we build and publish ourselves.

**Image in use:** `ghcr.io/mmalyska/custom-installer:v1.13.8-6.18.42-nvgpu5.11.1-drm-noshim`
(publicly pullable — anonymous manifest fetch returns HTTP 200).

### Gate results — Task 5

| Gate                        | Expected                   | Measured                          | Result |
| --------------------------- | -------------------------- | --------------------------------- | ------ |
| Node returns on new version | `Ready`, Talos v1.13.8     | `Ready`, `Talos (v1.13.8)`        | PASS   |
| Kernel                      | `6.18.42-talos` (revised)  | `6.18.42-talos`                   | PASS   |
| GPU modules loaded          | nvgpu + host1x + tegra_drm | all 8 loaded                      | PASS   |
| DRM device node             | `renderD128` present       | `card0`, `renderD128`             | PASS   |
| GPU allocatable             | `nvidia.com/gpu: 1`        | `1`                               | PASS   |
| nvidia DaemonSets           | 3× Running on nv1          | 3/3 Running                       | PASS   |
| ollama                      | Running                    | Running (rescheduled after drain) | PASS   |
| Inference — eval rate       | within ~10% of 8.84 tok/s  | **8.96 tok/s** (+1.4%)            | PASS   |
| Inference — prompt eval     | within ~10% of 74.18 tok/s | **77.66 tok/s** (+4.7%)           | PASS   |
| Upgrade version guard       | resolves v1.13.8 and skips | matches, would skip               | PASS   |

Inference measured with `qwen3.5:9b --think=false`, matching how the Phase 1 GPU
baseline was recorded. The plan's Step 5 command omitted `--think=false`; run as
written it would have compared thinking-mode generation against a non-thinking
baseline and looked like a severe regression on a healthy GPU.

### What the plan did not anticipate

The design assumed upstream's build works and only its `auto-tag` → `release`
trigger is broken. In fact upstream's publish path had **never** worked
end-to-end. Five defects were found, four of them build-breaking, each hit in
sequence over five builds:

1. `setup-keys.sh` copied only the private key into `talos_signing_key.pem`,
   so `extract-cert` failed with `PEM routines::no start line`.
2. Concatenating key and cert with a plain `cat` fused the PEM blocks, because
   CI restores secrets with `printf '%s'` and no trailing newline
   (`PEM routines::bad end line`).
3. Renovate's `extractVersionTemplate` stripped the `v` from `TALOS_VERSION`,
   so `ghcr.io/siderolabs/installer:1.13.8` 404'd (only `v1.13.8` exists).
4. `PKGS_COMMIT` desynced from `TALOS_VERSION`: the imager ships kernel 6.18.42
   while the pinned pkgs commit built modules for 6.18.24, so UKI assembly
   failed. This reclassified Task 8 from an optional track to a prerequisite.
5. `check-talos.yaml` compares a prefix-stripped version against a `v`-prefixed
   tag — the same root cause as (3), cosmetic rather than build-breaking.

Defects 3 and 4 together mean upstream's Renovate configuration **cannot**
produce a working build: every automated Talos bump both strips the prefix and
desyncs the kernel pin. That explains the empty publish history more completely
than the dispatch seam alone.

### Consequences

- **Kernel parity achieved** rather than deferred. nv1 is on `6.18.42-talos`;
  once PR #4503 lands and mc1–3 upgrade, all four nodes match on Talos and
  kernel — an outcome Phase 1 could not reach and Task 8 treated as a bonus.
- **The OE4T modules compiled cleanly against 6.18.42**, so the risk flagged in
  Task 8 Step 4 did not materialise. No revert was needed.
- **Fork divergence is four files, not two**, every one a genuine upstream bug
  fix rather than a local workaround. Each should shrink to zero as PRs land.
- The signing key was rotated once during execution (the original was exposed in
  a chat transcript before anything depended on it — the cheapest possible moment
  to rotate, since no signed modules existed yet).

### Still outstanding

- **Task 3** — the `auto-tag` → `release` dispatch fix, not yet applied.
- **Task 6** — upstream PRs (dispatch fix, signing-key fix, `v`-prefix fix) plus
  issues for the `PKGS_COMMIT` design gap and `check-talos.yaml`.
- **Task 7** — Renovate on the fork. Note the plan's instruction to leave
  upstream's `packageRules` untouched is wrong: `extractVersionTemplate` must
  stay removed or every future bump reintroduces defect 3.
- **PR #4503** — Talos v1.13.8 for mc1–3, deliberately deferred so nv1's upgrade
  stayed attributable.
