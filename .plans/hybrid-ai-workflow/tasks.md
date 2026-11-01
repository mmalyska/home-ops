# Hybrid AI workflow adaptation: tasks

<!-- markdownlint-disable MD013 -->

Design and rationale: [plan.md](plan.md). Evidence: [evidence.md](evidence.md). Every task below is executable without reading them, using the context in this section.

## Context every executor needs

- Base commit of the audit: `6c76fea1a4409d9ea9643d46c3b7f06cfe611a8b`. Re-check `origin/main` before starting a PR; if it moved, rebase and re-verify the paths a task names.
- The workflow itself (lifecycle Spec → Plan → Build → Test → Review → Simplify → Ship, QUICK/STANDARD/DEEP, SOLO/HANDOFF/PARALLEL/REVIEW, default STANDARD + SOLO) belongs to `mmalyska/claude-plugins`, tag `ai-workflow-v0.1.0-preview.1`, commit `25d785abee26ca7a3c87e8311f46e8a90f225301`. Do not copy it into this repository. Refer to it by name.
- Work only in a linked worktree: `git worktree add .worktrees/<type>/<slug> -b <type>/<slug> origin/main`, with `type` one of `feat`, `fix`, `chore`, `docs`. Never write in the primary checkout. Never commit to `main`. Never use `--no-verify`.
- Do not run, in any task, a command that changes cluster or external state: no `kubectl apply/create/delete/patch/annotate/scale/exec` (except allowlisted read-only `exec`), no ArgoCD sync or refresh, no `talosctl apply-config/upgrade/reset/reboot/shutdown`, no `terraform apply`, no Bitwarden secret change, no `gh pr merge`, no `gh workflow run`. Read-only checks (`kubectl get/describe/logs`, `argocd app get/list/diff`, `talosctl get`) are allowed. Pushing a branch and opening a PR need an explicit instruction from the owner, or must plainly be part of the task you were given (D4: no general authorization). Merging is done by the owner, or by an agent only after unambiguous consent naming that PR (D8).
- Secrets: never write secret values, tokens, the private domain, Bitwarden identifiers or node credentials into any file, prompt, log, test fixture or PR text. Use names and references. Run `pre-commit run --all-files` (includes gitleaks) before every commit.
- Commit messages: conventional (`docs(agents): ...`), no AI attribution lines, no session links (hook and CI enforce this).
- Validation commands available in the devcontainer: `git diff --check`, `yamllint -c .github/linters/.yamllint.yaml <files>`, `prettier --ignore-path .github/linters/.prettierignore --config .github/linters/.prettierrc.yaml --check <files>`, `shellcheck`, `jq`, `yq`, `helm`, `kubectl kustomize`, `gitleaks` via `pre-commit`. `markdownlint` is not installed locally; CI runs it with `.github/linters/.markdownlint.yaml` (line length 240). `task lint:*` always exits 0, so read its output, do not rely on the exit code.
- Report each check as PASS, FAIL, NOT RUN (with the reason) or N/A. Never report an unrun check as PASS.
- After each PR: update the table row in `plan.md` section 14 and the `updated` date in its front matter.

## PR-0: plan and evidence (this change)

### T0.1 Audit the repository at the base commit

- **Scope:** read-only; writes `.plans/hybrid-ai-workflow/evidence.md`.
- **Depends on:** none.
- **Tests:** every cited path exists at the base commit (`git cat-file -e 6c76fea1:<path>`).
- **Expected result:** evidence file with the base SHA, the pinned contract verification, findings and a NOT RUN list.
- **Acceptance:** all claims carry a path or command; unverified items are listed as NOT RUN.
- **Rollback:** delete the file.
- **Mutation consent:** none.
- **Status:** done 2026-11-01.

### T0.2 Write the plan and the task list

- **Scope:** `.plans/hybrid-ai-workflow/plan.md`, `.plans/hybrid-ai-workflow/tasks.md`.
- **Depends on:** T0.1.
- **Tests:** each task below has scope, dependencies, tests, expected result, acceptance, rollback and consent; links resolve.
- **Expected result:** self-contained plan and tasks.
- **Acceptance:** plan.md sections 1 to 19 present; no copy of the workflow definitions; no secret or private domain.
- **Rollback:** delete the files.
- **Mutation consent:** none.
- **Status:** done 2026-11-01.

### T0.3 Register the plan in the active index

- **Scope:** `.plans/list.md` (one row in the existing four-column table; prettier realigns the empty header).
- **Depends on:** T0.2.
- **Tests:** link in the row resolves; table renders under prettier.
- **Expected result:** the plan is listed with start date 2026-11-01.
- **Acceptance:** the `.plans/list.md` diff is one added row plus the realigned table header.
- **Rollback:** remove the row.
- **Mutation consent:** none.
- **Status:** done 2026-11-01.

### T0.4 Validate and review the plan documents

- **Scope:** read-only checks on the four PR-0 files.
- **Depends on:** T0.3.
- **Tests:** local Markdown link check, markdownlint (or NOT RUN with reason), `git diff --check`, prettier check, gitleaks, grep for the private domain and for secret-like strings, diff limited to the four files, self-review against workflow duplication and consent wording.
- **Expected result:** results recorded in `plan.md` section 17.
- **Acceptance:** no FAIL; any NOT RUN has a reason.
- **Rollback:** none needed.
- **Mutation consent:** none.
- **Status:** done 2026-11-01 (results in plan.md section 17).

### T0.5 Publish PR-0 (needs the owner)

