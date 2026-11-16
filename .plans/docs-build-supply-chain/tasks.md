# Docs build supply chain tasks

## Execution contract

Repository: `mmalyska/home-ops`. All work runs in the remote Coder workspace under
`/workspaces`, in linked worktrees. Read AGENTS.md from the default branch before
work; run `.agents/bin/worktree-preflight` before editing. Never read secrets,
change cluster state, change required checks, freeze OS images, migrate themes,
merge PRs, bypass hooks or write to main. Source requirements are the merged
`.plans/docs-build-supply-chain/spec.md` from #6300. Exact pins and hashed locks,
shared local/CI inputs, strict builds and native Renovate regeneration are mandatory.

These are future tasks, not cards created by the plan PR. Status: all pending.
Post all human-only tasks when execution is approved, marking conditional tasks
as conditional; do not assign them to workers. Workers push branches and return
handoffs, never open PRs. The conductor reviews and opens implementation PRs.

## H1 - HUMAN ONLY: approve the plan phase

Owner: repository owner. Dependencies: this plan PR exists. Blocks everything: yes.
Review and merge the plan PR, then explicitly approve the merged plan in the
Discord spec thread. Confirmation: PR state MERGED and an owner-authored approval
message. No code work or worker card is permitted before both are verified.

## T1 - Establish native Renovate feasibility

Owner: worker. Dependencies: H1. Branch: `chore/docs-build-supply-chain-feasibility`
from updated origin/main. Read scope: `.github/renovate.json5`,
`.github/renovate/*.json5`, `.github/workflows/scheduled-renovate.yaml`,
`.github/mkdocs/**`, `.taskfiles/mkdocs.yml`; public referenced Renovate presets,
reusable runner workflow and deployed Renovate manager source/documentation.
Do not edit other repositories. Only write disposable fixtures and a sanitized
handoff under `/workspaces`; no production edits or commits needed for this task.

Goal: prove the native pip-compile manager can compile uv-generated hashed outputs
using the exact declared Python/uv versions and keep source/lock consistent for
updates. Native pyenv and mise managers must extract docs runtime/tool pins.

Commands/checks: inspect the runner/action's actual Renovate version, run that
version's config validator and extraction dry-run against controlled fixture
requirements.in/requirements.txt, `.python-version` and mise.toml. Configure
compiled-output matching and parseable uv compile headers. Run local native
artifact regeneration for a controlled direct update, an indirect update and
Python/uv pin updates. Compare lock headers, hashes, selected binaries and source
versions; confirm no duplicate pip_requirements updates. Read credentials only
through tool-supported authentication; never print tokens or invoke Renovate
write mode. Do not dispatch workflows. Extraction alone is not regeneration proof.

Done: return reproducible sanitized commands, exact versions, pass/fail evidence
and supported home-ops-only configuration to the conductor. All four update types
must have a demonstrated path using the declared binaries. If unavailable,
unsupported or dependent on external settings, stop and invoke H2; do not replace
the approved manager strategy or claim success from documentation alone.

## H2 - HUMAN ONLY, CONDITIONAL: resolve a native-tooling prerequisite

Owner: repository owner. Dependencies: a specific T1 failure report. Blocks
everything downstream of T1 if invoked: yes. No unconditional external change is
currently identified. Review the exact unsupported configuration or runner access
request. If another repository or external runner needs changing, decide scope and
use its own approved PR process; do not delegate that mutation implicitly here.
Alternatively revise the spec explicitly. Confirm the prerequisite and authorize
resumption in the spec thread; T1 must recheck it before T2 starts. No credential
values belong in chat, task bodies, fixtures or evidence.

## T2 - Implement locked docs build as one atomic change

Owner: worker. Dependencies: successful T1; H2 confirmation if invoked. Branch:
`chore/docs-build-supply-chain` from updated origin/main. Files: add
`.github/mkdocs/requirements.in`, generate `.github/mkdocs/requirements.txt`, add
`.github/mkdocs/.python-version`, `.github/mkdocs/mise.toml`,
`.github/mkdocs/docs.py` and `.github/mkdocs/tests/`; edit
`.taskfiles/mkdocs.yml`, `.github/workflows/docs-build.yaml`,
`.github/workflows/publish-pages.yaml` and docs-scoped native Renovate config in
`.github/renovate/managers.json5` plus related local config only if necessary.
Document usage in `docs/src/contributing/docs-build.md` and add its nav entry in
`.github/mkdocs/mkdocs.yml`. Update `.gitignore` only for local docs environments.
Do not touch spec/plan status or unrelated application/workflow configuration.

Goal: exact direct source pins and complete hashed lock; shared version-checked
uv/Python installation, compilation, strict build and serve paths; all action
SHAs; native Renovate updates including transitive maintenance.

Use Python 3.15.2 as the initial compatibility candidate, selecting exact uv and
dependency pins after testing. Follow T1's demonstrated manager configuration;
stop on unsupported runtime/tool regeneration instead of using floating tools.
The helper reads runtime files without shell evaluation, rejects mismatched tools,
syncs a dedicated environment with `uv pip sync --require-hashes`, and compiles
only on explicit lock operations using `uv pip compile --generate-hashes` with
standard headers and explicit input/output. No hidden unpinned sdist build
dependencies: require wheels or return the conflict to the owner. Cache only as
an optimization, never skipping hash checks or stale lock changes.

