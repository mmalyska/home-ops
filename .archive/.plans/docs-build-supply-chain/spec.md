# Docs build supply chain and reproducibility

## Status and scope

Spec revision for owner review. Size: big, because the requirements needed owner decisions,
the build policy outlives this change, and delivery has separate spec, plan and
implementation phases. This revision updates the spec, plan and tasks together under the owner's H2
decision. It does not authorize implementation, publication or settings changes.

The source item is "Docs build supply chain and reproducibility" in `.plans/TODO.md`.

## Problem

The docs dependency file `.github/mkdocs/requirements.txt` has no version pins.
Both `.github/workflows/docs-build.yaml` and
`.github/workflows/publish-pages.yaml` additionally install `mkdocs[i18n]` without
a pin. The publication workflow contains mutable action references and does not
build with `--strict`. The PR workflow already uses full action SHAs and strict
mode. Local `.taskfiles/mkdocs.yml` commands install only the dependency file,
so local and CI dependency sources are not currently equivalent.

## Goal and reproducibility boundary

Make docs builds use reviewed, pinned inputs that Renovate can update. A pin
update may change the generated site; byte-for-byte site identity is not required.

The boundary includes the complete Python dependency graph, exact Python version,
installation and lock-generation tooling, and full GitHub Action commit SHAs.
OS image pinning is excluded; `ubuntu-latest` may remain. This is not a claim of
an entirely hermetic build, frozen external assets or offline availability.

## Owner decisions

- Use a fully resolved dependency lock with artifact hashes, not plain direct
  dependency pins alone.
- Use a pip-compile-style source file plus generated hashed lock. Renovate updates
  dependencies and regenerates the matching lock in the same PR; a custom regex
  manager is not the chosen approach.
- CI and all local `task mkdocs:*` dependency-install paths share the same source
  and lock. Serving and building must not silently install extra unpinned packages.
- Pin Python and installation/lock-generation tooling to exact versions, with
  Renovate able to update them. Do not pin the OS image as part of this work.
- Use strict mode for PR validation and publication. Docs breakage must make the
  corresponding build fail, and a failed publication build must not deploy.
- Inspect the current baseline before deciding how to handle existing failures.
- Do not add the docs CI check to required repository checks at this time and do
  not change branch protection or rulesets. A failed PR build is a red check, not
  a GitHub-enforced prohibition on merging; this qualifies the earlier request
  to "block PR".

## Owner H2 decision - 2026-11-16

Misiek (repository owner) decided in Discord message `1571957410518667386`
to revise the strategy, with no further cross-manager trigger investigation:

- Pin target Python in the uv lock header using `--python-version=<exact version>`.
  The fourth invariant in `.github/tests/docs-workflows.sh` requires that version
  to equal `.github/mkdocs/.python-version`; missing or malformed values fail.
  A pyenv bump PR fails CI until `task mkdocs:lock` is run on its branch and the
  regenerated lock is committed. Do not assume pyenv triggers pip-compile.
- A mise uv bump requires a green locked install and strict build, not lock
  regeneration. Do not assume mise triggers pip-compile.
- Accept the direct/indirect command-equivalent evidence from `t_a17002ef`, plus
  local Renovate extraction (`--platform=local --dry-run=extract`, no remote
  writes) showing pip-compile picks up requirements.txt with indirect dependencies.
  Proof of an actual Renovate update PR remains in T4, not the pre-T2 gate.
- T2 stays stopped until the owner merges this spec/plan/tasks revision PR and
  explicitly approves it in the Discord thread. This decision is not that approval.

## Requirements

1. Commit a dependency source with explicit direct pins and a generated lock that
   resolves the complete docs dependency graph with exact versions and hashes.
   Include MkDocs itself and every required theme, plugin and extension through
   this shared dependency definition; remove independent unpinned installs.
2. Install the committed lock with hash verification in both workflows and local
   MkDocs tasks. Normal builds consume the lock rather than resolving a fresh
   dependency graph. An absent or mismatched artifact hash must fail installation.
3. Pin and document the Python and tooling versions needed to install and
   regenerate the lock. Local commands use the same declared versions as CI or
   report an actionable incompatibility rather than silently using another set.