- **Scope:** `git push -u origin docs/hybrid-ai-workflow-home-ops-plan`; `gh pr create` with the title and body from the hand-off message; add one label (the `meta-enforce-labels` check blocks unlabeled PRs).
- **Depends on:** T0.4 and the owner's explicit confirmation.
- **Tests:** CI Lint and attribution workflows pass.
- **Expected result:** an open PR; merge left to the owner.
- **Acceptance:** PR body contains no AI attribution; merge is not performed by the agent.
- **Rollback:** close the PR, delete the remote branch.
- **Mutation consent:** required for the push and the PR (DELIVERY). Merge is GITOPS_TRIGGER class and is not part of this task.

## PR-1: `AGENTS.md` and a thin `CLAUDE.md`

### T1.1 Write `AGENTS.md`

- **Scope:** create `AGENTS.md` (target under 200 lines and 20 KiB).
- **Depends on:** PR-0 approved by the owner; decisions D3, D4, D10 recorded.
- **Content:** project overview, hardware line, repository structure (including `.agents/`, `.plans/`, `.archive/`), application pattern, secrets rule and the ban on writing the private domain or secret output anywhere, permission classes and consent protocol (summary, link to `.agents/policy/permissions.md`), hard rules (no secrets, no push to `main`, no AI attribution, branch types `feat`, `fix`, `chore`, `docs`), worktree rule (one paragraph; PR-2 adds the enforcement details), process selection by reference to the claude-plugins workflow with default STANDARD + SOLO on a line carrying the marker `workflow-ref`, validation (the three existing render commands unchanged, pointer to `.agents/policy/validation.md` once PR-4 exists), plans section copied from the current `CLAUDE.md` unchanged in meaning (PR-3 rewrites it), archive and memory pointer lines, area-to-skill map (about ten lines), the rule "update docs after non-trivial changes".
- **Tests:** `grep -c` shows the file is under the caps; link check passes; no line defines profiles or topologies; gitleaks passes; no private domain.
- **Expected result:** every section of the old `CLAUDE.md` except Memory has a home (see the preservation table in plan.md section 5).
- **Acceptance:** a reviewer can tick each old section against the new file; the file contains no harness tool names.
- **Rollback:** delete `AGENTS.md`.
- **Mutation consent:** none.
- **Status:** done 2026-11-01 (`AGENTS.md`, 154 lines, 11.6 KB).

### T1.2 Write the adapter contract

