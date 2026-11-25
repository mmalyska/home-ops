---
status: shipped
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 3633f41aff58b5e53f66744f52369bd8ebcf2354
branch: chore/docs-build-supply-chain
worktree: .worktrees/chore/docs-build-supply-chain
pr: "#6300, #6301, #6315, #6339"
started: 2026-11-16
updated: 2026-11-25
---

# Docs build supply chain implementation plan

## Authority and current state

The owner approved the merged spec PR #6300 in the Discord spec thread on
2026-11-16 and subsequently approved plan PR #6301. [spec.md](spec.md) is the
requirements authority. Execution is now stopped pending merge and explicit thread
approval of this H2 spec/plan/tasks revision; no T2 work is authorized.

The default-branch baseline strict build passed on Python 3.15.2 with the current
unlocked dependency inputs. That is not evidence that a future lock or Renovate
regeneration works. This PR revises the spec explicitly at the owner's request.

## Owner H2 decision - 2026-11-16

The owner revised the strategy on 2026-11-16; the full decision text is in
[spec.md](spec.md#owner-h2-decision---2026-11-16).

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
with `--generate-hashes`, `--python-version=<exact version>`, explicit input/output
paths and no private index URL. The target comes from `.python-version`;
`task mkdocs:lock` writes it into the header and regenerates the hashed lock.
Normal installs use `uv pip sync --require-hashes` into a dedicated virtualenv;
never compile or resolve an unlocked graph as part of normal build or serve.

Keep the exact Python patch version in `.github/mkdocs/.python-version`, detected
by the native pyenv manager. Keep the exact uv version in a docs-only
`.github/mkdocs/mise.toml`, detected by the native mise manager. Do not change the
workspace-wide runtime or require installing mise for docs. Start from the passing
Python 3.15.2 baseline; select and record uv and dependency versions only after
compatibility verification. Read the version files directly in Task variables and
workflow setup steps without shell evaluation of configuration. Use native Task
preconditions and explicit uv Python selection for actionable version mismatches;
do not introduce a Python wrapper or a replacement orchestration script.

CI uses SHA-pinned setup-python and setup-uv actions, reading Python from its
version file and uv from the docs mise file. The initial uv executable is
bootstrapped by the pinned action in CI or the user's existing version manager
locally; no unversioned curl installer is added.

### CI and local commands

The Taskfile and both workflows invoke `uv pip sync --require-hashes` directly
against the same committed requirements.txt and explicit virtualenv interpreter.
Lock regeneration invokes `uv pip compile --generate-hashes` directly against the
same requirements.in with explicit Python and output paths. Normal build/serve
runs only synchronize the committed lock; compilation is an explicit lock/update
operation, not fresh resolution during a build. Workflow regeneration/check steps,
where needed, use the same direct compile command, not a helper.

Preserve `task mkdocs:build` and `task mkdocs:serve`; add `task mkdocs:lock` for
explicit compilation. Keep the old internal prerequisites task compatible or
update all callers. Run the environment's MkDocs executable directly, with strict
mode for build and an explicit output path. No docs.py, helper unittest suite or
custom mkdocs:check orchestration layer is planned. Recreate or synchronize stale
environments after pin updates; Task caching must not skip changed inputs. Keep
caches limited to downloads keyed by runtime/tool/lock inputs, never as a
substitute for hashed synchronization.

Both workflows use full history and disable persisted checkout credentials.
Pin all publication actions, preserve read-only PR permissions, existing Pages
concurrency/environment and deploy `needs: build`. Never use `always()` or ignored
build failures to permit upload/deploy after a failed strict build. Add workflow
path filters for publication workflow, docs tasks, workflow-invariant tests, locks and version
files; publication also reacts to changed shared build inputs. Keep publication
on main or its existing manual path, not on PRs.

### Renovate integration and feasibility gate

Configure `pip-compile.managerFilePatterns` for the compiled requirements.txt,
not requirements.in. Exclude only these docs files from competing
`pip_requirements` extraction; do not disable unrelated dependency management.
Enable docs-scoped indirect updates/lock maintenance explicitly because indirect
updates are disabled by default. Validate extraction of the Python and uv files
using their native managers. Dependency changes regenerate the matching lock.
Python-file updates require branch-local `task mkdocs:lock`; CI rejects header
version drift. uv updates require only locked install and strict build.

T1 accepts the direct/indirect source-derived command and hash diffs recorded on
`t_a17002ef`, plus the local extraction evidence below. No further investigation
of pyenv/mise cross-manager triggers is required or authorized. Native automatic
Python/uv lock regeneration is not promised. The real Renovate PR is observed in
T4; do not dispatch write-mode Renovate, add arbitrary post-upgrade commands,
replace the manager or edit another repository.

Reference: <https://docs.renovatebot.com/modules/manager/pip-compile/>. The manager
requires explicit output-file matching and a recognizable compile-command header;
it supports uv compilation, lock maintenance and opt-in indirect updates. Its
actual deployed version must be checked during T1.

## Delivery and task ordering

1. H1 was satisfied by #6301. The active H2 revision gate now requires the owner
   to merge this revision and approve it in the thread before T2.
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

Per the owner's 2026-11-16 H2 revision, persistent tests cover four invariants:
full action SHAs, strict build mode in both workflows, publication deploy
`needs: build`, and exact header Python equality with `.python-version`. Put these focused checks in
`.github/tests/docs-workflows.sh` and run them in PR CI. Do not add docs.py, its
unittest suite, or automated tests for the uv CLI, other version checks, hash enforcement,
path filters or other workflow properties. Review those properties directly.
This revises spec regression coverage without weakening locked-input or
fail-closed build requirements.

Retain bounded acceptance exercises as recorded command evidence, not a maintained
test framework: fresh hashed installs twice with equal installed versions, missing
and corrupt hash rejection, runtime/tool selection, actual strict build and HTTP
serve smoke check, unchanged-input compilation without lock drift, and a controlled
dependency update with a consistent hashed lock. Never commit disposable broken
copies or publish their artifacts. A missing nav entry in a disposable copy must
fail strict build; inspect normal upload/deploy conditions without dispatching Pages.

Run real native Renovate extraction and local artifact regeneration on controlled
fixtures using Renovate 44.242.0. Direct/indirect evidence plus extraction meet
T1; a Python mismatch fails until explicit regeneration, and a uv bump requires
locked install plus strict build only. Record sanitized commands and versions.
Real PR proof remains in T4;
never print tokens, run write-mode Renovate or invent an updated lock.

For this plan PR run diff whitespace, targeted Prettier and markdownlint,
`.agents/bin/check-plans`, and pre-commit across all files including gitleaks.
Implementation adds only focused workflow-invariant tests, recorded build/serve
acceptance exercises, actionlint,
YAML lint and Renovate config validation. Report PASS, FAIL or NOT RUN with reasons.

## Risks, rollback and completion

Python 3.15/tool compatibility and failed locked installs or strict builds can block
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
