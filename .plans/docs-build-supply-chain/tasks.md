# Docs build supply chain tasks

## Execution contract

Repository: `mmalyska/home-ops`. All work runs in the remote Coder workspace under
`/workspaces`, in linked worktrees. Read AGENTS.md from the default branch before
work; run `.agents/bin/worktree-preflight` before editing. Never read secrets,
change cluster state, change required checks, freeze OS images, migrate themes,
merge PRs, bypass hooks or write to main. Source requirements are the
revised `.plans/docs-build-supply-chain/spec.md` after this revision merges
(original spec #6300). Exact pins and hashed locks,
shared local/CI inputs, strict builds and native Renovate regeneration are mandatory.
The owner revised the design on 2026-11-16: direct uv commands, no docs.py or its
unittest suite. H2 adds a fourth persistent invariant: lock-header target Python
equals `.github/mkdocs/.python-version`. The 2026-11-16 owner decision below
supersedes all-four native regeneration proof; use recorded command evidence for
remaining acceptance checks.

Status: T1 direct/indirect evidence accepted under the H2 revision (see
spec.md for the owner's decision); evidence recorded on kanban cards.
T2/T3 stopped pending revision merge and explicit thread approval. Prior
incomplete T2 delivery does not satisfy this plan. Reconcile existing cards
rather than recreating the graph. Human-only tasks stay with the owner. Per default-branch AGENTS.md, workers work in separate workspaces and cannot
affect each other. Workers commit and push their branch
`chore/docs-build-supply-chain`, post the commit SHA and evidence as card
comments, and open no PR. The conductor reviews the pushed branch and opens
the only implementation PR.

## H1 - HUMAN ONLY: approve the plan phase

Owner: repository owner. Original H1 is satisfied by merged #6301 and thread
approval. The active gate is now H2: merge this spec/plan/tasks revision PR and
explicitly approve it in the Discord thread. Confirmation: revision PR state
MERGED and an owner-authored approval message. No T2 card or code work is
permitted before both are verified.

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
compiled-output matching and parseable uv compile headers. Accept the recorded direct/indirect command-equivalent regeneration from
`t_a17002ef`; run local extraction with `--platform=local --dry-run=extract`.
Do not investigate Python/uv-triggered regeneration further. Compare lock headers, hashes, selected binaries and source
versions; confirm no duplicate pip_requirements updates. Read credentials only
through tool-supported authentication; never print tokens or invoke Renovate
write mode. Do not dispatch workflows. Extraction alone is not regeneration proof.

Done: return reproducible sanitized commands, exact versions, pass/fail evidence
and supported home-ops-only configuration to the conductor. Direct/indirect command and hash diffs plus extraction of requirements.txt
including indirect dependencies meet the revised pre-T2 gate. Real PR proof is
T4; automatic pyenv/mise lock regeneration is not required. If unavailable,
unsupported or dependent on external settings, stop and invoke H2; do not replace
the approved manager strategy or claim success from documentation alone.

## H2 - HUMAN ONLY, CONDITIONAL: resolve a native-tooling prerequisite

Owner: repository owner. Dependencies: a specific T1 failure report. Blocks
everything downstream of T1 if invoked: yes. No unconditional external change is
currently identified. Review the exact unsupported configuration or runner access
request. If another repository or external runner needs changing, decide scope and
use its own approved PR process; do not delegate that mutation implicitly here.
Alternatively revise the spec explicitly. Confirm the prerequisite and authorize
resumption in the spec thread. For this H2 decision, no further investigation:
the revision PR must be merged and explicitly approved before T2 starts. No credential
values belong in chat, task bodies, fixtures or evidence.

## T2 - Implement locked docs build as one atomic change

Owner: worker. Dependencies: successful T1; H2 confirmation if invoked. Branch:
`chore/docs-build-supply-chain` from updated origin/main. Files: add
`.github/mkdocs/requirements.in`, generate `.github/mkdocs/requirements.txt`, add
`.github/mkdocs/.python-version`, `.github/mkdocs/mise.toml`,
and `.github/tests/docs-workflows.sh` for the four invariants; edit
`.taskfiles/mkdocs.yml`, `.github/workflows/docs-build.yaml`,
`.github/workflows/publish-pages.yaml` and docs-scoped native Renovate config in
`.github/renovate/managers.json5` plus related local config only if necessary.
Document usage in `docs/src/contributing/docs-build.md` and add its nav entry in
`.github/mkdocs/mkdocs.yml`. Update `.gitignore` only for local docs environments.
Do not touch spec/plan status or unrelated application/workflow configuration.

Goal: exact direct source pins and complete hashed lock; direct uv commands using
shared Python/uv pins for installation, compilation, strict build and serve; all action
SHAs; native Renovate updates including transitive maintenance.

Use Python 3.15.2 as the initial compatibility candidate, selecting exact uv and
dependency pins after testing. Follow T1's demonstrated manager configuration;
do not promise automatic runtime/tool regeneration or use floating tools.
`mkdocs:lock` reads the exact target from `.python-version` and generates the
parseable header with `--python-version=<version>` (equals syntax). Keep Material
at least 9.8.1 and revision plugin at least 1.7.0, and explicitly list mkdocs and
pymdown-extensions in requirements.in.
Taskfile and workflow steps read the same runtime files without shell evaluation.
Use simple Task preconditions and explicit uv Python selection to report version
mismatches; do not create a wrapper script. Call `uv pip sync --require-hashes`
directly with the committed lock and explicit environment interpreter. Call
`uv pip compile --generate-hashes` directly for explicit lock/update operations,
using standard headers and explicit Python/input/output paths. Normal builds do
not compile. No docs.py, helper unittest suite or replacement orchestration layer.
No hidden unpinned sdist build dependencies: require wheels or return the conflict
to the owner. Cache only as an optimization, never skipping hashes or stale inputs.

Keep local build/serve task names; add `mkdocs:lock`. Setup Python
and uv in CI from the same declared versions via SHA-pinned setup actions. Both
workflows use full git history and strict builds; PR permissions stay read-only,
publish deploy remains dependent on successful build. Expand docs PR and publish
path filters for shared files. Never dispatch publication as a test. Keep OS and
required-check settings unchanged.

Commands/checks: add only `.github/tests/docs-workflows.sh`, covering full SHA
pins, strict mode in both workflows, publication deploy `needs: build`, and
header Python equality with `.github/mkdocs/.python-version`; invoke
it in PR CI. Demonstrate that each invariant check rejects a corresponding
disposable workflow or Python/header input mutation, then run it against the implementation. Do not add tests
for uv behavior, other version checking, hashes, path filters or a helper.
The fourth check fails closed for missing/malformed header or pin and mismatch.
A pyenv-only bump must fail CI until `task mkdocs:lock` is run on its branch and
the regenerated lock is committed. Document this repair procedure and that a
mise uv bump requires green locked install plus strict build, not regeneration.
Run `task mkdocs:lock` and `task mkdocs:build`; smoke-test `task mkdocs:serve` with
bounded startup, HTTP request and cleanup. Record direct CLI checks and installed
versions, rather than introducing another check task or framework. Run targeted
Prettier, markdownlint, YAML lint, actionlint, Renovate validator,
`git diff --check`, `.agents/bin/check-plans` and pre-commit including gitleaks.
Inspect advisory task output rather than relying on its exit code.

Done: worker commits and pushes the complete implementation to
`chore/docs-build-supply-chain`, posts the commit SHA and evidence as card
comments, and opens no PR. The conductor reviews the pushed branch and opens
the implementation PR. Return commit, exact pins, generated lock counts,
workflow-invariant check output, all check statuses and reproducible commands. Include docs for local bootstrap, compilation,
Renovate updates, mismatches and the non-enforced red-check limitation. New locked
strict failures go to the owner; never weaken strict mode to finish.

## T3 - Verify the complete implementation and hand off for PR

Owner: worker. Dependencies: T2. Branch: continue `chore/docs-build-supply-chain`
at the exact T2 handoff commit in a linked worktree, not main. Scope: the T2 files
only, plus fixes within that scope. No independent implementation branch or PR.

Goal: exercise acceptance criteria rather than merely inspecting configuration.
Run `bash .github/tests/docs-workflows.sh`, strict build and a bounded serve
HTTP smoke check. Keep automated tests limited to the four invariants;
record remaining acceptance exercises as one-off command evidence. Install the unchanged committed lock twice into fresh isolated
environments and compare installed versions. Corrupt/remove hashes in disposable
copies and require nonzero installs; verify declared Python/uv selection and
actionable Task precondition failures directly. Compile
unchanged inputs and require no lock diff. Introduce a missing nav page in a copy
and verify strict build fails; validate upload/deploy cannot run after that build
failure by the deploy-needs-build invariant check and direct review of upload
and deploy conditions, not an actual Pages dispatch.

Repeat T1's native manager extraction/regeneration with final paths and config
for direct/transitive updates. Verify a Python-file-only bump fails the fourth
invariant and branch-local `task mkdocs:lock` restores equality with a compatible
lock and green strict build. Verify a uv-only pin bump by locked install and
strict build, with no regeneration requirement. Record exact Renovate/compiler
versions and regenerated hashed changes where required, with no remote write. Run final targeted
format/lint, actionlint, Renovate config validation, `.agents/bin/check-plans`,
`git diff --check` and pre-commit. Do not claim unrun CI as passing.

Done: worker amends and pushes to `chore/docs-build-supply-chain`, posts the
final commit SHA and per-acceptance PASS/FAIL/NOT RUN report as card comments.
The conductor reviews the pushed branch, opens the implementation PR as
rudi-the-brain with `triage/owner`, and reports its checks. Missing revised
local acceptance evidence blocks delivery; real Renovate PR proof stays in
T4.

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
are in one PR, with the declared compiler/runtime and passing docs CI. This is
the real Renovate PR proof deferred from T1 by the owner, not an automatic
Python/uv cross-manager regeneration promise. When those bump PRs occur, Python
requires branch-local lock regeneration and header equality; uv requires only a
green locked install and strict build. Read PR
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
