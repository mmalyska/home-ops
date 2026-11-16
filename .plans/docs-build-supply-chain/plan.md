---
status: draft
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 6e641cd1139e3883a33799894fbc54eda4a901ad
branch: docs/docs-build-supply-chain-plan
worktree: .worktrees/docs/docs-build-supply-chain-plan
pr: not-opened
started: 2026-11-16
updated: 2026-11-16
---

# Docs build supply chain implementation plan

## Authority and current state

The owner approved the merged spec PR #6300 in the Discord spec thread on
2026-11-16. [spec.md](spec.md) is the requirements authority. This plan is a draft
for review, not approval to implement. No worker cards are created in this phase.

The default-branch baseline strict build passed on Python 3.15.2 with the current
unlocked dependency inputs. That is not evidence that a future lock or Renovate
regeneration works. Keep the spec unchanged in this PR.

## Requirements and limits

- Fully resolved, hashed dependency locks with exact direct pins, consumed by
  both CI workflows and every local MkDocs installation path.
- Exact Python and installation/compilation tooling pins, all Renovate-managed;
  action references use full SHAs and readable version comments.
- Native pip-compile-style source/lock updates in one Renovate PR, including a
  supported transitive-update path. No custom regex-manager replacement.
- Strict PR and publication builds, full git history, safe publication dependency
  ordering and validation triggers for every relevant input.
- Keep OS selection and required-check settings unchanged. A red check is not an
  enforced merge block. No theme migration, cluster work or manual deployment.

## Proposed design

### Dependency and runtime files

Use `.github/mkdocs/requirements.in` for exact direct dependencies and keep
`.github/mkdocs/requirements.txt` as the generated hashed lock. Include MkDocs,
theme and plugins explicitly; include directly configured extensions as direct
requirements rather than relying on incidental transitive availability.

Use the native Renovate `pip-compile` manager with `uv pip compile`, which the
manager documentation explicitly supports. Generate the standard command header
with `--generate-hashes`, explicit input/output paths and no private index URL.
Normal installs use `uv pip sync --require-hashes` into a dedicated virtualenv;
never compile or resolve an unlocked graph as part of normal build or serve.

Keep the exact Python patch version in `.github/mkdocs/.python-version`, detected
by the native pyenv manager. Keep the exact uv version in a docs-only
`.github/mkdocs/mise.toml`, detected by the native mise manager. Do not change the
workspace-wide runtime or require installing mise for docs. A shared helper reads
these files, verifies Python and uv versions, and emits actionable errors if the
local tools do not match. Start from the passing Python 3.15.2 baseline; select
and record the uv and dependency versions only after compatibility verification.

CI uses SHA-pinned setup-python and setup-uv actions. Read Python from its version
file and uv from the docs mise file using a narrow, validated version reader, not
shell evaluation of configuration. The helper verifies the tools after setup.
The initial uv executable is bootstrapped by the pinned action in CI or the
user's existing version manager locally; no unversioned curl installer is added.

Place the shared helper at `.github/mkdocs/docs.py`. It provides install, build,
serve, compile and check operations. Use only the standard library for version
reading/bootstrap checks, so running the helper requires no unlocked helper
packages. Handle stale environments after a pin update by recreating or syncing
them; a Task up-to-date cache must not skip changed lock/runtime inputs.

### CI and local commands

Have `.taskfiles/mkdocs.yml` and both workflows call the shared helper. Preserve
`task mkdocs:build` and `task mkdocs:serve`; add `task mkdocs:lock` and
`task mkdocs:check`. Keep the old internal prerequisites task compatible or update
all callers. Build uses strict mode and an explicit output path; serving uses the
same environment. Keep caches limited to downloads, keyed by runtime/tool/lock
inputs, never as a substitute for hashed synchronization.

Both workflows use full history and disable persisted checkout credentials.
Pin all publication actions, preserve read-only PR permissions, existing Pages
concurrency/environment and deploy `needs: build`. Never use `always()` or ignored
build failures to permit upload/deploy after a failed strict build. Add workflow
path filters for publication workflow, docs tasks, helper/tests, locks and version
files; publication also reacts to changed shared build inputs. Keep publication
on main or its existing manual path, not on PRs.

### Renovate integration and feasibility gate

Configure `pip-compile.managerFilePatterns` for the compiled requirements.txt,
not requirements.in. Exclude only these docs files from competing
`pip_requirements` extraction; do not disable unrelated dependency management.
Enable docs-scoped indirect updates/lock maintenance explicitly because indirect
updates are disabled by default. Validate extraction of the Python and uv files
using their native managers. Pin changes must regenerate compatible locks in the
same PR, including runtime/tool changes that affect compilation.

