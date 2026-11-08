# Hermes orchestration spec

**Date:** 2026-11-08
**Status:** Draft, for the owner's review in PR #6148. The plan is written after this spec is merged.
**Profile:** DEEP / SOLO. Facts and their sources: [evidence.md](evidence.md).

## Problem

The owner runs about a dozen public repositories alone, and dependency updates pile up: 26 Renovate PRs were open on
2026-11-06, some of them four months old. Reading each changelog takes time, so safe updates wait alongside risky ones.
Larger work needs the owner present for every step, even once it is well defined.

Hermes is deployed but does little of this. It has one effective profile, it runs commands inside its own pod, and its
profiles are hand edits on a volume. The `agent-workspaces` namespace and template built for it have no workspace.

## Users

**Primary:** the repository owner, the only human, working through Discord and GitHub.

**Not for:** other people (nobody else may instruct or approve anything), and Claude or Codex sessions. Those keep their
own rules in `AGENTS.md` and `claude-plugins`. Hermes does not use `claude-plugins`.

## Success criteria

Each is checked on the live system before the work ships.

- [ ] Both workspaces (`hermes-main`, `hermes-worker`) are running and healthy in Coder.
- [ ] A command from each profile runs in that profile's workspace, not in the Hermes pod.
- [ ] Each workspace acts as its own GitHub account, pushes over HTTPS with its token, and its test commit shows "Verified".
- [ ] `agent-rosie` cannot get a PR merged alone: with only her approval, a throwaway PR stays blocked.
- [ ] Three daily runs in a row post a summary by 07:00 Europe/Warsaw, with a label and a verdict on every open bot PR,
      while merging stays off and nothing is merged.
- [ ] Across those three runs, every "would merge" verdict is one the owner agrees with (0 wrong "clean" verdicts).
      A wrong verdict restarts the count after the fix.
- [ ] Merging on: a clean PR is approved, merged and health-checked. A denylisted PR gets a thread with the four choices.
- [ ] A PR that already has a verdict and an unchanged diff causes no worker task on the next run.
- [ ] One real piece of work goes through spec PR, plan PR and implementation PR, starting each phase only on the owner's
      message, with human tasks raised before the work that depends on them.
- [ ] After a pod restart, every setting, skill and scheduled job is back without manual steps, except creating the
      `worker` profile the first time.

## Scope

### Must have

- Two Hermes profiles, each with its own Coder workspace, GitHub account and credentials.
- Chat on Discord.
- Daily Renovate triage with gated auto-merge across all non-archived `mmalyska` repositories.
- PR state labels in every repository.
- Spec, plan and execution flow with owner approval between phases.
- CODEOWNERS and a ruleset in every repository; Renovate's own automerge turned off.
- A written, scoped permission for Hermes to merge in home-ops.
- Hermes upgraded to the current release, and Renovate able to see its new version scheme.

### Out of scope

- Hermes approving spec or plan PRs, merging implementation PRs or running deployments. This is the intended direction
  (see "Future direction"), but not this work.
- Platforms other than Discord. Discord is enough for now.
- Talos access for Hermes. Nothing here needs it, and it is a large increase in reach.
- Any cluster change by Hermes except through a merged PR. Anything else is a human task.
- GitHub webhooks into Hermes. They need an inbound port, and the owner's message is enough.
- Deleting the old Hermes profiles. They are kept, disabled.
- Hermes using `claude-plugins`. Those are written for Claude and Codex. Hermes has its own skills.

## Roles

| Actor                        | Does                                                                                                                      | Never does                       |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------- |
| Owner                        | Leads specs, approves specs and plans, merges everything but clean Renovate PRs, does human tasks                         | -                                |
| `default` / `rudi-the-brain` | Chat, spec notes, plans, orchestration, approves and merges Renovate PRs that are clean or that the owner said `merge` to | Merges any other PR              |
| `worker` / `agent-rosie`     | PR checks, implementation, post-merge checks, revert PRs                                                                  | Approves as a code owner, merges |

## Required behaviour

### Workspaces and identity

- Neither profile runs commands in the Hermes pod. GitHub credentials exist only in the workspaces, not in the pod.
- Git uses HTTPS with the account's token, the same credential as `gh`. There is no SSH authentication key.
  Each account has an SSH signing key, and all its commits are signed.