4. Support Renovate updates of direct pins, transitive lock dependencies, Python,
   tooling and action SHAs. Dependency updates and their regenerated lock must
   remain consistent in the same PR. Python updates require explicit branch-local
   lock regeneration and header/version-file equality enforced in CI. uv updates
   require locked installation and strict build, not regeneration. Verify local
   direct/indirect reproduction and extraction before T2; observe a real PR in T4.
5. Pin every action in the publication workflow to a full commit SHA, retaining
   readable version comments. Preserve the PR workflow's existing SHA pinning.
6. Run both validation and publication builds with `--strict` and equivalent
   dependency inputs. Supply git history where the revision-date plugin needs it
   so checkout differences do not create publication-only strict failures.
7. Trigger PR validation for changes to all relevant docs build inputs, including
   publication workflow, dependency/runtime/tooling definitions and local tasks.
   Preserve the build-only, read-only PR workflow and publish only on the existing
   authorized publication path.
8. Document local installation/build/serve and lock regeneration. Add regression
   coverage through four maintained invariants: full action SHAs, strict build
   mode, publication deploy needs build, and lock-header Python equals the version
   file. Other acceptance properties use bounded recorded command exercises.

## Baseline evidence

On 2026-11-16, the unmodified default-branch revision
`957ddeba56f1142cb97ddcfcc013372f68a30071` was checked in a linked worktree
with full git history on the remote Coder workspace.

- Python: CPython 3.15.2 on Linux.
- An isolated virtual environment installed `mkdocs[i18n]` and the current
  `.github/mkdocs/requirements.txt` together using `uv pip install`.
  This checks the current dependency inputs, not the future lock or an exact
  reproduction of GitHub's pip installer environment.
- Resolved packages included MkDocs 1.6.1, Material 9.8.1,
  git-revision-date-localized plugin 1.7.0 and autolinks plugin 0.7.1.
- `mkdocs build --strict --config-file .github/mkdocs/mkdocs.yml` with an external
  site output directory exited 0 and built the documentation in 2.00 seconds.
- There were no MkDocs build warnings or errors. Six audit pages outside the nav
  were reported at INFO level. Material printed an end-of-life notice that did
  not cause strict mode to fail.

No existing strict-build failure needs an exception decision on this baseline.
Recheck after selecting the initial lock; a future failure must be reported to
and resolved with the owner, not hidden by weakening strict mode. This baseline
is evidence, not a selection of the final dependency pins.

## Acceptance criteria

- Clean installations in CI and local tasks consume the same complete hashed
  dependency lock and declared Python/tooling pins without extra unpinned installs.
- Repeated installation of unchanged inputs selects the same locked package
  versions; a hash mismatch fails rather than falling back to an unlocked install.
- Direct/indirect source-derived reproduction and local pip-compile extraction
  satisfy T1; an actual consistent Renovate dependency update PR is observed in T4.
- A Python-file-only bump fails CI; branch-local `task mkdocs:lock` restores header
  equality and a compatible hashed lock. A uv bump passes locked install and strict
  build without a lock-regeneration requirement.
- Both workflows use full action SHAs and strict builds. A deliberately introduced
  strict-build warning or error fails PR validation and prevents publication.
- The initial locked strict build passes, or any new incompatibility is brought
  back to the owner before proceeding. Existing warnings are not silently waived.
- Local build and serve commands work with the shared dependency definition, and
  the update/regeneration procedure is documented and exercised.
- Repository required-check settings and OS image selection remain unchanged.

## Non-goals

- Byte-identical generated HTML, frozen OS images, offline builds or vendoring all
  externally hosted site assets.
- A theme migration prompted by the Material end-of-life notice.
- Deployment, cluster mutation, changes to repository protection settings, or
  automatic approval or merging of spec, plan or implementation PRs.

## Open questions and phase gates

The H2 decision above supersedes any requirement for automatic Python/uv-triggered
lock regeneration or all-four native update proof before T2. No further trigger
investigation is authorized. No unresolved owner policy decision remains. Exact
file layout, initial versions, tooling bootstrap and native Renovate configuration
are plan-phase design work subject to the requirements above. If that work exposes
a conflict or unsupported update path, return to the owner instead of substituting
another dependency-management approach.

This revision must be merged and explicitly approved in the Discord thread before
T2 resumes. The original phase gates remain: planning begins only after the owner
approves the spec in the Discord spec thread
and this spec PR is merged. Implementation begins only after the separate plan is
approved in that thread and its PR is merged. The owner merges these PRs.