- **Scope:** create `.agents/README.md`.
- **Depends on:** T1.1.
- **Content:** what lives where (table from plan.md section 4); the accepted workflow pin written once (tag and commit above) and how to bump it (read the new tag's compatibility document, re-run T1.7, update the pin in a separate PR); per-harness notes: Claude (imports `AGENTS.md`, project skills, plugin hook is a backstop), Codex (reads `AGENTS.md`; no hook claimed until T2.1), OpenCode (manual contract: read `AGENTS.md`, run the preflight by hand, no installer, no parity claim); scenarios S1 to S8 for behavioural acceptance with expected outcomes.
- **Tests:** link check; `test_no_workflow_copy` rule holds (no line names two profiles or two topologies unless marked).
- **Expected result:** one page to find any adapter fact.
- **Acceptance:** no instruction in this file that also appears in `AGENTS.md`.
- **Rollback:** delete the file.
- **Mutation consent:** none.
- **Status:** done 2026-11-01.

### T1.3 Write the permission policy

- **Scope:** create `.agents/policy/permissions.md`.
- **Depends on:** T1.1.
- **Content:** the class table and consent protocol from plan.md section 8; per-tool command lists (kubectl, argocd, talosctl, terraform, helm, task, git, gh, bws, ceph, CNPG plugin) mapped to classes; the read-only `exec` allowlist; the merge-impact map; the SECRET_ACCESS list; a rule that an unlisted command takes the stricter class; a statement of what enforces each class per harness.
- **Tests:** every command in `.claude/settings.json` `allow` appears under READ, LOCAL_CHECK or the commit entry of DELIVERY; every `deny` entry appears under SECRET_ACCESS or DESTRUCTIVE; `kubectl exec`, `gh pr merge`, `gh api` methods, `argocd app sync`, `terraform apply`, `talosctl apply-config` and `upgrade`, drain, cordon, uncordon, scale, patch, annotate, create, delete, apply and BWS changes are all listed.
- **Expected result:** the single detailed matrix.
- **Acceptance:** nothing in the file authorizes a mutation without consent; the merge entry says a merge may deploy.
- **Rollback:** delete the file and revert T1.1's link.
- **Mutation consent:** none (documentation only).
- **Status:** done 2026-11-01.

### T1.4 Turn `CLAUDE.md` into a thin adapter

- **Scope:** rewrite `CLAUDE.md` (target under 40 lines).
- **Depends on:** T1.1 to T1.3 merged in the same PR.
- **Content:** `@AGENTS.md`; memory section kept verbatim in meaning (location `.claude/memory/`, symlink trap, commit memory edits on the working branch); a line that `.claude/settings.json` is the Claude enforcement of the permission matrix; that the `git-workflows` plugin hook is a backstop; that the user can run a blocked command with the `!` prefix; the statusline. Nothing that applies to other harnesses.
- **Tests:** `test_thin_adapter`; `@AGENTS.md` present; no heading that exists in `AGENTS.md`.
- **Expected result:** old text remains available in git history; preservation table complete.
- **Acceptance:** diff shows every removed section moved to `AGENTS.md` or a policy file.
- **Rollback:** `git revert`.
- **Mutation consent:** none.
- **Status:** done 2026-11-01 (`CLAUDE.md`, 18 lines).

### T1.5 Align `.claude/settings.json` with the matrix

- **Scope:** `.claude/settings.json` only.
- **Depends on:** T1.3. Decision D5 is accepted (2026-11-01).
- **Content:** distinguish read-only variants as precisely as the permission pattern syntax allows: remove `Bash(gh api *)` from allow, allow only `gh api --method GET *` and `gh api -X GET *` forms, and add `ask` for every other `gh api` call; allow the read subcommands `gh pr view/list/diff/checks/status`, `gh run view/list/watch`, `gh label list`; allow `kubectl rollout status/history` and `kubectl auth can-i`; keep `ask` for `kubectl rollout restart/undo`; record in `permissions.md` where a prefix pattern cannot tell a read from a write (for example a `gh api` call with the method set late in the command) and treat that case as consent-required; move `gh run *` to `gh run view/list/watch`; replace `git branch*` by read forms; add `ask` for `gh pr merge*`, `gh pr create*`, `gh workflow run*`, `gh run rerun*`, `argocd app sync*`, `argocd app set*`, `argocd app delete*`, `terraform apply*`, `terraform import*`, `talosctl apply-config*`, `talosctl upgrade*`, `kubectl apply*`, `create*`, `delete*`, `patch*`, `annotate*`, `label*`, `scale*`, `exec*`, `drain*`, `cordon*`, `uncordon*`, `rollout*`, `bws secret create*`, `edit*`, `delete*`; add `deny` for `git commit*--no-verify*`, `git push*--no-verify*`, `git push*origin main*`, `bws secret get*`, `printenv*`, `env`. Keep every existing deny.
- **Tests:** `jq empty .claude/settings.json`; `test_permissions_parity`; diff reviewed by the owner (behaviour change: tighter).
- **Expected result:** the Claude enforcement matches the policy file.
- **Acceptance:** no previously blocked command became allowed; routine read commands still run without a prompt.
- **Rollback:** `git revert`.
- **Mutation consent:** none (configuration file). The owner reviews because it changes prompts.
- **Status:** done 2026-11-01; owner review of the diff pending. `gh api` is not blanket-asked: a broad ask pattern would shadow the allowed GET forms, so mutating forms get specific ask patterns and every other form falls back to the default prompt.

### T1.6 Add the first tests and runner

- **Scope:** create `.agents/tests/run.sh`, `.agents/tests/lib.sh`, `.agents/tests/test_links.sh`, `.agents/tests/test_thin_adapter.sh`, `.agents/tests/test_no_workflow_copy.sh`, `.agents/tests/test_permissions_parity.sh`.
- **Depends on:** T1.1 to T1.5.
- **Tests:** shellcheck clean; each test has a deliberately failing fixture to prove it can fail (copy the pattern of `provision/talos/tests/lib.sh`); the runner prints PASS or FAIL per test and exits non-zero on any failure.
- **Expected result:** `bash .agents/tests/run.sh` passes on the PR branch.
- **Acceptance:** negative fixtures fail as expected; no network use.
- **Rollback:** delete `.agents/tests/`.
- **Mutation consent:** none.
- **Status:** done 2026-11-01 (`bash .agents/tests/run.sh`, 5 tests).

### T1.7 Verify loading in both harnesses (owner-authorized)

- **Scope:** none in the repo; results appended to `.plans/hybrid-ai-workflow/evidence.md` section 10 (N1, N2).
- **Depends on:** T1.4 on a branch; owner authorizes opening Claude Code and Codex sessions.
- **Tests:** in a fresh session of each harness, in a worktree, ask which rules apply to deleting a PVC, to merging a PR, to writing in the primary checkout, and what the default process level is. Expected: both answers cite `AGENTS.md`, refuse to mutate without consent, call merge a deploy, and give STANDARD + SOLO. Check that Codex reads the whole file (compare against the size limit of the installed version).
- **Expected result:** N1 and N2 become PASS or FAIL with versions and date.
- **Acceptance:** on FAIL the fallback in plan.md section 18 is applied before merge.
- **Rollback:** none.
- **Mutation consent:** none for the cluster. Needs the owner's go-ahead because it starts other harness sessions.
- **Not run otherwise:** record NOT RUN with the reason; PR-1 may merge only if the owner accepts that.
- **Status:** done 2026-11-01 for Claude Code 2.1.316 and Codex 0.164.0; results in evidence.md section 11. S2, S7 and S8 NOT RUN (allowed after merge by D12).

### T1.8 Transitional skills link for Codex

- **Scope:** create the symlink `.agents/skills` pointing to `../.claude/skills`; add the link check to `.agents/tests/` (`test_skills_parity.sh`, stage-1 part); one sentence in `.agents/README.md` saying the link is transitional and `.agents/skills` is the target canonical source (D2).
- **Depends on:** T1.1, T1.2, T1.6.
- **Tests:** the link resolves; every `SKILL.md` has `name` equal to its directory and a non-empty `description`; `grep -R "superpowers:" .claude/skills` returns nothing; during the T1.7 sessions a Codex session lists `add-app` and `dev-workflow` (N3) and Claude still loads `.claude/skills` unchanged.
- **Expected result:** Codex can discover the existing skills; no skill is moved, copied or edited.
- **Acceptance:** `git diff --stat` shows one added symlink and the test; if Codex does not follow the directory link, record it in `evidence.md` and keep the link for documentation only until T5.1 chooses the mirror fallback.
- **Rollback:** remove the symlink and the test.
- **Mutation consent:** none; owner approval for the harness sessions (same as T1.7).
- **Status:** done 2026-11-01; Codex follows the link (evidence.md section 11, N3).

## PR-2: harness-agnostic worktree-first

### T2.1 Spike: Codex facts

- **Scope:** disposable repository under the scratchpad directory (never this repo); notes appended to `evidence.md` section 10 (N2 to N5).
- **Depends on:** PR-1 merged; owner authorizes a Codex session.
- **Tests:** in the disposable repo with a linked worktree: (a) does Codex read `AGENTS.md` from the worktree, (b) can Codex run `git add` and `git commit` with cwd in the linked worktree under the default sandbox, and which paths must be writable (`<repo>/.git/worktrees/<name>`), (c) does the `hooks` feature offer a pre-write interception, with what input and decision format, in a project or user config, (d) can project-level execution policy rules mark `kubectl apply` as forbidden or prompt.
- **Expected result:** a short table of facts with Codex version 0.164.0 (or the installed version) and date.
- **Acceptance:** each of the four questions answered PASS, FAIL or NOT RUN; decision recorded on whether `.codex/config.toml` is needed (D5, plan.md D-list).
- **Rollback:** delete the disposable repository.
- **Mutation consent:** none for the cluster; owner approval to run Codex.

### T2.2 Implement `worktree-preflight`

- **Scope:** create `.agents/bin/worktree-preflight` (POSIX sh, executable), `.agents/tests/test_worktree_preflight.sh`.
- **Depends on:** PR-1.
- **Interface:** `worktree-preflight [--path <p>] [--hook] [--json]`. Prints `kind`, `branch`, `default_branch`, `dirty`; exit codes 0 (worktree, submodule, git-internal, not-repo), 3 (primary or bare), 2 (usage). `--hook` additionally fails when the branch equals the default branch. Break-glass via `HOME_OPS_BREAK_GLASS` with a non-empty reason: exit 0, warning on stderr, one line appended to `$(git rev-parse --git-common-dir)/break-glass.log`.
- **Tests:** the positive and negative scenario list in plan.md section 7, built in temporary repositories (`git init`, `git worktree add`, a submodule with `protocol.file.allow=always`, a bare clone); shellcheck; runs without `jq`.
- **Expected result:** deterministic classification equal to the plugin guard's `classify_target` for the same inputs.
- **Acceptance:** all scenarios pass; empty reason does not bypass; the script never writes to the repository except the log line under break-glass.
- **Rollback:** delete the script and its test.
- **Mutation consent:** none.

### T2.3 Pre-commit guard

- **Scope:** `.pre-commit-config.yaml` (new local hook `worktree-first`, stage `pre-commit`, `language: script`, entry `.agents/bin/worktree-preflight --hook`, `pass_filenames: false`, `always_run: true`), `.agents/tests/test_precommit_guard.sh`.
- **Depends on:** T2.2.
- **Tests:** in temporary repos: commit in primary fails; commit on the default branch inside a worktree fails; commit on a feature branch in a worktree passes; break-glass passes and logs; `pre-commit run --all-files` on this repo still passes in a worktree.
- **Expected result:** every harness that commits through git is checked.
- **Acceptance:** the existing hooks (gitleaks, attribution, whitespace) are unchanged; `docs/` and `renovate/` branches pass.
- **Rollback:** remove the hook entry and run `pre-commit install` to refresh the installed script.
- **Mutation consent:** none.

### T2.4 Claude project hook

- **Scope:** `.claude/settings.json` (`hooks.PreToolUse`, matcher `Edit|Write|NotebookEdit`), `.agents/bin/claude-pretool-guard` (POSIX sh, no `jq`), `.agents/tests/test_claude_hook.sh`.
- **Depends on:** T2.2; owner has reviewed duplication with the plugin hook.
- **Tests:** JSON fixtures piped to the script: Write to a path in the primary (deny JSON), in a worktree (no output, exit 0), outside any repository (allow), missing `file_path` (allow), break-glass set (allow), tool name not in the matcher (allow). The deny output uses `hookSpecificOutput.permissionDecision: "deny"` with the worktree command in the reason.
- **Expected result:** Claude clones without the plugin still block edit-tool writes in the primary.
- **Acceptance:** with both hooks active a write to the primary is denied once with a clear message; reads and worktree writes are unaffected.
- **Rollback:** remove the `hooks` entry and the script.
- **Mutation consent:** none.

### T2.5 Codex adapter (conditional)

- **Scope:** `.codex/config.toml` only if T2.1 shows it is needed; otherwise a paragraph in `.agents/README.md` stating the manual preflight.
- **Depends on:** T2.1.
- **Tests:** a Codex session started in a linked worktree can commit (owner-authorized, same as T2.1); the file contains no rule duplicated from `AGENTS.md` and no secret.
- **Expected result:** documented, minimal Codex settings, or an explicit "no adapter needed".
- **Acceptance:** the decision and its evidence are recorded.
- **Rollback:** delete `.codex/`.
- **Mutation consent:** none; needs the owner's go-ahead for a Codex session.

### T2.6 Worktree section, break-glass and hygiene

- **Scope:** `AGENTS.md` (worktree section extended), `.agents/README.md`, `.claudeignore` (add `.worktrees/` if D11 accepted and honored), `.claude/memory/` untouched.
- **Depends on:** T2.2 to T2.4.
- **Content:** preflight command and exit codes; branch and path convention including `docs/`; `.worktrees/` excluded through `.git/info/exclude`; read-only exceptions list; break-glass rules (human sets the variable before launching, agents must not); the three enforcement levels stated per harness.
- **Tests:** link check; `test_no_workflow_copy`; `git status` in the primary shows no `.worktrees` noise.
- **Expected result:** the rule is complete and honest about limits.
- **Acceptance:** the text matches the implemented exit codes and variable name.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

## PR-3: plan convention, indexes and archive

### T3.1 Document the plan convention

- **Scope:** create `.plans/README.md`; update the Plans section of `AGENTS.md`.
- **Depends on:** PR-1; decision D1.
- **Content:** folder layout, front matter fields and status values (plan.md section 6), pointer to the `development-lifecycle` plan, tasks, handoff and decision resources, rule that Superpowers output is redirected to `.plans/<slug>/`, legacy forms still readable, `TODO.md` out of the workflow, how a task becomes a PR row, archive procedure after Ship.
- **Tests:** link check; front matter example validates under `check-plans`.
- **Expected result:** one description of where plans go for every harness.
- **Acceptance:** `AGENTS.md` Plans section no longer names Superpowers as the default.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

### T3.2 Widen the active index

- **Scope:** `.plans/list.md`.
- **Depends on:** T3.1.
- **Content:** columns Plan, Status, Owner, Profile/Topology, Branch, PR, Started, Updated; migrate the single existing row (this plan).
- **Tests:** prettier check; `check-plans` accepts it.
- **Expected result:** every active plan has status, owner, branch and PR visible in the index.
- **Acceptance:** no information from the old row is lost.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

### T3.3 Archive notice and index note

- **Scope:** create `.archive/.plans/README.md`; add one explanatory line above the table in `.archive/.plans/list.md`.
- **Depends on:** T3.1.
- **Content:** archived plans are history, not instructions; "REQUIRED SUB-SKILL" and similar lines are ignored; paths are stable because live docs link to them; how new entries are added.
- **Tests:** link check; `git diff --stat` shows no other file under `.archive/`.
- **Expected result:** the archive is marked without rewriting history.
- **Acceptance:** zero changed lines in existing archived plans or specs.
- **Rollback:** delete the new file, revert the one line.
- **Mutation consent:** none.

### T3.4 Implement `check-plans`

- **Scope:** create `.agents/bin/check-plans`, `.agents/tests/test_check_plans.sh`.
- **Depends on:** T3.1, T3.2.
- **Checks:** each `.plans/<slug>/` has `plan.md` and `tasks.md`; plan front matter has the required fields and a valid `status`; each folder has a `list.md` row and each row links to an existing plan; no files under `docs/superpowers/`; `.plans/superpowers/` content gives a warning; no plan or evidence file contains a `kubectl`/`talosctl`/`terraform` mutation line outside a fenced block marked as a consent-gated step (simple heuristic, warning); all relative links resolve; archive links in `.archive/.plans/list.md` resolve.
- **Tests:** fixtures for each failure; passes on the real tree.
- **Expected result:** a second plan convention cannot appear unnoticed.
- **Acceptance:** negative fixtures fail with a clear message.
- **Rollback:** delete the script and test.
- **Mutation consent:** none.

### T3.5 Reconcile the plan memory entry

- **Scope:** `.claude/memory/project_plans_location_convention.md`, `.claude/memory/MEMORY.md` (one line).
- **Depends on:** T3.1.
- **Content:** replace the Superpowers-specific "how to apply" with the neutral rule and a link to `.plans/README.md`; keep the history of the 2026-10-20 reorganization. No private domain.
- **Tests:** grep for the private domain on the author's machine (value from the environment, not written in any file); link check.
- **Expected result:** memory no longer contradicts `AGENTS.md`.
- **Acceptance:** the entry's `description` still names the archive location.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

### T3.6 Dry-run the archive procedure

- **Scope:** a scratch copy under the scratchpad directory; no repo change.
- **Depends on:** T3.4.
- **Tests:** move a copy of a finished plan folder, rewrite links with a path replace, run `check-plans`; expected clean.
- **Expected result:** the procedure in `.plans/README.md` is proven before the first real archive (PR-7).
- **Acceptance:** commands recorded in `.plans/README.md` match what worked.
- **Rollback:** delete the scratch copy.
- **Mutation consent:** none.

## PR-4: validation matrix, PR template and CI

### T4.1 Write the validation policy

- **Scope:** create `.agents/policy/validation.md`.
- **Depends on:** PR-1 to PR-3.
- **Content:** the matrix in plan.md section 9, with exact commands and paths from the repository; the four layers L0 to L3; the NOT RUN rule and wording; the recommended profile column; the local `file://` chart bump rule; the Deployment strategy live-patch note; the statement that `task lint:*` is advisory (until D6).
- **Tests:** `test_validation_policy`: each script and task named exists; each change type from the task statement has a row (documentation, plain YAML, Helm or `values.yaml`, Kustomize, ArgoCD Application and ApplicationSet, Talos, Terraform, ExternalSecret, storage/CNPG/Ceph, network, live-test needs).
- **Expected result:** one place that answers "what do I run for this change".
- **Acceptance:** no new tool is introduced except the adaptation tests; `AGENTS.md` links here.
- **Rollback:** delete the file and the link.
- **Mutation consent:** none. Rows that list mutating live steps are documentation only.

### T4.2 Add the PR template

- **Scope:** create `.github/pull_request_template.md`.
- **Depends on:** T4.1.
- **Content:** Summary; Validation table (check, result PASS/FAIL/NOT RUN/N/A, reason); Impact (paths mapped to the merge-impact classes, whether merge deploys, rollback); Live follow-up (consent needed); label reminder; no attribution lines.
- **Tests:** prettier and markdownlint rules; the file contains no AI attribution text matching the CI pattern.
- **Expected result:** every PR states validation and merge impact.
- **Acceptance:** the template renders in a draft PR (owner-authorized; otherwise NOT RUN).
- **Rollback:** delete the file.
- **Mutation consent:** none.

### T4.3 Add the CI workflow

- **Scope:** create `.github/workflows/agent-instructions.yaml`.
- **Depends on:** T1.6, T2.x tests, T3.4.
- **Content:** triggers on pull requests to `main` for the instruction and plan paths, `permissions: contents: read`, concurrency, pinned `actions/checkout` by the same SHA the other workflows use, installs `shellcheck`/`jq` only if absent, runs `bash .agents/tests/run.sh` and `shellcheck` over `.agents/bin` and `.agents/tests`.
- **Tests:** `actionlint` (runs in Lint CI) and `yamllint`; the job passes on the PR and fails on a deliberately broken fixture branch (owner-authorized push; otherwise NOT RUN with the local negative fixtures as the substitute evidence).
- **Expected result:** instruction drift is caught before merge.
- **Acceptance:** the job needs no secrets and mutates nothing.
- **Rollback:** delete the workflow.
- **Mutation consent:** pushing a test branch needs the owner's confirmation.

### T4.4 Decide on strict lint and local markdownlint

- **Scope:** documentation of the decision in `plan.md` D6; optional `.taskfiles/lint.yml` edit only if the owner accepts.
- **Depends on:** T4.1 data; owner.
- **Tests:** if accepted: `task lint:all` returns non-zero on a seeded lint error, zero on a clean tree.
- **Expected result:** either an explicit "advisory" label in the docs, or strict lint.
- **Acceptance:** `AGENTS.md` and the dev-workflow skill describe the actual behaviour.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

### T4.5 Verify GitHub repository settings by hand (owner)

- **Scope:** read-only inspection in the GitHub web UI (Settings, Branches and Rules); results appended to `.plans/hybrid-ai-workflow/evidence.md` section 10 (N7). No setting is changed by this task.
- **Depends on:** none; schedule before PR-4 merges so the CI design can use the result.
- **Tests:** record, with the date, for `main`: branch protection or rulesets present or absent, required reviews, required status checks (names), enforcement for administrators, force-push and deletion rules, whether the `Lint`, `Talos config` and `No Claude attribution` checks are required, `allow_auto_merge`, merge methods, and who may bypass.
- **Expected result:** N7 changes from NOT VERIFIED to VERIFIED with the observed values, or stays NOT VERIFIED with the reason.
- **Acceptance:** nothing is inferred from a failed API call (HTTP 403 on the protection endpoint is not evidence of missing protection); any gap found becomes a new open decision, not an automatic change.
- **Rollback:** none needed (read-only).
- **Mutation consent:** none for reading. Changing a setting is a separate decision by the owner.

## PR-5: skills, memory and repository documentation

### T5.1 Canonical skills move to `.agents/skills`

- **Scope:** replace the transitional link: `git mv .claude/skills/<skill> .agents/skills/<skill>` for all 18 skills in one commit, then make `.claude/skills` an adapter symlink to `../.agents/skills`; update path references (`CLAUDE.md`, `AGENTS.md`, `.agents/README.md`, `.claude/memory/feedback_claude_files_in_workspace.md` and its index line, any `docs/` page or skill that names `.claude/skills/`); extend `.agents/tests/test_skills_parity.sh`.
- **Depends on:** PR-1 (T1.8), PR-4; results N3, N6 and N10 recorded as PASS in `evidence.md` (owner authorizes the Claude and Codex sessions); decision D2.
- **Tests:** both links resolve; in fresh Claude and Codex sessions the skill list contains `add-app` and `dev-workflow` and a trigger phrase loads the right skill; `git log --follow` still shows skill history; `grep -rn ".claude/skills" AGENTS.md CLAUDE.md docs .agents` shows only intentional adapter mentions.
- **Fallback (a harness does not follow a symlink, or N10 fails):** keep `.agents/skills` as the real source and make `.claude/skills` a real directory generated by `.agents/bin/sync-skills` (copy plus a "generated, do not edit" marker file); add `test_skills_drift` (byte comparison of the mirror with `.agents/skills`) to the agent-instructions CI job so any hand edit or stale mirror fails the PR.
- **Expected result:** one canonical copy of each skill, available to both harnesses, with no drift possible.
- **Acceptance:** no skill content changed in the move commit (renames only); `test_skills_parity` (and `test_skills_drift` in the fallback) pass in CI.
- **Rollback:** `git revert` restores `.claude/skills` as the real directory and the stage-1 link.
- **Mutation consent:** none; owner approval for the harness sessions.

### T5.2 Neutral skill text

- **Scope:** `.claude/skills/prometheus-portforward-session/SKILL.md`, `.claude/skills/cluster-reference/SKILL.md` (line about reboot), `.claude/skills/talos-config-editing/SKILL.md` (lines about reboot and apply), `.claude/skills/dev-workflow/SKILL.md` (branch types, validation pointer).
- **Depends on:** PR-4.
- **Content:** replace "blocked for Claude" and "Claude Code" with the policy statement ("needs the user's consent; the user can run it with their shell prefix"); keep every technical step unchanged.
- **Tests:** `git diff` shows only wording; prettier; the link check.
- **Expected result:** no skill states harness behaviour as repository fact.
- **Acceptance:** skill names and trigger phrases unchanged.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

### T5.3 Memory triage

- **Scope:** `.claude/memory/*.md` listed in evidence section 9.2 and `.claude/memory/MEMORY.md`.
- **Depends on:** PR-1, PR-3.
- **Content:** for each rule-bearing entry, confirm it exists in `AGENTS.md` or a policy file in short form; narrow `feedback_push_and_pr_after_branch` to match D4 (no standing authorization: push and PR only on explicit instruction or when plainly part of the assigned task); procedure gotchas get a skill or docs destination or an explicit "stay"; nothing deleted without the owner's yes.
- **Tests:** list of 41 files with a decision each recorded in `evidence.md`; no private domain, secret or identifier in any touched file; index line count unchanged or smaller.
- **Expected result:** no rule exists only in Claude memory.
- **Acceptance:** `AGENTS.md` memory pointer line is accurate.
- **Rollback:** `git revert`.
- **Mutation consent:** none.

### T5.4 Repository page `docs/src/contributing/ai-workflow.md` (home-ops ownership)

- **Ownership:** this page is the **local application** of the workflow in `home-ops` and is owned by `home-ops`. The general adoption guide for any repository is owned by `claude-plugins` (task F1.1) and is not written here.
- **Scope:** new page `docs/src/contributing/ai-workflow.md`; a new nav group `"Contributing"` with entry `"AI workflow": contributing/ai-workflow.md` in `.github/mkdocs/mkdocs.yml` (the only MkDocs config in the repo, `docs_dir: ../../docs/src/`); `README.md` one line only if it lists tooling.
- **Depends on:** PR-1 to PR-4; T5.5 for the PR-time build.
- **Content (sections, in this order):**
  1. What this page is and is not: the home-ops application of the workflow; the workflow definitions (lifecycle, profiles, topologies) live in `claude-plugins` and are linked at the pinned tag `ai-workflow-v0.1.0-preview.1`, never restated.
  2. Where rules live: `AGENTS.md` (shared), `CLAUDE.md` (Claude adapter), `.agents/` (policy, tooling, tests), `.plans/`, skills.
  3. Onboarding: Claude Code, Codex, and the future OpenCode placeholder (what is verified, what is NOT VERIFIED, per N1 to N10 in `evidence.md`; unverified claims are labelled as such).
  4. Worktree-first: how to start a task, `.worktrees/<type>/<slug>`, what the preflight and the pre-commit hook enforce per harness, break-glass (human only, with a reason).
  5. Plans: `.plans/<slug>/plan.md` and `tasks.md`, the index, the archive is history and not instructions.
  6. Validation: the change-type matrix summary with a link to `.agents/policy/validation.md`; L0 to L3 and NOT RUN; how to read the PR Validation table.
  7. Permission boundaries: action classes with a link to `.agents/policy/permissions.md`; examples of a valid consent request and of the GITOPS_TRIGGER impact statement; merge is a production operation.
  8. Handoff: what a handoff note contains (state, base SHA, branch, worktree, next task, open questions, NOT RUN items) and where it is kept; link to the topology definitions in `claude-plugins`, not a copy.
  9. Troubleshooting: guard blocks a write in the primary checkout; hook not installed in a new worktree; `@AGENTS.md` import not loaded; skill not discovered; pre-commit blocked by attribution or gitleaks (fix the cause, never `--no-verify`); `check-plans` failure; MkDocs build failure.
- **Public-site rules:** no private domain, hostnames, IPs, bucket names or identifiers; examples use placeholders (`<app>`, `example.invalid`).
- **Tests:**
  - local link check over the page and the nav entry (relative links resolve; links to `claude-plugins` use the pinned tag URL form);
  - `test_no_workflow_copy` (PR-1) extended to cover `docs/src/contributing/`: no definition of lifecycle, profiles or topologies;
  - the secret/domain scan from T4.x over the page;
  - prettier with the repo config;
  - MkDocs build, see T5.5.
- **Expected result:** the docs rule ("update docs after non-trivial changes") is satisfied for the adoption; a human can onboard from this page alone.
- **Acceptance:** all nine sections present; no copied canonical definition; every link resolves; nav entry renders; MkDocs build passes in strict mode (T5.5) or is recorded NOT RUN with the reason.
- **Rollback:** `git revert` removes the page and the nav entry; no other file refers to the page except an optional README line, which the same revert removes.
- **Mutation consent:** none. Merge to `main` triggers the public GitHub Pages publication (`publish-pages.yaml`); the owner decides the merge (D8) and the PR states this in Impact.

### T5.5 PR-time MkDocs build check

- **Scope:** `.github/workflows/docs-build.yaml` (new): on `pull_request` with `paths` `docs/**`, `.github/mkdocs/**` and the workflow itself, install `.github/mkdocs/requirements.txt` and run `mkdocs build --strict --config-file .github/mkdocs/mkdocs.yml --site-dir <runner temp>`; no deploy, read-only `contents` permission, no secrets.
- **Why:** today `publish-pages.yaml` builds only on a push to `main`, so a broken nav entry or link is found after the merge, on the production publication path (evidence: `.github/workflows/publish-pages.yaml`).
- **Depends on:** none; may merge before T5.4 so that T5.4 is validated by it.
- **Tests:** `actionlint` and `yamllint` on the workflow; the job is green on the T5.4 PR; a deliberately broken nav entry in a scratch branch makes it fail (negative test; run in a worktree, not merged).
- **Local variant (owner-approved install):** in a throwaway virtualenv outside the repo, `pip install -r .github/mkdocs/requirements.txt` then the same build command. Installing packages is external code, so the executor asks first; without approval the local build is recorded NOT RUN and CI is the evidence. Baseline on 2026-11-01: `mkdocs` is on `PATH` but `pymdownx` and the Material theme are missing, so the build does not start (config parse error); this is NOT RUN, not a failure of the docs.
- **Expected result:** documentation errors are caught in the PR, not on `main`.
- **Acceptance:** the check passes on a docs PR; it does not run for unrelated PRs; it is not marked required until the owner decides (D9, T4.5).
- **Rollback:** delete the workflow file.
- **Mutation consent:** none for the file; making the check required is a repository setting and the owner's decision.

## PR-6: pilot (optional)

### T6.1 One small non-production change through the whole lifecycle

- **Scope:** one change that touches no `cluster/`, `provision/` or `charts/` path, for example correcting a documentation page or a skill's wording found during T5.2. The owner picks it.
- **Depends on:** PR-1 to PR-5.
- **Run:** STANDARD + SOLO in Claude Code; optionally a HANDOFF to Codex for Build (needs the owner's explicit authorization of that topology). Record base SHA, branch, worktree, validation table, and the handoff file if used, in a new plan folder or in this plan's `evidence.md`.
- **Tests:** the pilot PR's Validation and Impact sections are filled; `check-plans` and the agent-instructions job pass; no write happened in the primary checkout (`git status` of the primary clean).
- **Expected result:** evidence that the model works end to end, and a list of frictions.
- **Acceptance:** frictions are turned into follow-up tasks or `.plans/TODO.md` items.
- **Rollback:** revert the pilot PR.
- **Mutation consent:** none for docs. Push and PR need an explicit instruction (D4); merge is the owner's (D8).

## External follow-up (not part of any home-ops PR): `claude-plugins` adoption guide

Ownership: `claude-plugins` owns the general guide; `home-ops` owns only its local application page (T5.4). Nothing in this section is done in `home-ops`, and nothing here is started by the current plan; it needs its own spec and PR in `mmalyska/claude-plugins` and the owner's explicit go-ahead.

### F1.1 Canonical `docs/workflow/repository-adoption-guide.md` in `claude-plugins`

- **Scope (in `mmalyska/claude-plugins`, its own worktree, branch `docs/repository-adoption-guide`):** create `docs/workflow/repository-adoption-guide.md`: a universal guide for adapting any repository to the Hybrid AI Engineering Workflow, derived from the `dotfiles` and `home-ops` adoptions. Contents: when to adopt (QUICK/STANDARD/DEEP triage by repository risk), the instruction-file model (`AGENTS.md` canonical, thin harness adapters, placeholder for harnesses not yet verified), worktree-first enforcement layers and their honest limits, plans and archive conventions, a permission-matrix template with the action classes, a validation-matrix template, CI and test patterns for the instructions themselves, rollout as small revertible PRs, rollback, a **checklist** (audit, decide, adopt, verify, record NOT RUN), and a **plan template** (`plan.md` and `tasks.md` skeletons with the front matter and the Scope/Depends on/Tests/Expected result/Acceptance/Rollback/Mutation consent task fields). Lessons learned from `home-ops` go in as general patterns (for example: validate documentation builds before merge when merge publishes; a merge in a GitOps repo is a production operation; no standing authorization to publish), with no private values.
- **Depends on:** the `home-ops` PR-1 to PR-4 results, so the guide rests on a completed adoption and not on this plan; the `dotfiles` experience recorded by its owner.
- **Tests (in `claude-plugins`):** its own link check and docs validation; the guide references the canonical lifecycle/profiles/topologies by link and does not duplicate any definition elsewhere; a scan for private domains, hostnames and identifiers; the template renders as valid Markdown and validates against that repository's own plan-check if it has one.
- **Expected result:** a second repository can be adapted by following the guide alone.
- **Acceptance:** the checklist and the plan template are present and usable; every `home-ops`-specific detail is generalized or removed; the `home-ops` page and the guide do not contradict each other (cross-read recorded in the PR).
- **Rollback:** revert the `claude-plugins` PR; `home-ops` is unaffected because it links to the guide only after F1.2.
- **Mutation consent:** none for the file; push, PR and merge in `claude-plugins` follow that repository's rules and the owner's explicit instruction (D4, D8).

### F1.2 Link the guide from the `home-ops` page (small home-ops PR, after F1.1 is merged)

- **Scope:** one sentence and one link in `docs/src/contributing/ai-workflow.md` section 1, pointing to the guide at a pinned tag or commit of `claude-plugins`; nothing else.
- **Depends on:** F1.1 merged and tagged or pinned.
- **Tests:** link check; T5.5 build; no copied content.
- **Expected result:** readers of the home-ops page find the general guide.
- **Acceptance:** the link resolves at the pinned reference.
- **Rollback:** `git revert`.
- **Mutation consent:** none; push and PR only on explicit instruction (D4).

## PR-7: ship and archive

### T7.1 Archive this plan after Ship

- **Scope:** move `.plans/hybrid-ai-workflow/` to `.archive/.plans/hybrid-ai-workflow/`; edit both `list.md` files; rewrite links.
- **Depends on:** PR-1 to PR-5 merged, T1.7 and T5.1 results recorded, PR-6 done or dropped by the owner. F1.1 and F1.2 are tracked outside this plan and do not block archiving; if still open, list them in the archived plan status.
- **Tests:** `check-plans`; link check; `git diff --stat` shows a rename plus index edits.
- **Expected result:** the plan is history; status `shipped` with the PR numbers.
- **Acceptance:** live docs links to the plan (if any) updated; nothing else under `.archive/` changed.
- **Rollback:** move the folder back, restore both rows.
- **Mutation consent:** none for the move; push and PR only on explicit instruction (D4).