- Both workspaces have read-only Kubernetes access (no Secrets, no exec). Neither has Talos access.

### Repository rules

Before working in a repository, a profile reads that repository's `AGENTS.md` (and any nested one on the paths it
touches) through its terminal, from the **default branch**. A PR branch could rewrite the file, so a PR's version is
never trusted. Hermes cannot be relied on to load the file by itself over SSH (V4). Repository rules apply on top of this spec, and where
they differ the stricter one wins: a repository that reserves merging for people is never auto-merged.

### PR state labels

Every repository has these labels. They show the state at a glance and tell Hermes what to skip.

| Label           | Meaning                          | Next actor | Set by                                     |
| --------------- | -------------------------------- | ---------- | ------------------------------------------ |
| `triage/needed` | Not checked, or diff has changed | Worker     | Renovate at creation; Hermes on a stale PR |
| `triage/clean`  | Passed every gate                | Hermes     | Worker                                     |
| `triage/owner`  | Waiting for the owner            | Owner      | Worker; Hermes on spec, plan and ready PRs |

- A bot PR with no `triage/*` label is treated as `triage/needed`. This also adopts the PRs open at rollout.
- The worker's verdict comment records a hash of the PR's diff. If the diff changes, the verdict is void and the label
  returns to `triage/needed`. A rebase that leaves the diff unchanged keeps the verdict.
- A label never authorises a merge. The orchestrator re-checks the gates itself first.

### Daily Renovate run

Starts at 06:00 Europe/Warsaw, every day.

1. List open bot PRs (`app/bendo-bot`) in every non-archived `mmalyska` repository.
2. Reset stale labels. Assign the worker one task for each `triage/needed` PR. `triage/owner` PRs get no new work.
3. The worker returns a verdict with evidence: clean, needs the owner, or needs a fix. A check still open after 2 hours
   counts as needing the owner.
4. While merging is on, for each `triage/clean` PR, the orchestrator re-checks gates G1 to G5, approves as
   `rudi-the-brain`, and merges with the repository's allowed method. If a re-check fails, nothing is merged: a changed
   diff (G4) returns the PR to `triage/needed`, pending CI (G3) leaves it for the next run, and any other failure moves
   it to `triage/owner`.
5. Post the summary in `#hermes-renovate`: merged, would merge (while merging is off), waiting for the owner, skipped
   and why, failed checks. A run that finds nothing still posts, so a missing summary means the run failed.
6. Each PR waiting for the owner has one thread with the verdict, the reasons and four choices. A thread never expires,
   and the daily summary keeps listing it.

| Owner's reply | Result                                                                                  |
| ------------- | --------------------------------------------------------------------------------------- |
| `fix`         | The worker pushes the change and re-checks. The PR returns to the owner (G1 now fails). |
| `I merge`     | Hermes stops listing it.                                                                |
| `merge`       | The orchestrator approves and merges. This is the owner's consent for this one PR.      |
| `reject`      | The PR is closed with a comment, so Renovate ignores that version.                      |

Anything else gets a clarifying question.

### Clean gate

A bot PR is clean only if all gates hold. The orchestrator checks G1 to G5 itself. The worker judges G6 to G8 and must
give evidence for each.

- **G1 Author:** opened by `app/bendo-bot` from a `renovate/` branch, not a draft, no `do-not-merge` label, and every
  commit is Renovate's.
- **G2 Not denylisted:** see the denylist below.
- **G3 CI:** every check on the current head has finished as success, skipped or neutral; nothing pending; GitHub
  reports the PR mergeable.
- **G4 Same diff:** the diff at merge time has the hash the worker checked.
- **G5 Protected repository:** the repository has the required ruleset. Without one (for example a new repository), it
  is treated as denylisted, and the summary says so.
- **G6 Diff shape:** only version, tag, digest and chart version lines, and their lock or checksum lines, change.
- **G7 Release notes:** the worker read the notes for every version in between and cites them. Not clean: a breaking
  change, a removed or renamed option this repository uses (checked by searching it), a required migration or manual
  step, an unmet minimum version, or a major whose notes cannot be found. For a major, the verdict names the breaking
  changes listed upstream and says why none applies.