The current scheduled job calls a reusable workflow in github-workflows, which
runs renovatebot/github-action. No inspected repository config supplies explicit
Python/uv binary constraints. Matching the runtime/tool pins inside Renovate and
regenerating on their updates is therefore a feasibility gate, not an assumption.
T1 must inspect the installed Renovate version's supported configuration and
exercise it without remote writes. If native manager constraints, binary setup or
cross-manager lock regeneration cannot meet this contract using home-ops changes,
stop and return to the owner. Do not silently use floating Renovate tooling,
post-upgrade arbitrary commands, a regex manager or cross-repository edits.

Reference: <https://docs.renovatebot.com/modules/manager/pip-compile/>. The manager
requires explicit output-file matching and a recognizable compile-command header;
it supports uv compilation, lock maintenance and opt-in indirect updates. Its
actual deployed version must be checked during T1.

## Delivery and task ordering

1. H1: owner approves and merges this plan, then approves the merged plan in the
   spec thread. This blocks all execution.
2. T1: worker performs a bounded native-Renovate feasibility check and hands back
   reproducible evidence. No production source edits or external mutations.
3. T2: worker builds the complete atomic implementation on one feature branch,
   including tests, documentation and Renovate configuration. Depends on T1.
4. T3: worker runs acceptance verification and hands back the tested feature
   branch. Depends on T2; conductor reviews evidence and opens one implementation
   PR. Workers never open PRs or merge.
5. H2 is conditional owner intervention for unsupported native tooling or an
   external runner prerequisite. It blocks downstream implementation if invoked.
6. H3: owner reviews and merges the implementation PR. Merge can trigger Pages
   publication and the existing Renovate schedule/config-change workflow.
7. T4: read-only post-merge verification of Pages and the first real native
   Renovate update. Report incomplete evidence honestly; no manual job dispatch.
8. H4: owner decides any required manual dispatch, external change or rollback
   merge if the normal publication/update path fails. Conditional only.

Human tasks are fully specified in [tasks.md](tasks.md). No cluster or repository
protection change is needed. H1 is already satisfied only when both phase gates
are verified; H2/H4 must not be treated as unconditional work or permission.

## Validation and acceptance evidence

TDD for helper/contract behavior: first demonstrate failing tests, then implement.
Use standard-library tests under `.github/mkdocs/tests/` because no existing
`test_docs_page` file was located in this checkout. Wire them into PR CI rather
than claiming an absent suite covers the change.

Require fresh hashed installs twice with equal installed versions; reject missing
and corrupt hashes; reject Python/uv mismatches; exercise build and bounded HTTP
serve smoke test; compile unchanged inputs without lock drift; and prove that a
controlled dependency update regenerates a consistent hashed lock. Never commit
the intentionally broken test copy or publish its artifact.

Static workflow tests must enforce strict mode, full SHAs, full history, read-only
PR permissions, complete path filters, shared install source and no deployment
bypass. A synthetic broken nav/config fixture must cause a nonzero strict build;
combine that with build/upload/deploy dependency tests to verify fail-closed
publication without actually dispatching Pages.

Run real native Renovate extraction and local artifact regeneration on controlled
fixtures using the actual configured version. Cover direct, indirect, runtime and
tool updates separately; record sanitized commands, versions and output. A config
validator alone or extraction-only dry run is insufficient. If authenticated full
dry-run needs access not available, report the limitation and request owner help;
never print tokens, run write-mode Renovate or invent an updated lock.

For this plan PR run diff whitespace, targeted Prettier and markdownlint,
`.agents/bin/check-plans`, and pre-commit across all files including gitleaks.
Implementation adds Python tests, actual installs/build/serve checks, actionlint,
YAML lint and Renovate config validation. Report PASS, FAIL or NOT RUN with reasons.

## Risks, rollback and completion

Python 3.15/tool compatibility and native manager runtime selection can block
implementation. Hashing source archives does not automatically lock build-time
isolation dependencies: prefer wheels and fail closed on missing wheels, or bring
an explicit hashed build-dependency design back to the owner. Do not claim a
complete lock while pip/uv installs unpinned build dependencies behind it.

No byte-identical HTML, OS freeze or offline asset guarantee is added. A Material
migration remains out of scope. If locked strict mode fails, report to the owner
rather than adding warning suppressions or disabling strict mode.

Rollback is an owner-reviewed revert PR restoring the last working docs inputs;
only the owner merges it. No agent dispatches a deployment or bypasses hashes to
recover publication. Completion requires local/CI evidence, an owner-merged
implementation, successful normal Pages publication, and a real consistent native
Renovate update observed read-only. Until then, leave missing evidence explicit
and the plan open; archive only through a separate owner-merged documentation PR.
