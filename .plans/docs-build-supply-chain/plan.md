---
status: blocked
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 3633f41aff58b5e53f66744f52369bd8ebcf2354
branch: chore/docs-build-supply-chain
worktree: .worktrees/chore/docs-build-supply-chain
pr: not-opened
started: 2026-11-16
updated: 2026-11-16
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

## Revised T1 evidence - 2026-11-16

The conductor read `t_a17002ef` evidence comments with `kanban_show`. Quoted
results: direct `pymdown-extensions 13.0 -> 13.1`, header command exit 0,
34 packages, both artifact hashes changed; indirect `click 8.5.0 -> 8.5.1`,
`--upgrade-package=click==8.5.1`, exit 0, direct pins unchanged and both artifact
hashes changed. These are accepted as command-equivalent evidence under the
owner's H2 decision, not as proof of a real Renovate PR. Earlier Python/uv
experiments remain failed evidence under the old gate, not newly relabeled PASS.

The conductor repeated extraction in a fresh disposable local Git fixture at
`/workspaces/docs-h2-extraction`, because the previous worker fixture was not
present in Coder. Exact versions: Python 3.15.2, uv 0.13.7, Renovate 44.242.0,
Node v26.13.0. Direct pins: mkdocs 1.6.1, Material 9.8.1, revision plugin 1.7.0,
autolinks 0.7.1, pymdown-extensions 13.1.

```sh
uv pip compile --generate-hashes --python-version=3.15.2 --output-file=.github/mkdocs/requirements.txt .github/mkdocs/requirements.in
npx --yes --package=renovate@44.242.0 renovate-config-validator renovate.json
LOG_LEVEL=debug RENOVATE_BINARY_SOURCE=global npx --yes --package=renovate@44.242.0 renovate --platform=local --dry-run=extract
```

All three commands exited 0. The minimal fixture config was:

```json
{
  "pip-compile": {
    "managerFilePatterns": ["/^\\.github\\/mkdocs\\/requirements\\.txt$/"]
  },
  "pip_requirements": {"ignorePaths": [".github/mkdocs/**"]},
  "packageRules": [
    {
      "matchManagers": ["pip-compile"],
      "matchDepTypes": ["indirect"],
      "enabled": true
    }
  ]
}
```

Inputs were staged locally so Renovate's Git file listing could see them; no
fixture commit, remote writes, branches, PRs or workflow dispatch occurred.
The first attempt with untracked files exited 0 but extracted zero dependencies;
it is not passing evidence. After staging, the actual output included:

```text
Matched 1 file(s) for manager pip-compile
fileName: .github/mkdocs/requirements.txt
commandType: uv
.github/mkdocs/requirements.in --> .github/mkdocs/requirements.txt
pip-compile: fileCount=1, depCount=34
mise: fileCount=1, depCount=1
pyenv: fileCount=1, depCount=1
```

The extracted pip-compile graph contained five direct and 29 indirect entries,
including `babel`, lockedVersion `2.18.0`, depType `indirect`. No competing
pip_requirements package file was extracted. Raw extraction marks indirect entries
`enabled: false` before update-rule application; this is discovery evidence, not
proof of enabled update selection. The fixture rule opts them in. uv extraction
warned `GitHub token is required for some dependencies` and skipped its lookup;
that does not affect pip-compile discovery, and is not uv update proof. Full
production-preset validation and actual update PR generation remain for T2/T3
and T4 respectively. T1's revised local evidence is satisfied; T2 remains gated
on owner merge and explicit thread approval of this revision.

Reference: <https://docs.renovatebot.com/modules/manager/pip-compile/>.