- **G8 Rendered impact (home-ops Helm and Kustomize apps):** rendered output changes only image references, version
  labels and annotations, and checksum annotations. Not clean: CRDs, `volumeClaimTemplates`, PVC specs, Service type or
  ports, RBAC, NetworkPolicies, added or removed resources, security context changes.

Patch, minor, digest and major updates are all eligible.

**Denylist.** In home-ops: `cluster/apps/core/**`, `provision/**`, Talos, kubelet and `tuppr`, the `kubernetes` group,
`cilium` (the chart; `cilium-cli` is allowed), `rook-ceph*`, `cloudnative-pg` and Postgres images used by CNPG clusters,
`argo-cd`, `envoy-gateway`, `cert-manager`, `external-secrets`, `coredns`, Coder workspace templates, Terraform providers
and modules, and Hermes's own stack (`hermes-agent`, `litellm`, `litellm-operator`, `honcho`, `agent-workspaces`, `coder`).
In other repositories: all of `github-workflows` and `renovate-config`, because they change every other repository.
The worker still checks denylisted PRs, so the owner's thread has the full analysis.

**Run limits (home-ops).** At most 5 auto-merges per run, one at a time. After each, the worker waits up to 20 minutes
for the owning ArgoCD Application to be Synced and Healthy. On failure: no more merges in that run, a revert PR is
opened as `agent-rosie`, and the owner is mentioned with the evidence. Hermes does not merge the revert. In other
repositories the check is the default-branch CI run after the merge, with the same response. The same check follows a
merge done on the owner's `merge` reply.

**Rollout.** Merging starts switched off in the policy file. The owner turns it on with a one-line PR after the three
report-only runs in the success criteria.

### Spec, plan and execution

Hermes sizes the work when it starts, says which size it picked and why, and uses its own skill for this.

| Size   | When                 | Documents                            |
| ------ | -------------------- | ------------------------------------ |
| Small  | Not medium or big    | None; the owner's request and the PR |
| Medium | Needs a durable plan | Plan PR, with a Requirements section |
| Big    | Any trigger below    | Spec PR, then plan PR                |

Any one of these makes the work big. Size in lines or files is not a trigger.

1. Requirements are unsettled: it needs owner decisions before "done" can be defined.
2. The behaviour outlives the change: a new automation, agent, scheduled job or service, or a new permission or policy.
3. It crosses boundaries: more than one repository or app, or settings in external services.
4. It is hard to undo: a data migration, credentials, anything destructive, or merges that deploy with nobody watching.
5. It needs more than one PR or more than one session.

The owner can raise the size at any time. Lowering it needs the owner's word. If a trigger appears during the work,
Hermes stops, writes the spec from what is known, and waits for approval. A spec once written stays.

Small work goes straight from the owner's request to an implementation PR, which the owner merges. Medium work starts
at phase 2, from the owner's request. Big work goes through all three phases:

1. **Spec.** The owner leads. Hermes assists: it asks questions, takes notes, records decisions and points out gaps. It
   does not decide. It writes `.plans/<slug>/spec.md` in a PR, which the owner reviews and merges.
2. **Plan.** When the owner tells Hermes the spec is approved, Hermes builds `plan.md` and `tasks.md` from the merged
   spec in a PR. The owner verifies and merges it.
3. **Execution.** When the owner tells Hermes the plan is approved, Hermes turns the tasks into kanban cards and drives
   them through the worker. The implementation PR goes to the owner, who merges it.

Starting the plan or execution phase needs a message from the owner's Discord account, and the spec or plan PR before it
must be merged on the default branch. If it is not merged, Hermes says so and waits. Hermes does not watch for merges
by itself.

**Human tasks and blockers.** `tasks.md` marks every task only a person can do, including any cluster change that is
not a merged PR. When execution starts, Hermes posts all of them at once, so problems surface early. Each one blocks the
tasks that depend on it, and one marked as blocking everything stops the whole work. Anything the worker cannot answer
from the spec or plan goes to the orchestrator, and then to the spec thread if the orchestrator cannot answer it either.

### Models

`default` uses `main` (`chatgpt/gpt-6.1-sol`). `worker` uses a new gateway alias `main-cheap` (`chatgpt/gpt-6.1-terra`)
on the same subscription, falling back to `main`. If the provider does not serve Terra, the alias points at Sol.

### Discord

