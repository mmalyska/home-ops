# Tasks: Hermes orchestration

Gates (G1 to G8), live checks (V1 to V9) and decisions are defined in [spec.md](spec.md). Facts are in
[evidence.md](evidence.md).

Unless a task says otherwise: status is planned, actual evidence is NOT RUN, the conductor is the integrator, each writer
works in its own linked worktree on the branch named in the task, and the owner merges. The expected result is the task's
done criterion. Update a task's status and evidence in place as it is done.

- **Authority:** the owner instructed the first wave (T02, T03, T04, T06, T13, T15), including push and PR, on 2026-11-09. Other
  tasks need their own instruction. Every command in a `consent-gated` block needs the owner's consent at that moment,
  naming the action, target and effect.
- **Next action:** a task starts when its dependencies are merged and its checks have passed.
- **Evidence found after a PR merged** goes into a `docs/hermes-evidence-<task>` PR.
- **Secrets:** name Bitwarden items by reference. IDs appear only in the `#gitleaks:allow` value lines of chart values.

## T01 — Owner prerequisites

- **Status:** done, 2026-11-09. Evidence in [evidence.md](evidence.md), section "T01 prerequisites".
- **Who:** the owner. **Files:** none. **Depends on:** nothing.
- **Human task, blocking everything:** no other task starts until this one is done, so a bad token or a missing invitation
  shows up before anything is half-built.
- **Do:**
  1. Invite `rudi-the-brain` and `agent-rosie` with write access to the 10 source repositories, and accept the invitations.
  2. Add each account's SSH signing key on GitHub as a signing key.
  3. Confirm `HERMES_MAIN_GITHUB_TOKEN` belongs to rudi and `HERMES_WORKER_GITHUB_TOKEN` to rosie, as classic tokens with
     `repo`, `workflow` and `read:org` scopes (`read:org` added after the first daily run: `gh pr edit` needs it).
  4. Create in Bitwarden: `HERMES_MAIN_SIGNING_KEY`, `HERMES_WORKER_SIGNING_KEY`, `HERMES_MAIN_WS_SSH_KEY`,
     `HERMES_WORKER_WS_SSH_KEY`. Give the build actor the four IDs and the two workspace public keys.
  5. Create `#hermes-renovate`, let the bot post and create threads there, and give the build actor its channel ID.
     Confirm that `#hermes` is the channel already in `discord.free_response_channels`.
  6. Log the `coder` CLI in where T07 runs.
- **Done when:** the owner confirms all six. **Rollback:** none needed.

## T02 — Gateway aliases `main-cheap` and `main-lite`