Keep local build/serve task names; add `mkdocs:lock` and `mkdocs:check`. Setup Python
and uv in CI from the same declared versions via SHA-pinned setup actions. Both
workflows use full git history and strict builds; PR permissions stay read-only,
publish deploy remains dependent on successful build. Expand docs PR and publish
path filters for shared files. Never dispatch publication as a test. Keep OS and
required-check settings unchanged.

Commands/checks: write failing standard-library tests first and record RED, then
implement and record GREEN using
`python3 -m unittest discover -s .github/mkdocs/tests -v`. Cover exact version
checks, lock synchronization, hash failures and workflow invariants. Run
`task mkdocs:lock`, `task mkdocs:check`, `task mkdocs:build`; smoke-test
`task mkdocs:serve` with bounded startup, HTTP request and cleanup. Run targeted
Prettier, markdownlint, YAML lint, actionlint, Renovate validator,
`git diff --check`, `.agents/bin/check-plans` and pre-commit including gitleaks.
Inspect advisory task output rather than relying on its exit code.

Done: tested implementation pushed to the named branch, no PR opened. Return
commit, exact pins, generated lock counts, RED/GREEN output, all check statuses
and reproducible commands. Include docs for local bootstrap, compilation,
Renovate updates, mismatches and the non-enforced red-check limitation. New locked
strict failures go to the owner; never weaken strict mode to finish.

## T3 - Verify the complete implementation and hand off for PR

Owner: worker. Dependencies: T2. Branch: continue `chore/docs-build-supply-chain`
at the exact T2 handoff commit in a linked worktree, not main. Scope: the T2 files
only, plus fixes within that scope. No independent implementation branch or PR.

Goal: exercise acceptance criteria rather than merely inspecting configuration.
Run standard-library tests, `task mkdocs:check`, strict build and bounded serve
HTTP smoke check. Install the unchanged committed lock twice into fresh isolated
environments and compare installed versions. Corrupt/remove hashes in disposable
copies and require nonzero installs; test Python/uv mismatches similarly. Compile
unchanged inputs and require no lock diff. Introduce a missing nav page in a copy
and verify strict build fails; validate upload/deploy cannot run after that build
failure using workflow dependency tests, not an actual Pages dispatch.

Repeat T1's native manager extraction/regeneration with final paths and config
for direct, transitive, Python and uv updates. Record exact Renovate/compiler
versions and regenerated hashed changes with no remote write. Run final targeted
format/lint, actionlint, Renovate config validation, `.agents/bin/check-plans`,
`git diff --check` and pre-commit. Do not claim unrun CI as passing.

Done: push any scoped corrections, return the tested commit and per-acceptance
PASS/FAIL/NOT RUN report, sanitized commands and remaining risks. The conductor
must review the final diff and evidence, open one implementation PR as
rudi-the-brain with `triage/owner`, and report its checks. Missing native update
proof blocks delivery, not permission to fake results. Worker does not open PRs.

## H3 - HUMAN ONLY: review and merge the implementation

Owner: repository owner. Dependencies: T3 and conductor-opened implementation PR.
Blocks post-merge verification only: yes; does not block local implementation.
Review the atomic source/lock, runtime/tool pins, native Renovate evidence and CI.
Merge only when satisfied. Effect: changing docs build inputs may start normal
GitHub Pages publication; Renovate configuration edits may start the existing
Renovate workflow. Confirmation: implementation PR is MERGED with its commit.
No agent may approve or merge this PR or a revert PR.

## T4 - Observe publication and a real Renovate update read-only

Owner: worker. Dependencies: H3. Branch: none, read-only default-branch/API work.
Files/read scope: merged docs inputs and relevant Actions runs, Pages build/deploy
status, Renovate logs and update PR diffs. No workflow dispatch, merge, external
configuration edit, secret read or cluster change.

Use `gh run list --repo mmalyska/home-ops` and `gh run view` to identify normal
post-merge runs at the merged SHA. Verify strict build, successful upload and
Pages deployment; inspect only sanitized build logs. Observe the next ordinary
Renovate run/update and verify changed source pins and regenerated hashed lock
are in one PR, with the declared compiler/runtime and passing docs CI. Read PR
files with `gh pr diff` and check statuses with `gh pr checks`. Do not approve or
merge an update as part of this task. Use a bounded observation, not a perpetual
polling loop; if no eligible update exists yet, report pending evidence and leave
completion open rather than manufacture an update.

Done: report run URLs/SHAs and actual update PR URL plus consistency evidence, or
mark the unobserved portion NOT RUN/pending with reason. Conductor retains final
sign-off and keeps the plan open until acceptance evidence exists. Invoke H4 only
for a specific failure or genuinely necessary manual action.

## H4 - HUMAN ONLY, CONDITIONAL: manual recovery or external action

Owner: repository owner. Dependencies: T4 failure or evidence that a manual run is
necessary. Blocks closure if invoked: yes, not initial implementation. Decide and
perform any manual workflow dispatch, external runner change or merge of an
owner-reviewed rollback PR. Review impact before acting; this task is not blanket
authorization and contains no executable mutation command. Confirm the action
and run/PR reference in the spec thread, then allow read-only re-verification.
Required checks, OS pinning and cluster changes remain excluded unless separately
specified and approved.