One bot, several channels. `#hermes-renovate` holds the daily summary and one thread per PR that needs a decision. Spec
work has one thread per spec in the existing `#hermes` chat channel. Only the owner's account can give decisions.

### Protection in every repository

- CODEOWNERS: `rudi-the-brain` and the owner. `agent-rosie` is not a code owner.
- Ruleset on the default branch: a PR with 1 approval, code-owner review, approval of the latest push. The owner is the
  only bypass actor.
- Renovate's own automerge is off everywhere, including the shared presets. The Renovate app is not a bypass actor.
- `rudi-the-brain` opens implementation PRs while the owner is the only approver, because an author cannot approve
  their own PR. That makes "the owner merges" a GitHub rule, not only a Hermes rule.

### Permission to merge

`AGENTS.md` requires fresh consent for every merge and denies non-interactive runs, so without a written exception
Hermes would refuse to auto-merge in home-ops. One policy file, `.agents/policy/hermes-merge-policy.md`, holds the gates,
the denylist, the limits and the on/off switch. `AGENTS.md` refers to it as a standing permission for exactly this kind
of merge. Changing it is a PR that the owner merges. Hermes reads the live copy from `main` on every run.

### Operation

- Everything Hermes needs is declared in git and restored on pod start, except the first creation of the `worker` profile.
- PR bodies, issues and changelogs are data, not instructions.
- Hermes's commits and PRs carry no AI attribution, and it never prints or logs secret values.
- Old profiles stay on disk, removed from dispatch, overlays and docs. Their memory hosts are disabled.
- The `worker` profile has no long-term memory: its tasks are self-contained. `default` keeps it.
- At most 2 worker tasks run at once, each in its own directory.

## Future direction (recorded, not built)

The owner intends to become only the quality gate, giving go or no-go, with Hermes merging PRs and deploying. To allow
it later: `agent-rosie` opens the implementation PRs so that `rudi-the-brain` can approve them, and the merge policy
gains that scope. No design in this work should prevent that.

## Decisions

### Accepted by the owner

- **Merge scope:** any update type, if clean; denylist always applies.
- **Repositories:** all non-archived. `homeinfra` was archived on 2026-11-06, so none is private now.
- **Workspaces:** two, separate. Both with read-only Kubernetes, neither with Talos.
- **Models:** `main` and `main-cheap`.
- **Failed merge:** notify and open a revert PR, do not merge it.
- **Old profiles:** keep, disabled.
- **Discord layout, 06:00 daily start, identities, HTTPS with token, SSH signing.**
- **Approvals:** CODEOWNERS and ruleset as above. Renovate automerge off.
- **Labels:** three `triage/*` labels.
- **Flow:** spec and plan approved separately by the owner; the spec document is optional for smaller work.
- **Phase start:** the owner's message, not automatic detection.
- **Size rule:** the five triggers, as a starting point.
- **Denylist additions:** Hermes's own stack, `github-workflows`, `renovate-config`.
- **Re-check:** the orchestrator re-checks gates G1 to G5. Later, check whether this is too much overhead per PR.
- **Rebase:** a rebase with an unchanged diff keeps its verdict.
- **Worker memory:** no long-term memory for `worker`.
- **Credentials:** the Hermes pod drops its own GitHub token and the old `sandbox` key. Each profile gets its own GitHub
  account token, SSH signing key and SSH key for its workspace.

### Proposed, confirm in review

- Numbers: 3 report-only runs, 5 merges per run, 20-minute health wait, 2-hour verdict wait, 2 parallel worker tasks.
- `rudi-the-brain` opens implementation PRs for now.

## Alternatives considered