- **Status:** done, 2026-11-09 (#6187). V7 passed: each alias answered as itself with fallbacks off.
- **Branch:** `feat/hermes-gateway-aliases`. **Depends on:** T01.
- **Files:** `cluster/apps/ai/litellm/templates/models/main-cheap.yaml` and `main-lite.yaml` (new, modelled on `main.yaml`),
  `cluster/apps/ai/litellm/templates/teams.yaml`, `cluster/apps/ai/litellm/templates/litellmproxy.yaml`,
  `cluster/apps/ai/hermes-agent/templates/litellm-key.yaml`, `docs/src/k8s/ai-gateway.md`.
- **Change:** `main-cheap` is `chatgpt/gpt-6.1-terra`, `main-lite` is `chatgpt/gpt-6-luna`. Add both to the `hermes` team and
  key. Add the fallbacks from P5. Add both to the models table in the doc.
- **Checks:** `helm template litellm cluster/apps/ai/litellm -f cluster/apps/ai/litellm/values.yaml` renders both models;
  `task lint:all` shows nothing new.
- **Live, after merge:** the proxy builds `chatgpt/` models only at startup (`docs/src/k8s/ai-gateway.md`). This is V7,
  checked with fallbacks off so that a fallback cannot hide a failure:

  ```sh consent-gated
  kubectl -n ai delete pod -l app.kubernetes.io/name=litellm
  kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- sh -c \
    'for m in main-cheap main-lite; do
       curl -s http://litellm.ai.svc.cluster.local:4000/v1/chat/completions \
         -H "Authorization: Bearer $LITELLM_API_KEY" -H "Content-Type: application/json" \
         -d "{\"model\":\"$m\",\"disable_fallbacks\":true,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":16}"
       echo
     done'
  ```

- **If V7 fails:** point the failing alias at the next model up (Luna to Terra, Terra to Sol) and record it in
  `evidence.md`, section "Live checks".
- **Done when:** each call answers with its own alias as `model`. **Rollback:** revert the PR.

## T03 — Argo CD reconciles every 30 minutes

- **Status:** done, 2026-11-09 (#6188). The value is live and the controller was restarted.
- **Branch:** `chore/argocd-reconcile-30m`. **Depends on:** T01.
- **Files:** `cluster/apps/core/argocd/patches/argocd-cm.yaml`.
- **Change:** `timeout.reconciliation` from `1h` to `30m`.
- **Checks:** render the Argo CD app; the diff is that one value.
- **Live, after merge:** the controller reads the value from its environment at startup and no reloader watches it:

  ```sh consent-gated
  kubectl -n argocd rollout restart statefulset/argocd-application-controller
  ```

- **Expected:** `kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.timeout\.reconciliation}'` prints `30m`, and the
  controller pod is newer than the merge. **Done when:** both hold, and every Application is still Synced.
- **Rollback:** revert the PR and restart the controller the same way.

## T04 — Upgrade Hermes to the current `v0.x` release

- **Status:** done, 2026-11-09 (#6192, #6193). Running v0.23.0; Discord and Honcho checked. Piper text-to-speech is open in `.plans/TODO.md`.
- **Branch:** `feat/hermes-upgrade`. **Depends on:** T01.
- **Files:** `cluster/apps/ai/hermes-agent/values.yaml`, chart templates if the release notes need it,
  `.plans/hermes-orchestration/evidence.md` (section "Upgrade notes").
- **Change:** pin `hermes.image.tag` to the latest `v0.x` tag by digest (`v0.23.0` on 2026-11-08; re-check). Read the
  release notes from `v2026.9.24` onwards, record breaking changes and renamed keys, and adjust the seeders, args and
  `postStart` where needed.
- **Backup first:**

  ```sh consent-gated
  kubectl -n hermes-agent patch replicationsource hermes --type merge -p '{"spec":{"trigger":{"manual":"pre-upgrade"}}}'
  ```

  Wait until `status.lastManualSync` is `pre-upgrade`.

- **Checks:** `helm template`; `task lint:all`. After merge: pod Ready, boot log reconciles `default`, Discord answers a
  mention.
- **Done when:** those hold. **Risk:** R8. **Rollback:** revert the PR and restore the volume from that backup.

## T05 — Renovate tracks the `v0.x` tags

- **Status:** done, 2026-11-09 (#6195). A real upgrade PR is still to be seen at the next Hermes release.
- **Branch:** `fix/renovate-hermes-versioning`. **Depends on:** T04 (Renovate compares against the pinned tag).
- **Files:** `.github/renovate/groups.json5`.
- **Change:** in the Hermes rule, replace `versioning: loose` with `semver-coerced` and add `allowedVersions: "/^v0\\./"`.
- **Checks:** `npx --yes --package renovate -- renovate-config-validator .github/renovate.json5`.
- **Done when:** the validator passes. A real upgrade PR is observed at the next Hermes release. **Rollback:** revert the PR.

## T06 — Workspace template: git identity and signing

- **Status:** done, 2026-11-09 (#6189).
- **Branch:** `feat/agent-workspace-git-identity`. **Depends on:** T01.
- **Files:** `cluster/apps/ai/coder/workspace-template-agent-workspace/main.tf` and its `README.md`,
  `docs/src/k8s/agent-workspaces.md`.
- **Change:** add optional parameters `git_user_name` and `git_user_email`. At every start, write the git configuration:
  name and email; when a signing key is loaded, `gpg.format ssh`, `user.signingkey` as `key::<public key>` from `ssh-add -L`,
  `commit.gpgsign` and `tag.gpgsign`; when `GITHUB_TOKEN` is set, `gh auth setup-git` and
  `url."https://github.com/".insteadOf` for `git@github.com:` and `ssh://git@github.com/`.
- **Checks:** in that directory, `terraform init -backend=false`, `terraform fmt -check` and `terraform validate`.
- **Done when:** both pass. The template reaches Coder in T07. **Rollback:** revert the PR.

## T07 — Allowlist and the two workspaces

- **Status:** done, 2026-11-09 (#6196). Both workspaces are healthy on the current template.
- **Branch:** `feat/hermes-workspaces`. **Depends on:** T01, T06.
- **Files:** `cluster/apps/ai/agent-workspaces/values.yaml` (`allowedBwsRefs` gains the two signing-key IDs; the workspace SSH
  keys go to the Hermes pod in T09).
- **Live, after merge:** follow the `coder-workspace-template-deploy` skill for the push. The `<id>` and key values come
  from T01, and are typed at the prompt, not stored. `src_size` stays at its 30Gi default for main and is 50Gi for worker.

  ```sh consent-gated
  coder templates push agent-workspace --directory cluster/apps/ai/coder/workspace-template-agent-workspace --yes
  coder create mmalyska/hermes-main --template agent-workspace --yes \
    --parameter github_token_ref=<id> --parameter signing_key_ref=<id> --parameter authorized_key="<public key>" \
    --parameter git_user_name=rudi-the-brain --parameter git_user_email=<noreply address> \
    --parameter kubernetes_access=true --parameter talos_access=false
  coder create mmalyska/hermes-worker --template agent-workspace --yes \
    --parameter github_token_ref=<id> --parameter signing_key_ref=<id> --parameter authorized_key="<public key>" \
    --parameter git_user_name=agent-rosie --parameter git_user_email=<noreply address> \
    --parameter kubernetes_access=true --parameter talos_access=false --parameter src_size=50Gi
  ```

- **Expected:** both Deployments Available in `agent-workspaces`; `coder list` healthy and not outdated. In each workspace,
  `kubectl auth can-i list applications.argoproj.io -A` is `yes` and `kubectl auth can-i get secrets -A` is `no`.
- **Done when:** those hold. **Rollback:** `coder delete` both, then revert the PR.

## T08 — Identity checks and merge requirements

- **Status:** done, 2026-11-09. V8 passed.
- **Files:** `.plans/hermes-orchestration/evidence.md` (section "Merge requirements").
- **Depends on:** T01, T07.
- **Checks, in each workspace:** `gh auth status` shows the right account; `gh repo list mmalyska --source --no-archived`
  lists the 10 repositories. For each repository, record the required checks (`gh api repos/mmalyska/<repo>/branches/<default>`,
  field `protection`) and the allowed merge methods (`gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed`),
  and confirm `gh api repos/mmalyska/<repo>/rules/branches/<default>` answers.
- **Scratch write, `mmalyska/dotfiles`:** each account pushes an empty signed commit to `hermes/identity-check-<account>` over
  HTTPS, GitHub shows "Verified", and the branch is deleted. This is an external write: ask first.
- **If V8 fails:** stop and ask the owner.
- **Done when:** both accounts pass and the section is written. **Rollback:** delete the scratch branches.

## T09 — Hermes chart: workspace keys, profile environment, cleanup

- **Status:** done, 2026-11-09 (#6197).
- **Branch:** `feat/hermes-workspace-credentials`. **Depends on:** T01, T04.
- **Files:** `cluster/apps/ai/hermes-agent/values.yaml`, `templates/deployment.yaml`.
- **Change:** add the two `*_WS_SSH_KEY` secrets. Remove `GITHUB_PERSONAL_ACCESS_TOKEN` and `SANDBOX_DEVOPS_SSH_KEY`. Seed
  `/opt/data/ssh/hermes-{main,worker}.key` (mode 600, owned by the Hermes user) and delete `sandbox-devops.key`. Add
  `hermes.profileEnv.<profile>`, non-secret keys merged into each profile's `.env`: `TERMINAL_SSH_HOST`, `_USER`, `_PORT`,
  `_KEY`, `TERMINAL_SSH_PERSISTENT`, and for `default` `DISCORD_HOME_CHANNEL` set to `#hermes-renovate`.
- **Checks:** `helm template`, `task lint:all`; the rendered Deployment has no reference to the removed secrets.
- **Done when:** merged, the pod is Ready and both keys exist on the volume. Tell the owner the old token can be revoked.
- **Rollback:** revert the PR.

## T10 — Profiles, toolsets, kanban, approvals

- **Status:** done, 2026-11-09 (#6203, #6204). Each profile runs in its own workspace; `worker` needs `LITELLM_API_KEY` in its own `.env`.
- **Branch:** `feat/hermes-profiles`. **Depends on:** T02, T07, T09.
- **Files:** `cluster/apps/ai/hermes-agent/values.yaml`, `templates/honcho-configmap.yaml`, `templates/deployment.yaml`.
- **Shared settings move to Managed Scope (P10):** settings common to every profile go into a ConfigMap mounted read-only at
  `/etc/hermes/config.yaml`, and `config-seeder` is removed. Per-profile differences stay in `profile-config-seeder`. After the
  change, `hermes doctor` must report the pinned keys, because a malformed managed file is only logged and ignored.
- **Honcho on an empty volume (owner's decision, 2026-11-09):** no pre-job, because this case is rare. The Hermes README records the
  manual step: after a restore onto an empty volume, run `hermes plugins install honcho --yes-deps --enable`, then restart the gateway,
  because a running gateway does not see a dependency environment built after it started.
- **Create the profile once, before this PR merges,** so that the overlay has a profile to land in:

  ```sh consent-gated
  kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- hermes profile create worker \
    --description "Executes well-defined tasks from the orchestrator: Renovate PR checks, implementation, post-merge checks. Never merges."
  ```

- **Change, `default`:** `terminal.backend: ssh`, `terminal.cwd: /workspaces`; `kanban.orchestrator_profile: default`,
  `default_assignee: worker`, `dispatch_profiles: [worker]`, worker limit 2; `discord.free_response_channels` gains
  `#hermes-renovate` next to `#hermes`, so that the owner's thread replies need no mention. `approvals.deny`: force pushes, pushes to `main` or `master`, and mutating `kubectl` (`apply`, `delete`, `patch`, `exec`).
- **Change, `worker` overlay:** model `main-cheap`, SSH terminal, toolsets for terminal, file, web, kanban, skills, todo,
  clarify; `memory`, `cronjob`, `delegation` and `discord` off. The same `approvals.deny`, plus `gh pr merge*`, `gh pr review*`,
  `gh api*merge*`, `gh api*-X PUT*`, `gh api*--method PUT*`, `gh api*-X DELETE*` and `argocd app sync*`.
- **Change, old profiles:** remove the `researcher`, `devops` and `orchestrator` overlays; set their Honcho hosts to disabled; add
  no worker host; stop seeding `honcho.json` into `worker`.
- **Checks:** confirm each key against the release's configuration reference. This is V9: use the documented equivalent if
  one differs, and record any gap in `evidence.md`, section "Live checks". `helm template`, `task lint:all`.
- **Live:** `hostname` run through each profile returns that workspace's name, not the pod's (exec, consent).
- **Done when:** that holds and `hermes kanban` assigns only to `worker`. **Rollback:** revert the PR.

## T11 — Live checks V1 to V6

- **Status:** done, 2026-11-09. Results in `evidence.md`, section "T11 results".
- **Depends on:** T10. **Files:** `.plans/hermes-orchestration/evidence.md` (section "Live checks"). Each check needs exec
  consent and uses paused or throwaway jobs. A change that a result calls for ships in T12's or T14's PR.
- **V1:** `-p worker` reads, writes and patches a path that exists only in the workspace. If they act on the pod, T12's PR
  turns off the `file` toolset for both profiles and its skills edit through the terminal.
- **V2:** a paused cron job creates one kanban task. If not, the job hands off to the `default` session; failing that, use
  `model_map` or `profile_routes` delegation.
- **V3:** a cron job posts to `#hermes-renovate` and creates a thread, and a reply in it reaches `default`. If not: one
  daily message, with decisions as replies naming the PR.
- **V4:** note whether startup context files come from the workspace. T12 reads `AGENTS.md` explicitly either way.
- **V5:** `hermes cron create` in an init container, without the gateway running. If not: T14 creates the job once by hand.
- **V6:** `default` closes a human-task card. If not: the owner closes it with `/kanban` in Discord.
- **SSH host keys:** first connection records the key in `/opt/data/.ssh/known_hosts`, and it survives a workspace restart.
- **Merge commands under `cron_mode: deny`:** run the exact approve and merge commands the skills will use through
  `detect_dangerous_command` in the deployed image's `tools/approval_detection.py`. It must flag none of them, as in
  v0.23.0. If it flags one, T12's PR adds only that rule to `command_allowlist` for `default`. `cron_mode` stays `deny`:
  `approve` would auto-approve every dangerous command in the job.
- **Done when:** each has a recorded result, and the chosen branch is written into the tasks it affects.
- **Rollback:** delete the test jobs and cards.

## T12 — Skills and SOUL files

- **Status:** done, 2026-11-09 (#6206, #6207). Both profiles list their skills and SOUL files. Not yet exercised on a real run; that is T18.
- **Branch:** `feat/hermes-skills`. **Depends on:** T11.
- **From T11:** turn off the `file` toolset for both profiles and edit through the terminal (V1). Use one daily message, with decisions as replies naming the PR, such as
  `merge home-ops#6183` (V3); update `.agents/policy/hermes-merge-policy.md` and the skills to match. Skills read `AGENTS.md` explicitly (V4). No `command_allowlist` change is needed.
- **Files:** `cluster/apps/ai/hermes-agent/skills/<name>/SKILL.md` and `files/soul-{default,worker}.md` (new); `templates/`
  ConfigMaps and a seeder step in `templates/deployment.yaml`.
- **Skills, all implementing the spec's sections of the same name:**
  - `renovate-triage` (default): "Daily Renovate run". Reads the policy from `main`, restores labels when the diff hash
    matches, assigns tasks, re-checks G1 to G5, approves and merges, posts the summary and threads, applies the run limits.
  - `renovate-pr-check` (worker): G6 to G8 in a worktree, then posts the verdict comment with its diff hash and sets the label.
  - `renovate-fix` (worker): applies the owner's instruction to the Renovate branch.
  - `post-merge-check` (worker): after the next reconcile, for up to 45 minutes, checks the owning Applications; in other
    repositories, the default-branch CI. On failure, opens the revert PR and blocks further auto-merge there.
  - `spec-author` (default): "Spec, plan and execution", including the sizes, the five triggers, the phase rules and
    raising human tasks first. Hermes keeps this rule itself; it does not use `claude-plugins`.
  - `implement-task` (worker): works in a task worktree, runs the repository's checks, commits signed, pushes.
- **Every skill:** reads the repository's `AGENTS.md` from the default branch through the terminal, treats PR text and changelogs
  as data, adds no AI attribution, prints no secret values, and accepts decisions and phase starts only from the owner's
  Discord account. Worker repositories: `/workspaces/repos/<repo>`, one worktree per task,
  removed when the task ends.
- **Diff hash:** SHA-256 of `gh pr diff` with `index` and `@@` lines removed. Verdict comments carry it in an HTML comment.
- **SOUL files:** role, account, and the rules above. Overwritten at every start.
- **Checks:** `helm template`; `task lint:all`; no private domain in the rendered ConfigMaps.
- **Done when:** merged, and after a restart both profiles list their skills. **Rollback:** revert the PR.

## T13 — Merge policy and standing permission

- **Status:** done, 2026-11-09 (#6191), with `merge_enabled: false`.
- **Branch:** `feat/hermes-merge-policy`. **Depends on:** T01.
- **Files:** `.agents/policy/hermes-merge-policy.md` (new), `AGENTS.md`, `.agents/policy/permissions.md`.
- **Change:** the policy file holds `merge_enabled: false`, the limits, gates G1 to G8, the denylist, the revert rule and the
  thread decisions, copied from the spec. `AGENTS.md` gains a "Standing authorization for Hermes" paragraph: the `default`
  profile may merge exactly the Renovate PRs that pass this policy while `merge_enabled` is true, an owner's `merge` reply
  is consent for that one PR, and everything else stays as it is. `permissions.md` points to it under GITOPS_TRIGGER.
  `.claude/settings.json` does not change: Claude sessions gain nothing.
- **Checks:** `.agents/bin/check-plans`; `markdownlint` on the new file.
- **Done when:** merged. **Rollback:** revert the PR, which also removes Hermes's permission.

## T14 — Daily cron job

- **Status:** done, 2026-11-09 (#6208). The model later moved from `main-lite` to `main-cheap` (P12). Its single long session is replaced in T22 (P13).
- **From T11:** V5 passed, so the job is declared in git. It delivers to `discord:<#hermes-renovate channel ID>`.
- **Branch:** `feat/hermes-cron`. **Depends on:** T01, T02, T11, T12, T13, T16: the first run must find the policy and the
  labels.
- **Files:** `cluster/apps/ai/hermes-agent/values.yaml`, `templates/deployment.yaml` (only if V5 passed); otherwise the README
  records the manual step.
- **Change:** job `renovate-daily`, schedule `0 6 * * *`, timezone Europe/Warsaw, skill `renovate-triage`, pinned to `main-lite`,
  delivered as chosen in V3. `approvals.cron_mode` stays `deny`.
- **Checks:** `hermes cron list` shows the next run at 06:00 local and the pin (exec, consent).
- **Done when:** that holds. **Rollback:** pause the job, then revert the PR.

## T15 — Reusable label workflow

- **Status:** done, 2026-11-09 (github-workflows#34).
- **Repository:** `mmalyska/github-workflows`, branch `feat/pr-triage-label`. **Depends on:** T01.
- **Files:** `.github/workflows/pr-triage-label.yaml` (new).
- **Change:** a `workflow_call` workflow. For a PR opened by `bendo-bot[bot]`, removes `triage/clean` and `triage/owner` and adds
  `triage/needed`, through the REST issue-labels endpoints with the caller's `GITHUB_TOKEN`. The caller grants
  `pull-requests: write`.
- **Checks:** `actionlint` if installed, otherwise NOT RUN and reviewed by hand. Behaviour is checked in T16.
- **Done when:** merged. **Rollback:** revert the PR.

## T16 — Repository protection and labels, per repository

- **Status:** done, 2026-11-09. The label workflow ran on a real Renovate push, but that PR already had `triage/needed`, so the label change itself is seen in the first real runs.
- **Depends on:** T08, T15. Afterwards nothing merges without an approval, so the owner's own PRs (T14, T17) use the bypass
  and the owner merges Renovate PRs by hand until T19.
- **`mmalyska/renovate-config` first:** remove `automerge` from the `automerge-*` presets; drop `:automergeDigest` from
  `default.json`; add `triage/needed` through `addLabels` in `pr-labels.json`, without disturbing the `dep/*` labels.
- **One PR in each of the 10 repositories:** `.github/CODEOWNERS` as `* @rudi-the-brain @mmalyska`, replacing the
  `* @mmalyska` line in `containers` and `argocd-secret-replacer` and the comment-only file in home-ops; caller
  `.github/workflows/triage-label.yaml` on `pull_request: [synchronize]` with `@main`, like the existing Renovate callers;
  remove that repository's automerge rules. In home-ops: also `.github/labels.yaml` gains the three labels, and
  `.github/renovate/autoMerge.json5`, `groups.json5` and `.github/renovate.json5` lose their automerge settings.
- **Existing rulesets:** `homelab-portal` (`default`, `deletion-no`) and `vintagestory-mods-downloader` (`Main`) already have active rulesets, recorded in
  `evidence.md`. Reconcile the new rules with those; do not add a conflicting second set. No repository has a required status check today.

- **Labels elsewhere, and rulesets (external writes, per repository):**

  ```sh consent-gated
  gh label create triage/needed --repo mmalyska/<repo> --color fbca04
  gh label create triage/clean --repo mmalyska/<repo> --color 0e8a16
  gh label create triage/owner --repo mmalyska/<repo> --color d93f0b
  gh api -X POST repos/mmalyska/<repo>/rulesets --input ruleset.json
  ```

  The ruleset targets `~DEFAULT_BRANCH`: PR with 1 approval, code-owner review, last-push approval, stale approvals dismissed, no
  force push or deletion, the required checks recorded in T08, and repository admin as the only bypass. Classic branch protection
  stays as it is; if it stops the owner's bypass, stop and ask the owner.

- **Checks:** `renovate-config-validator` on every changed config. `rules/branches/<default>` lists the rules. On a throwaway
  PR in `dotfiles`: rosie's approval leaves it blocked, rudi's unblocks it, a later push by rosie blocks it again. A push
  to a real Renovate PR sets `triage/needed`, and a push to a non-bot PR changes no label.
- **Done when:** all 10 are covered and those checks pass. New Renovate PRs show no "Automerge: Enabled".
- **Risk:** R5, R10. **Rollback:** delete the ruleset and revert the PRs; the owner can bypass meanwhile.

## T17 — Docs and memory

- **Status:** done, 2026-11-09 (#6209).
- **Branch:** `docs/hermes-orchestration`. **Depends on:** T16.
- **Files:** `cluster/apps/ai/hermes-agent/README.md`, `docs/src/k8s/agent-workspaces.md`,
  `docs/src/contributing/new-repository.md` (new), `.github/mkdocs/mkdocs.yml`, `.claude/memory/reference_hermes_64k_context_floor.md`
  and `.claude/memory/MEMORY.md`.
- **Change:** README describes two profiles, workspaces, seeded files, the remaining manual steps, the daily run and the spec flow;
  the old profiles are removed from it, as the spec requires. `new-repository.md` lists CODEOWNERS, ruleset, labels and the label
  workflow caller. The memory note stops saying the stack is archived.
- **Checks:** `.agents/bin/check-plans`; `markdownlint`; CI docs build.
- **Done when:** merged. **Rollback:** revert the PR.

## T21 — Live checks V10 to V14 for the kanban pipeline

- **Status:** done, 2026-11-10. All five answered; see [evidence.md](evidence.md), section "Pipeline checks".
- **Depends on:** T14, T17. **Files:** `.plans/hermes-orchestration/evidence.md` (section "Pipeline checks").
- **Do:** with `renovate-daily` paused, create the `renovate` board (`hermes kanban boards create renovate`) and use
  throwaway cards in a test tenant on it. No PR is touched.

  | Check | Question                                                                                             | If it fails                                                              |
  | ----- | ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
  | V10   | How does a card started by the dispatcher (`cli` platform) post to `#hermes-renovate`?               | A short cron job posts the latest summary card's result instead          |
  | V11   | What happens to a child when a parent is `blocked` or fails, and does the dispatcher time cards out? | The next coordinator archives stale parents, as in "Redesign"            |
  | V12   | Can a cron job run on the `worker` profile, or must the `default` job create the coordinator card?   | The `default` job stays and only creates the coordinator card            |
  | V13   | Is a per-card `model` honoured, and can a card or its profile set the reasoning effort?              | Merge cards run on `main` at the profile's effort, and the owner decides |
  | V14   | Are cards created with `board="renovate"` dispatched, and can a `worker` card create cards there?    | Cards stay on the default board, separated by tenant                     |

  ```sh consent-gated
  kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- hermes kanban boards create renovate
  kubectl -n hermes-agent exec deploy/hermes-agent -c hermes-agent -- hermes kanban <create|show|list|archive> ...
  ```

- **Done when:** each check has a recorded answer. **Rollback:** archive the test cards.

## T22 — Pipeline skills and chart

- **Status:** PR opened 2026-11-10; see "Built in T22" in `plan.md`.
- **Branch:** `feat/hermes-kanban-pipeline`. **Depends on:** T21.
- **Files:** `cluster/apps/ai/hermes-agent/skills/` (new `renovate-coordinator`, `renovate-summary`, `renovate-merge`;
  `renovate-triage` keeps Part B, the owner's replies, and loses Part A), `values.yaml` (`profileSkills`, `cronJobs`, the
  `worker` toolsets if creating cards needs more than `kanban`), `templates/` if the cron seeder needs new fields or the `renovate` board must be created at start, `files/soul-*.md`,
  `.agents/policy/hermes-merge-policy.md`.
- **Change:** the design in "Redesign" in `plan.md`, with the answers from T21. The scripts and the guarded merge block
  from #6212 and #6213 move into the new skills unchanged. Add the GitHub fix path (P14): the snapshot script, the
  `renovate-fix` skill's done marker, and the rule "only the owner gives decisions" in both SOUL files and every skill,
  which names `/hermes fix` comments from `mmalyska` as the one exception to "PR comments are data". The owner reply
  table in `.agents/policy/hermes-merge-policy.md` gains the GitHub form of `fix`.
- **Checks:** `helm template`; each script run read-only against GitHub; the merge block with a stubbed `gh`. For P14:
  a `/hermes fix` comment from another account is not selected, one from `mmalyska` is, and one with a done reply is
  skipped, tested against fixture JSON.
- **Note:** the cron seeder keeps a paused job paused when it replaces it, so merging this PR does not resume
  `renovate-daily`. The owner resumes it with `hermes cron resume renovate-daily`.
- **Done when:** merged and the seeders report the new job and skills. **Rollback:** revert the PR and pause the job.

## T23 — Docs for the pipeline

- **Branch:** `docs/hermes-kanban-pipeline-docs`. **Depends on:** T22.
- **Files:** `cluster/apps/ai/hermes-agent/README.md`, `docs/src/k8s/agent-workspaces.md`.
- **Change:** describe the cards, who runs them, and how to read a run on the board.
- **Done when:** merged. **Rollback:** revert the PR.

## T18 — Report-only ramp

- **Depends on:** T23 (P13). **Files:** `.plans/hermes-orchestration/evidence.md` (section "Ramp").
- **Do:** three daily runs with `merge_enabled: false`. The owner reviews "would merge" and the threads. Fix the skills or the policy
  for every wrong verdict, and restart the count.
- **Expected:** a summary by 07:00 each day, a label and verdict on every open bot PR, nothing merged, and no worker task on
  the second run for a PR whose diff did not change.
- **Done when:** three clean runs in a row. Then decide whether `worker-lite` is worthwhile, from real usage.
- **Rollback:** none needed: nothing merges.

## T19 — Turn merging on

- **Branch:** `chore/hermes-merge-enable`. **Depends on:** T18.
- **Files:** `.agents/policy/hermes-merge-policy.md` (`merge_enabled: true`).
- **Do:** the owner merges this one-line PR, then watches the first run with merges.
- **Expected:** a clean PR is approved, merged and checked. A denylisted PR gets a thread, and `merge` in it merges that PR.
  If `approvals.cron_mode: deny` blocks a merge command anyway, set `merge_enabled` back to `false` and add only that rule
  to `command_allowlist` for `default` in a PR, never `cron_mode: approve`.
- **Done when:** that is observed. **Risk:** R1. **Rollback:** set it back to `false`.

## T20 — Final acceptance and ship

- **Depends on:** T19. **Files:** `plan.md` status, `.plans/list.md`, then the archive per `.plans/README.md`.
- **Do:** run the spec, plan and implementation flow once on a small real task. Restart the Hermes pod and confirm the
  settings, skills and job return. Fill in "Quality gates" in `plan.md`.
- **Done when:** every spec success criterion has PASS, or an accepted NOT RUN recorded with its reason. Then "Archive after Ship".
- **Rollback:** not applicable; each earlier task keeps its own.