| Topic           | Rejected option           | Why                                                                   |
| --------------- | ------------------------- | --------------------------------------------------------------------- |
| Workspaces      | One shared                | Both tokens in one pod, so the separation is lost                     |
| Workspaces      | Worker only               | The orchestrator needs a checkout to write specs and plans            |
| Git auth        | SSH authentication key    | A second secret per account; the token already works for git and `gh` |
| Approvals       | Both bots as code owners  | Rosie could approve a Renovate PR and then merge it herself           |
| Renovate merges | App as bypass actor       | Those updates would skip Hermes's checks and limits                   |
| Merge scope     | Patch and digest only     | Owner's call: majors are allowed if they pass every gate              |
| Worker model    | `cheap` (Gemini)          | Weaker judgement on changelogs, and it has a per-token cost           |
| Worker model    | `main` (Sol)              | Works, but a lighter model suits well-defined tasks                   |
| Failed merge    | Auto-merge the revert     | Rollback stays the owner's call                                       |
| Old profiles    | Delete                    | Owner's call: keep them                                               |
| Labels          | One `triaged` label       | Cannot show whose move it is                                          |
| Phase start     | Poll for merges           | More machinery, and the owner's message is enough                     |
| Phase start     | GitHub webhook            | Needs an inbound port                                                 |
| Spec location   | GitHub issue, kanban only | Not reviewable as a diff, or not in git at all                        |
| PR structure    | One PR for spec and code  | The owner approves spec and plan separately                           |
| Discord         | DMs, one existing channel | Decisions get mixed together on a busy day                            |
| Schedule        | 18:00, or weekdays only   | Owner's call: early, every day                                        |

## Risks

| #   | Risk                                                                    | Impact | Mitigation and how it is detected                                               |
| --- | ----------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------- |
| R1  | A "clean" update breaks an app, majors especially                       | High   | Gates, denylist, 5-merge limit, health check, revert PR; 3-run ramp             |
| R2  | A changelog or PR body injects instructions                             | High   | Treated as data; gates re-checked; rosie cannot merge alone                     |
| R3  | `rudi-the-brain` merges something it should not                         | High   | Accepted: GitHub cannot limit which PRs rudi may approve. Skill and policy only |
| R4  | Both tokens can write to every repository                               | High   | Accepted: needed to work there. Tokens exist only in their workspaces           |
| R5  | Hermes down means no dependency updates merge                           | Medium | Missing 07:00 summary shows it; the owner can merge or bypass                   |
| R6  | More checks hit subscription limits                                     | Medium | Labels stop repeat checks; gateway falls back; the summary lists failed checks  |
| R7  | The Codex login in a gateway is restricted (gray area, `ai-gateway.md`) | Medium | Accepted already; gateway falls back to `cheap` under its budget                |
| R8  | The upgrade from `v2026.9.24` damages Hermes state                      | Medium | Backup first; release notes read; restore from backup                           |
| R9  | File tools act on the pod, not the workspace                            | Medium | Checked first (V1); fallback is terminal-only editing                           |
| R10 | Backlog during the report-only days                                     | Low    | Three days; the owner merges by hand or bypasses                                |
| R11 | Pushing to a Renovate branch stops Renovate updating it                 | Low    | Accepted: the PR then goes to the owner (G1)                                    |

## Open questions

No decisions are open beyond confirming the "Proposed" list above. These facts cannot be settled on paper and are checked
on the live system during Build. Each has a defined outcome if the answer is no.

| #   | To verify                                                   | If no                                                        |
| --- | ----------------------------------------------------------- | ------------------------------------------------------------ |
| V1  | File tools act on the SSH workspace                         | Turn the `file` toolset off; edit through the terminal       |
| V2  | A scheduled job can create kanban tasks                     | Hand off to the `default` session, or use profile delegation |
| V3  | Scheduled posts can create a thread per PR                  | One daily message; decisions as replies naming the PR        |
| V4  | Startup context files are read from the workspace           | Nothing changes: skills read `AGENTS.md` explicitly anyway   |
| V5  | The scheduled job can be created from git at pod start      | Create it once by hand and document that                     |
| V6  | The orchestrator can close a human-task card for the owner  | The owner closes it with `/kanban` in Discord                |
| V7  | The provider serves `gpt-6.1-terra`                         | The alias points at Sol                                      |
| V8  | Classic tokens with `repo` and `workflow` scopes are enough | Stop and ask the owner                                       |
| V9  | Config keys known only from doc summaries exist in v0.23    | Use the documented equivalent, or record the gap in the plan |

## Technical notes

- **Stack:** Hermes (`nousresearch/hermes-agent`, Kubernetes, ArgoCD), Coder `agent-workspace` template, LiteLLM gateway,
  Honcho memory, GitHub, Discord.
- **Constraints:** `AGENTS.md` permission classes, no secrets in git, every cluster change gated on the owner's consent.
- **Prerequisites from the owner:** account invitations and signing keys, tokens and Bitwarden items, the Discord channel.
  The plan lists them exactly.
