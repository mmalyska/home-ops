# Hermes Agent — Kubernetes Deployment

Hermes Agent deployed as a single-pod application on the home Kubernetes cluster, managed declaratively via ArgoCD with Bitwarden secrets.

## Architecture

```
┌──────────────────────────────────┐
│               Pod                │
│                                  │
│  ┌──────────┐    ┌───────────┐   │
│  │  nginx   │ →  │  hermes   │   │
│  │  :9119   │    │  :9120    │   │
│  └──────────┘    └─────┬─────┘   │
│       ↑            ┌───┴───┐     │
│  HTTPRoute         │  PVC  │     │
│  (envoy)           │  5Gi  │     │
│                    └───────┘     │
└────────────┬─────────────┬───────┘
             │             │ every model call
             │             ▼
             │   http://litellm.ai.svc.cluster.local:4000/v1
             │   (AI gateway — docs/src/k8s/ai-gateway.md)
             │ memory.provider: honcho
             ▼
   http://honcho.honcho.svc.cluster.local:8000
   (namespace: honcho — see ../honcho/README.md)
```

| Component                      | Purpose                                                                                                                                                   |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **hermes-agent**               | Main process — one multiplexed gateway for both profiles (Discord), kanban dispatcher, scheduled jobs, dashboard                                          |
| **nginx**                      | Reverse proxy in front of hermes-agent; rewrites Host to `127.0.0.1` so hermes gateway loopback guard passes                                              |
| **PVC `hermes-agent-data`**    | Persistent state — config, profile homes, sessions, memory, logs, SSH keys                                                                                |
| **alloy** (sidecar)            | Tails the file logs on the PVC and pushes them to Loki (see Viewing Logs)                                                                                 |
| **emptyDir `/workspaces`**     | Empty read-only stand-in for `terminal.cwd`: the path lives in the Coder workspace, but Hermes also checks it on this host and warns every 2 s            |
| **VolSync**                    | Restic backups of the PVC to S3 (every 6 hours)                                                                                                           |
| **ExternalSecret**             | Discord credentials and the two workspace SSH keys from Bitwarden → K8s Secret (the keys are files, never environment variables)                          |
| **LiteLLMVirtualKey `hermes`** | Team key for the AI gateway; the operator writes it to Secret `hermes-litellm`, the pod reads it as `LITELLM_API_KEY` (no provider key in this namespace) |
| **Honcho**                     | Self-hosted memory server (separate namespace) — provides persistent cross-session user memory via Theory-of-Mind reasoning and vector recall             |

## Helm Values (`values.yaml`)

The declarative configuration lives in `values.yaml` and covers:

- **`hermes.image`** — Container image (`nousresearch/hermes-agent`)
- **`hermes.resources`** — CPU/memory requests and limits
- **`hermes.config`** — Settings shared by every profile (approvals mode, display, timezone, auxiliary models; all through the gateway).
  Rendered to a ConfigMap and mounted read-only as `/etc/hermes/config.yaml` (Hermes Managed Scope, single file by `subPath`; the image keeps other files in `/etc/hermes`).
  A managed value beats every profile for that exact key and a managed list replaces the profile's list, so a key that differs between profiles must not go here.
- **`hermes.profileEnv`**, **`hermes.profileSecretEnv`**, **`hermes.profileSkills`** — Per-profile `.env` keys, secrets copied into a profile's `.env`, and the skills and SOUL file seeded into it.
- **`hermes.profileOverlays`** — Per-profile settings, deep-merged by `profile-config-seeder` on every pod start: `default` into `/opt/data/config.yaml`, any other name into `/opt/data/profiles/<name>/config.yaml`.
- **`externalSecrets`** — Bitwarden secret references for API keys
- **`backup`** — VolSync schedule and retention

Init containers of note, run on every pod start:

1. **`profile-config-seeder`** — deep-merges each overlay in `hermes.profileOverlays` into that profile's `config.yaml` (lists are replaced).
   A missing `/opt/data/config.yaml` is created from the `default` overlay; an overlay for a profile with no directory yet is skipped. Runtime state (sessions, kanban board) survives on the PVC.
2. **`honcho-seeder`** — deep-merges `hermes-agent-honcho` ConfigMap into `/opt/data/honcho.json`, and seeds a copy into profile directories except `worker`, which has no long-term memory.
   Runtime additions made by `hermes honcho sync` are preserved across restarts (deep-merge, not overwrite).

Both the managed file and the overlays carry a checksum annotation on the pod template, so a change restarts the pod.

## HTTPRoute

The dashboard is exposed at `hermes.<private-domain>` via Envoy Gateway (HTTPS). A `cluster-secrets` plugin token resolves the private domain from Bitwarden at ArgoCD sync time.

## Profiles and workspaces

Two profiles run in one pod. Each has its own Coder workspace, reached over SSH, and its own GitHub account. The pod holds no GitHub credential: the tokens exist only inside the workspaces.

| Profile                        | GitHub account   | Role                                                                                                              | Workspace (SSH terminal) | Model        |
| ------------------------------ | ---------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------ | ------------ |
| **default** (`rudi-the-brain`) | `rudi-the-brain` | Chat on Discord, spec notes, plans, orchestration, the daily Renovate run; approves and merges clean Renovate PRs | `hermes-main`            | `main`       |
| **worker** (`agent-rosie`)     | `agent-rosie`    | PR checks, implementation, post-merge checks, revert PRs. Never approves or merges                                | `hermes-worker`          | `main-cheap` |

Terminal commands, `git` and `gh` run in the profile's workspace, not in the Hermes pod. The `file` toolset is off for both profiles, because `write_file` is refused outside `/opt/data`; files are edited through the terminal.
See [Agent workspaces](../../../../docs/src/k8s/agent-workspaces.md) for the workspaces, their SSH keys and git identity.

### One gateway for both profiles

Since Hermes v0.22 one multiplexed gateway serves every profile, and the kanban dispatcher runs inside it. The `worker` profile therefore needs no gateway of its own (no bot token, no `gateway_state.json`).
The container runs `gateway run --replace`, and the dashboard stays on loopback behind nginx.

### What is seeded at every pod start

Nothing a profile needs is set by hand, except creating the `worker` profile once (see below). Init containers restore all of it from git on every start, except skills that Hermes has edited (see the rules below the table):

| What                 | Where it comes from                                                                                              | Where it lands                                                                                                                                                |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared settings      | `hermes.config`, a ConfigMap mounted by `subPath`                                                                | `/etc/hermes/config.yaml` (Managed Scope, read-only, beats every profile for the same key)                                                                    |
| Per-profile settings | `hermes.profileOverlays`, deep-merged by `profile-config-seeder`                                                 | `/opt/data/config.yaml` for `default`, `/opt/data/profiles/<name>/config.yaml` for the others                                                                 |
| Profile `.env` keys  | `hermes.profileEnv` (plain values) and `hermes.profileSecretEnv` (secrets), written by `profile-env-seeder`      | the profile's `.env`: the `TERMINAL_SSH_*` target, `DISCORD_HOME_CHANNEL` (`#hermes`, where Hermes posts its own notices), and `LITELLM_API_KEY` for `worker` |
| Workspace SSH keys   | ExternalSecret items `HERMES_MAIN_WS_SSH_KEY` and `HERMES_WORKER_WS_SSH_KEY`, mounted only into `ssh-key-seeder` | `/opt/data/ssh/hermes-main.key` and `/opt/data/ssh/hermes-worker.key` (mode 600)                                                                              |
| Skills               | `skills/<name>/SKILL.md` and `skills/<name>/references/*`, listed per profile in `hermes.profileSkills`          | `<profile home>/skills/<name>/SKILL.md` and its `references/`                                                                                                 |
| SOUL files           | `files/soul-<profile>.md`                                                                                        | `<profile home>/SOUL.md`                                                                                                                                      |
| Honcho settings      | ConfigMap `hermes-agent-honcho`, merged by `honcho-seeder`                                                       | `honcho.json` of each profile except `worker`                                                                                                                 |

Rules that follow from this:

- Seeders only add or overwrite keys, never delete. To change a value for good, overwrite it explicitly.
- Skills are the exception to "restored from git": a skill file that Hermes edited is kept. The seeder records the sha256 of each file it writes, under `/opt/data/.skill-seed`.
  A copy that still has that hash takes the new git version (`updated from git: <path>`); a copy with any other hash holds Hermes' own edits ("Self-improvement review: Skill …
  patched" in the gateway log, a `patch` row in `/opt/data/skills/.curator_ledger.jsonl`) and is kept (`kept local edits: <path>`). See [Hermes' own skill edits](#hermes-own-skill-edits).
- A non-default profile resolves `${VAR}` in its config from its own `.env`, not from the pod environment. A secret that the profile's config uses must be listed in `hermes.profileSecretEnv` (today
  `LITELLM_API_KEY` for `worker`). `default` and Managed Scope read the pod environment.
- A seeded skill or SOUL file overwrites the copy on the volume, so edit them in `skills/` and `files/`, not in the pod.
- A profile directory that does not exist yet is skipped by every seeder. This is why the `worker` profile has to be created once.
- Changes to the managed file, the overlays or the skills carry a checksum annotation on the pod template and restart the pod.

### Remaining manual steps

1. **Create the `worker` profile once**, after the first deploy onto an empty volume. The next restart seeds it:

   ```bash
   kubectl exec -it deploy/hermes-agent -n hermes-agent -- bash -c \
     'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH" && \
      hermes profile create worker --clone --description "Executes well-defined tasks from the orchestrator"'
   ```

   `--description` matters: the kanban decomposer uses it to route tasks.

2. **Restore Honcho** after a restore onto an empty volume (see [Restoring onto an Empty Volume](#restoring-onto-an-empty-volume)).

### Kanban wiring

Kanban settings live in the `default` overlay: `orchestrator_profile: default`, `default_assignee: worker`, `dispatch_profiles: [worker, default]`, `max_in_progress_per_profile: 2`.
Kanban tools are opt-in per platform: the `default` overlay turns them on for Discord, cron and `cli`, and the `worker` overlay under `platform_toolsets.cli`. Cards started by the dispatcher run on `cli`.
Those cards can show, create and complete cards, but not list or unblock them; that is left to a cron or Discord session.
The Renovate run uses its own board, `renovate`.

Kanban limits found while building the Renovate pipeline (checked on v0.23.0, 2026-11-10; source: `.archive/.plans/hermes-orchestration/evidence.md`, "Pipeline checks"):

- The kanban notifier posts at most about 200 characters of a card's result. For a full result, a cron job with `--no-agent --script` delivers the script's stdout as it
  is, and the script reads the card with `hermes kanban --board <board> show <id> --json` (this is what `renovate-post` does).
- A child card stays in `todo` while its parent is `blocked`, and starts once the parent is archived. `--max-runtime` re-queues a card that runs too long, and
  `kanban.failure_limit` (default 2) blocks it after repeated failures.
- Hermes never archives done cards; `hermes kanban gc` only trims events and logs. `renovate-cleanup` archives done cards of the `renovate` board after 14 days.
- A per-card `--model` is honoured; kanban has no per-card reasoning effort (cron jobs and profiles do).

`kanban.auto_decompose` is off as a workaround for an upstream bug ([NousResearch/hermes-agent#75444](https://github.com/NousResearch/hermes-agent/issues/75444)). A card
that blocks twice in a row for the same reason goes to `triage` for the owner (`block_loop_detected`), but the auto-decomposer takes every `triage` card, rewrites its title
and body and puts it back to `ready`, so it runs and blocks again every one to two minutes. With the setting off, such a card waits in `triage`; read it with
`hermes kanban show <id>`, answer the question and move it on by hand. Remove the setting once the issue is fixed.

`kanban.auto_subscribe_on_create` is on for `default`. A card created from a Discord chat subscribes that chat, thread included, and the cards created from it copy the subscription.
When such a card blocks, finishes, gives up or crashes, Hermes posts a short notice in that thread. Every card of the execution phase of spec-driven work reports back in its spec
thread this way. Cards started by cron or by the dispatcher have no chat, so they post nothing.

Hermes subscribes these chats as `notify+wake`: each notice would also start a full `default` turn (about 60K input tokens), even when the answer is `[SILENT]`. Hermes cannot
limit the wake to some statuses or boards (`_WAKE_KINDS` is a constant in `gateway/kanban_watchers_notifier.py`; checked in v0.23.1 and upstream `main` on 2026-11-16), but each
subscription has its own mode, and a card created with parents copies their subscriptions, mode included. The script-only job `kanban-wake-trim` (every minute,
`files/scripts/kanban-wake-trim.sh`, silent unless it fails) gives every subscription on every board the mode below. It also promotes an `implement-task` card that inherited
`notify` from a human parent card back to `notify+wake`. Subscriptions in mode `wake` and TUI subscriptions are left alone.

| Card                                                             | Notice | Wakes `default`                                                  |
| ---------------------------------------------------------------- | ------ | ---------------------------------------------------------------- |
| Worker card with `implement-task` (spec-driven tasks)            | yes    | on finish (opens the PR) and on block, give-up, crash or timeout |
| Human card (`assignee: default`), created blocked by spec-author | yes    | no; a card created with `initial_status: blocked` never wakes    |
| Any other card, both boards (Renovate merge and fix cards too)   | yes    | no; the notice carries the block reason                          |

A card that finishes within about a minute of its creation, before the job runs, can still wake once; the woken turn starts with `[kanban] Task <id> <status>.` and
`soul-default.md` tells it to reply `[SILENT]` when nothing is needed, which the gateway does not post. To check the modes, run `hermes kanban --board <board> notify-list` in the
pod (`mode=notify+wake` is shown, `notify` is not).

The job checks each subscription once: it keeps the checked keys in `/opt/data/cron/kanban-wake-trim.txt` and reads a card (`kanban show`, read-only) only for a new
subscription. It never runs `kanban list`, which writes to the board (`recompute_ready`). A mode changed by hand after the check stays as it is; delete the key from the file to
check it again. A failed step is retried every run and posted to `#hermes` only on its first failure, once an hour while it still fails, and once when it recovers.
Test the script against a fake `hermes` CLI with `bash cluster/apps/ai/hermes-agent/tests/kanban-wake-trim.test.sh`.

Limits for long waits in a card (read from the v0.23.x source, 2026-11-18): a foreground terminal call is capped at 600 s (`TERMINAL_MAX_FOREGROUND_TIMEOUT`); a longer
`timeout` turns the call into a background process. A card's claim lasts 15 minutes, and every tool result renews it (at most once a minute), so a worker needs no
`kanban_heartbeat` between commands; a run with no heartbeat for 60 minutes is reclaimed as wedged. So a skill that waits polls inside one command of at most 9 minutes
(`post-merge-check` does this) instead of a `sleep` call and a heartbeat per reading, each of which is a model turn that resends the whole context.

Jobs removed from `hermes.cronJobs` stay in Hermes until they are listed in `hermes.retiredCronJobs`, which the cron seeder deletes at start (today `kanban-post`, the earlier
script that posted these notices in `#hermes`).

### Command policy

`approvals.deny` in each overlay holds case-insensitive `fnmatch` globs matched against the whole command and each executable in it.
Both profiles refuse force pushes, pushes to `main` or `master`, and `kubectl apply`, `delete`, `patch` and `exec`. `worker` also refuses `gh pr merge`, `gh pr review`, merge calls through `gh api`,
`PUT` and `DELETE` through `gh api`, and `argocd app sync`.
This is a policy, not a sandbox. A bare `git push` on a branch whose upstream is `main` is not matched; the GitHub ruleset stops it. `default` may run `gh pr review` and `gh pr merge`, because it
approves and merges the PRs the merge policy allows.

Kanban runs and cron jobs have no person to approve a command, so Hermes blocks every command its own detector flags (a heredoc, `python -c`, `rm -r`, an `rm` of an absolute path, `git branch -D`,
`git reset --hard`). `worker` lists those classes by rule key in `command_allowlist` (owner decision 2026-11-17, accepting the risk inside its own workspace); before that they blocked render diffs
and the cleanup of its own worktrees. The keys are the descriptions Hermes prints in the block message. A glob entry would not help: Hermes matches globs only against a command with no `&&`,
`;`, `|` or heredoc. The deny rules and Hermes' hard floor (deleting `/`, a system directory or the home directory, `sudo`) are checked first and still apply. `default` has no allowlist.

## Hermes' own skill edits

Hermes improves its skills as it works, and the owner wants those edits kept. Two pieces make that safe:

- **The seeder keeps them.** `skills-seeder` records the sha256 of each skill file (`SKILL.md` or a file in `references/`) it writes from git, under `/opt/data/.skill-seed`, outside
  the skills directory. At the next start a copy with that hash was not edited and takes the git version, so changes made in git deploy as usual. A copy with another hash holds
  Hermes' edits and is kept, logged as `kept local edits: <path>`. A copy equal to git only records the hash. SOUL files are still written from git at every start.
- **A weekly PR brings them to git.** The job `skill-sync` (Mondays 07:30 Europe/Warsaw, `default`, model `main`) first runs `files/scripts/skill-sync.sh` in the pod. The script compares every
  seeded skill in every profile with its git copy, mounted read-only at `/opt/skills-git`, and prints one patch plus the sha256 each file must have afterwards. No difference prints
  nothing, and Hermes then skips the model run. Otherwise the `skill-sync` skill applies the patch in a `chore/hermes-skill-sync-<date>` worktree of `home-ops`, checks every sha256,
  and opens one PR as `rudi-the-brain` with the label `triage/owner`, then posts the link in `#hermes`. It opens no new PR while one is still open. A run that stops halfway (a rate limit, a refused command) leaves its worktree;
  the next run removes it with `git worktree remove` and recreates the branch with `worktree add -B`, because `rm` on a path and `git branch -D` are refused in cron runs. The
  patch is written to a file before `git apply`: sent on stdin, its text matches the `git *push* +*` deny rule.

The owner reviews the PR. Merging it makes git match Hermes' copies, so nothing is kept at the next start (merging also changes the skills ConfigMap, which restarts the pod).
To reject an edit, the owner closes the PR and tells Hermes in Discord what to undo; Hermes decides how to change its skill.

Limits: a change made in git to a file that Hermes has edited does not reach Hermes until the copies match. The next sync PR then shows Hermes' copy against the new git version, so it
would undo that git change: edit the PR, or tell Hermes about the change and close it.
Different edits of one skill in two profiles, and files other than `SKILL.md` and `references/*`, are listed in the job's output but left out of the patch.

## Daily Renovate run

The run is a chain of short cards on the kanban board `renovate`, so no single session has to hold every step. Both jobs are declared in the chart.

| Step                                      | Runs as                 | Does                                                                                                                      |
| ----------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Job `renovate-daily`, 06:00 Europe/Warsaw | `default`, `main-cheap` | Closes check cards older than the verdict wait, lists auto-merge blocks, creates the coordinator card                     |
| `renovate-coordinator <date>`             | `worker`                | Snapshots open Renovate PRs, sets labels, creates check cards, fix cards for `/hermes fix` comments, and the summary card |
| `renovate-pr-check <repo>#<n>`            | `worker`                | One verdict with evidence: clean, needs the owner, or needs a fix                                                         |
| `renovate-summary <date>`                 | `default`, `main`       | Starts when every check card has finished. Re-checks gates, writes the summary, creates merge cards when merging is on    |
| `renovate-merge <repo>#<n>`               | `default`, `main`       | One PR: re-checks the gates and merges. Cards of one repository are chained, so merges never race                         |
| `post-merge-check <date>`                 | `worker`                | Created with the merge cards and started when they finish: checks every merge, opens a revert PR on a failure             |
| `renovate-merge-report <date>`            | `default`               | After the merges: the report                                                                                              |
| Job `renovate-post`, every 10 minutes     | script only, no model   | Posts each finished summary and merge report to `#hermes-renovate`, once                                                  |
| Job `renovate-cleanup`, 05:30             | script only, no model   | Archives done cards older than 14 days; posts only if it fails                                                            |

The daily run is started by cron, so its cards post no notices; `renovate-post` posts the summaries and merge reports. A card created from an owner's reply in `#hermes-renovate`
(`merge`, `fix`) posts a short notice in that thread when it, or a card created from it, finishes or blocks; `kanban-wake-trim` keeps those notices from waking the agent (see "Kanban wiring"). Start a manual run with
`hermes cron run renovate-daily`, not from a Discord message, or every card of the run reports back in the chat.

A PR whose diff hash still matches the worker's earlier verdict keeps its label and gets no new check. A summary arrives after the last check finishes, so a missing summary by mid-morning
means the run failed or a check is stuck: look at the `renovate` board.

**Merging is on since T19.** The switch is `merge_enabled` in `.agents/policy/hermes-merge-policy.md`. Setting it to `false` in a PR stops every merge, the owner's `merge` replies included, and the summary then says "would merge" instead.
The gates, the denylist and the limits are in that file; this page does not repeat them.

Every PR that waits for the owner is listed in the summary. The owner replies in `#hermes-renovate` and names the PR, for example `merge home-ops#6183`.
A `fix` can also be asked on GitHub: a comment on the PR from the owner's account whose first line is `/hermes fix <what to change>`, picked up by the next run.

| Reply     | Result                                                                               |
| --------- | ------------------------------------------------------------------------------------ |
| `fix`     | The worker pushes the change and re-checks. The PR returns to the owner.             |
| `I merge` | Hermes stops listing it.                                                             |
| `merge`   | A merge card re-checks the PR, approves and merges. The owner's consent for that PR. |
| `reject`  | The PR is closed with a comment, so Renovate ignores that version.                   |
| `resume`  | Lifts the auto-merge block on the named repository after a failed post-merge check.  |

The denylist only stops auto-merge. A `merge` reply from the owner overrides it. A cron job cannot create Discord threads, so decisions are replies in the channel, not per-PR threads.

## Spec, plan and execution

Work is sized when it starts: small (owner's request, then PR), medium (plan PR) or big (spec PR, then plan PR, then implementation PR). Big work goes through three phases, and each starts only on a
message from the owner's Discord account after the earlier PR is merged on the default branch:

1. **Spec.** The owner leads; Hermes asks questions, records decisions and writes `.plans/<slug>/spec.md` in a PR (skill `spec-author`).
2. **Plan.** Hermes builds `plan.md` and `tasks.md` from the merged spec in a PR.
3. **Execution.** Hermes turns the tasks into kanban cards, posts every human task at once and drives the rest through the `worker`. The implementation PR goes to the owner.

**Quick path.** Hermes may propose it for medium or big work of about 200 changed lines or fewer, in one repository, one PR and one session. The work must add no permission,
policy or automation, be nothing hard to undo, and not touch runtime or the cluster (no files whose merge deploys, no live-state step). It starts only on the owner's yes, because it
lowers the size. Hermes writes a single `.plans/<slug>/plan.md` (`profile: QUICK`, at most 80 lines, no `tasks.md`; `check-plans` accepts that) on the implementation branch and
waits for the owner's Discord approval. Then the worker implements on the same branch, and Hermes opens one PR with the plan and the change, its body 25 lines at most. There are
no conditional human cards, and the owner still merges. If the change grows or one of those conditions appears, Hermes stops and returns to the full phases.

### PR gate check

A written rule did not stop PR #6311, which was opened before its verification card had finished. So the `default` profile has a `pre_tool_call` shell hook, `hooks` in its overlay.
The hook runs `files/scripts/pr-gate-check.py --hook` in the pod before every terminal command. The terminal itself runs in the Coder workspace, which has no `hermes` command and no
board, so the check cannot run there.

The script first removes each backslash-newline outside single quotes, as bash does, so `gh pr \` and `create` on the next line are one command. Then it splits the command into
simple commands and tokenizes each like a shell, so quotes are removed. A `gh` command whose non-flag words hold `pr` directly followed by `create` opens a PR,
whatever global flags come first (`gh -R owner/repo pr create`) and however it is quoted (`gh "pr" create`). The hook lets a PR through only from exactly one such command, at the top
level, whose first word is literally `gh` and whose leading assignment is `GATE_CARDS`. That is `GATE_CARDS=none` for spec, plan and skill-sync PRs, or `GATE_CARDS="<worker card id> …"`
for an implementation PR. It refuses:

- `GATE_CARDS` anywhere else (an earlier command, an `export`, a comment, the PR text) or more than once;
- a second PR command;
- `pr create` behind another command word: a variable (`$g pr create`), an alias, `env`, `xargs`;
- a PR command inside `( )`, `$( )`, backticks or a string or here-document run as code (`bash -c`, `python3 -c`, `bash <<EOF`). Code that does not tokenize as shell is searched as raw text for `pr … create`.
  Text read as data is not searched: quoted arguments of `gh`, `git`, `echo` or `printf`, and here-documents read by `cat`, `tee` or `gh`. So PR bodies and skill-sync patches may quote the command;
- every other way to create a PR: `gh api …/pulls` with fields or `POST`, GraphQL `createPullRequest`, `curl …/pulls`;
- a payload it cannot read, a terminal call with no command, and a command it cannot parse.

For each named card the script runs `hermes kanban show <id> --json`. A card passes when it is `done` and its latest comment whose first line is `EVIDENCE` was written by the
`worker` profile, with a `- <check>: PASS` line and no `- <check>: FAIL` line. Kanban records the author from the runtime profile, not from tool arguments, so `default` cannot
write it for the worker. Only the `kanban_comment` tool does that: the `hermes kanban comment --author` CLI could fake an author, but the CLI runs only in the pod and `default`'s
terminal is the Coder workspace, which has no board. The `implement-task` skill tells the worker to write that comment. A crash, a timeout or output that is not JSON refuses the command (fail closed).
`hooks_auto_accept` gives the consent that a gateway cannot ask for.

The block message carries the whole instruction, so Hermes can follow it even while its kept copy of `spec-author` predates the rule.

To run it by hand in the pod: `/opt/data/scripts/pr-gate-check.py <card id> …`. It prints one line per card and exits 1 when one fails. The fixture tests are run with
`bash cluster/apps/ai/hermes-agent/tests/test_pr_gate_check.sh`.

Known bypasses: the hook sees only the text of a terminal command.

- `GATE_CARDS=none` is a claim that the hook cannot verify; the `spec-author` skill decides when it may be used. Checking it against the PR's changed files (allow `none` only when
  every file is under `.plans/` or the Hermes `skills/`) would need GitHub API access from the pod, which has none: the image has no `gh`, and the pod deliberately holds no GitHub
  token (the tokens live only in the workspaces). It would need a read-only token (contents read on the owner's repositories) as a new ExternalSecret item in the pod, `gh` or a
  small HTTP client in the script, and the head branch named in the command (`--head`), since the hook cannot see the workspace's current branch.
- A PR created by a script file that Hermes wrote and then ran, by a program reading `gh pr create` from a file or stdin, or by `execute_code`.
- Any PR-creating call that none of the rules above recognise: another HTTP client or API path, a binary copied under another name, or a command assembled at run time from pieces
  that never spell `pr create`.

The hook config is seeded from git at every start, so the check holds even while Hermes keeps its own edits of `spec-author`.

The design history (archived, not instructions) is in [`.archive/.plans/hermes-orchestration/spec.md`](../../../../.archive/.plans/hermes-orchestration/spec.md) and [`plan.md`](../../../../.archive/.plans/hermes-orchestration/plan.md).
The `default` profile may approve and merge only the Renovate PRs the merge policy allows. Every other PR is merged by the owner, and the repository rules (see [New repository
requirements](../../../../docs/src/contributing/new-repository.md)) enforce that.

### Filesystem Layout Inside the Container

```
/opt/data/                        ← PVC (hermes-agent-data)
├── config.yaml                   ← Default profile config (overlay merged at start)
├── SOUL.md                       ← Seeded from files/soul-default.md
├── .env                          ← Default profile environment
├── ssh/                          ← hermes-main.key, hermes-worker.key (seeded)
├── installs/                     ← Plugin dependency environments (Honcho)
├── plugins/                      ← Catalog plugins (Honcho)
├── profiles/
│   └── worker/
│       ├── config.yaml
│       ├── SOUL.md
│       ├── skills/
│       ├── sessions/
│       └── .env
├── skills/                       ← Default profile skills
├── logs/                         ← agent.log, gateways/<slot>/current (s6-log), … (shipped to Loki)
├── .alloy/                       ← Read positions of the alloy sidecar
└── backups/config/               ← Copies taken before a config migration
```

## Memory (Honcho)

Hermes uses [Honcho](../honcho/README.md) as a persistent memory backend (`memory.provider: honcho` in `config.yaml`). `default` maps to the Honcho host `hermes`. `worker` has no long-term memory and no host.

Hermes' built-in memory files sit in every `default` prompt: `MEMORY.md` (limit `memory_char_limit`, default 2200 characters) and the owner profile `USER.md` (`user_char_limit`, raised to 2750 from
the default 1375 on 2026-11-17 after four refused writes). A write over the limit is refused with the size it would reach; Hermes then has to shorten or remove entries.

### How it works

- After each conversation turn, the Honcho **deriver** extracts user facts and updates the vector store in the background.
- On the next turn, Honcho injects relevant context from past sessions before the model responds.
- The `dialecticCadence` (default: every 2 messages) controls how often deep recall runs; `contextCadence` (default: every message) controls context injection frequency.

### honcho.json

Honcho configuration lives at `/opt/data/.hermes/honcho.json` on the PVC. It is seeded on each pod start by the `honcho-seeder` init container from the `hermes-agent-honcho` ConfigMap. To change Honcho settings (e.g. `dialecticDepth`, `recallMode`), edit `templates/honcho-configmap.yaml` and restart the pod.

### Useful commands

```bash
# Check memory provider status (run in Discord)
# hermes honcho status

# Sync profile host registration with Honcho server
# hermes honcho sync

# Inspect the live honcho.json on the PVC
kubectl exec deploy/hermes-agent -n hermes-agent -c hermes-agent -- \
  cat /opt/data/.hermes/honcho.json
```

### Profile → Honcho host mapping

| Hermes profile | Honcho host key | aiPeer   |
| -------------- | --------------- | -------- |
| default        | `hermes`        | `hermes` |

## Maintenance Tasks

### Viewing Logs

In this image `gateway run` hands the gateway to s6 supervision, so its logs never reach container stdout: Python logging goes to
`/opt/data/logs/agent.log` and its stdout/stderr to s6-log in `/opt/data/logs/gateways/<slot>/current`. Container stdout only carries the
dashboard and the s6 boot lines. The `alloy` sidecar (`templates/alloy-configmap.yaml`) tails the files and pushes them to Loki:

| LogQL                                                                             | What                                                    |
| --------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `{job="hermes-agent/files", filename="/opt/data/logs/agent.log"}`                 | Agent and gateway Python logs, INFO+, tracebacks joined |
| `{job="hermes-agent/files", level=~"WARNING\|ERROR\|CRITICAL"}`                   | What `errors.log` holds (that file is not shipped)      |
| `{job="hermes-agent/files", filename=~".*/gateways/.*/current"}`                  | Gateway process stdout/stderr (crashes, prints)         |
| `{job="hermes-agent/files", profile="worker"}`                                    | Files under `profiles/worker/logs/`                     |
| `{namespace="hermes-agent", container="hermes-agent", job!="hermes-agent/files"}` | Container stdout (dashboard, s6), via alloy-k8s-logs    |

`errors.log` and `gateway.log` are subsets of `agent.log` and are skipped. Positions live on the PVC, so a restart resumes where it stopped; a file seen for the first time is read from
its end.

```bash
# Main agent
kubectl logs deploy/hermes-agent -n hermes-agent -c hermes-agent --tail=100

# s6 boot reconciliation
kubectl exec deploy/hermes-agent -n hermes-agent -- tail -50 /opt/data/logs/container-boot.log

```

### Checking Profiles

```bash
kubectl exec deploy/hermes-agent -n hermes-agent -- hermes profile list
```

### Updating the Image

Edit `values.yaml` → update `hermes.image.tag` → commit → ArgoCD syncs. On start the container migrates `/opt/data/config.yaml` to the new schema and keeps a copy in `backups/config/`. Downgrading is unsupported upstream, so restore from a VolSync backup instead of pinning an older tag.

### Forcing Config Reload

Restart the pod. `profile-config-seeder` re-applies the overlays, and the managed file comes from the ConfigMap (a `subPath` mount does not update in place, which is why changes to it restart the pod):

```bash
kubectl rollout restart deploy/hermes-agent -n hermes-agent
```

### Restoring onto an Empty Volume

After a restore onto an empty volume, Honcho is missing until the plugin and its dependency environment are rebuilt, and a running gateway cannot see a dependency environment built after it started. Run this, then restart the gateway:

```bash
hermes plugins install honcho --yes-deps --enable
```

## Models (through the AI gateway)

Hermes holds no provider key. `model.base_url` is the gateway, `model.api_key` is `${LITELLM_API_KEY}` (the `hermes` team key), and `model.default` is `main` (the ChatGPT/Codex subscription) for `default` and `main-cheap` for `worker` and the `renovate-daily` job. Fallback is the gateway's job (`main` → `or-deepseek-v4-pro` → `or-deepseek-v4.1-flash`, `main-cheap` and `main-lite` → `or-deepseek-v4.1-flash`, all on the OpenRouter budget; an exhausted chain returns an error instead of falling to `local`, see `docs/src/k8s/ai-gateway.md`), so there is no `fallback_providers` block. The team may call `main`, `main-cheap`, `main-lite`, `or-deepseek-v4-pro`, `or-deepseek-v4.1-flash`, `cheap`, `local` and `local-think`.

- `model.context_length` is 200000: `main` has 272K at the gateway, but Hermes cannot see that, and a low value makes compression start far too early. The agent tiers no longer fall back to `local` (131072 per slot); the OpenRouter fallbacks have 1M context.
- Context size (`default`, 2026-11-16 review, TODO item 2): about 70 to 80 % of the input tokens are conversation history, mostly the `#hermes` channel session, which every chat turn and kanban wake replays and which lives until `/new` (v0.23.1 no longer resets gateway sessions on a timer). Hermes floors the compression trigger at 75 % of any window under 512K (150K here), so the overlay sets `compression.threshold_tokens: 100000` (applied after that floor) and `compression.idle_compact_after_seconds: 1800` (compact a session that resumes after 30 minutes before the first reply). The fixed part is small: `hermes prompt-size --platform discord` measured an 18 KB system prompt (SOUL, guidance, a 4.8 KB skills index, 3 KB memory and user profile) and 66 KB of tool schemas in 35 tools, of which `kanban` is 26 KB. `browser`, `connections`, `delegation` and `code_execution` are in `agent.disabled_toolsets` because no seeded skill uses them: 4 tools and 14,979 bytes of schemas in that baseline (`browser_exec` 3,383, `manage_connections` 4,517, `delegate_task` 4,673, `execute_code` 2,406), so Discord goes from 35 to 31 tools and cron from 30 to 26; `tool_search` may already have held some of them back, so the saving on the wire is up to that. `browser` is the static toolset that covers every core `browser_*` tool; `browser_exec` registers under `browser-use`, which would disable only that tool. The 30 to 40 % saving on chat and wake input from the compression settings is an estimate from 2026-11-16 traffic, not a measurement. Measure again with `hermes prompt-size --platform <discord|cron|cli> [--json]` (or `hermes -p worker prompt-size …`); `--platform kanban` reports no tools and is not usable.
- Idle compaction is a quality trade-off: after 30 minutes idle it also compresses the `#hermes` chat history of any session above about 20K tokens (the post-compression target, 100K × `target_ratio` 0.2), history that was previously kept word for word until `/new`; each compaction is one summary call on `main-cheap`.
- Compression speed (2026-11-17 review of the docs-build-supply-chain run): on `main` a summary took 150 to 260 s (median 168 s over 35 runs) while the conversation waited, and a compressed `#hermes` session still held 45 to 72K tokens, because the 20 most recent messages (`protect_last_n`) kept large tool results such as a 100K-character `kanban_show`. Against the 100K threshold that meant a compression every few minutes (22 between 09:40 and 11:56). Compression now runs on `main-cheap` and Managed Scope sets `compression.protect_last_n: 10`.
- Prompt caching on `main`/`main-cheap`: Managed Scope declares the gateway under `providers.ai-gateway` with `session_affinity_header: x-litellm-session-id`, so Hermes sends its session key on every call and LiteLLM passes it on as the ChatGPT `session_id` (see the prompt-caching note under "Fallbacks and budget" in `docs/src/k8s/ai-gateway.md`). Without it `main` got 13 to 21 % cache hits. Check with the `cache=` field of the `API call #` lines in `agent.log` (calls without `upstream=` went to the subscription or the Jetson).
- Result of the 2026-11-16 cost changes (measured 2026-11-18, 24 h from LiteLLM counters and `agent.log`, against the 24 h of 2026-11-16 before them): Hermes requests 800 to 617, input tokens 48.5M to 31.8M (about 60K to 52K per request), cache hits on `main` 13 to 84 % and on `main-cheap` 57 to 91 %, no Hermes traffic on the Jetson (1.7M input tokens before), OpenRouter spend about 4.4 to 0.42 USD, tool errors 10 to 3.8 % and refused commands 24 to 3. The day before had far more ChatGPT 429s (401 against 28), so the fallback and spend figures are partly the quieter day. Not yet seen in real traffic at that date: the `or-deepseek-v4-pro` daily cap (it never spent 1.12 USD in a day), compression after #6343 and idle compaction. Source: `.archive/TODO.md`, "Moved 2026-11-18". To measure again use the same queries: `litellm_*_metric_total` by `team` and `requested_model`, `litellm_input_cached_tokens_metric_total` over `litellm_input_tokens_metric_total`, and in Loki `{job="hermes-agent/files"}` the `agent.tool_executor` "returned error"/"BLOCKED" lines and the "context compression started" lines.
- `model.streaming` is `false` in both overlays. LiteLLM `v1.109.1` drops the arguments of parallel tool calls in a streamed response, so Hermes received empty tool calls
  (390 failed calls in 7 days, and the failed run on 2026-11-13). Unstreamed responses arrive intact. Turn streaming back on only after a LiteLLM version passes the test in `.archive/.plans/hermes-orchestration/evidence.md`.
- Auxiliary tasks follow "prefer `main`" (subscription, no budget cap): `web_extract`, `approval`, `mcp`, `kanban_decomposer` and `vision` use `main`; `compression` uses `main-cheap` for speed (see above). `vision` was on `local-think` from 2026-10-29 to 2026-11-13, while nv1 served LFM3-VL-2B; the text-only LFM3-1.7B reads no images. Small background tasks (`title_generation`, `triage_specifier`, `profile_describer`, `curator`, `skills_hub`) stay on `local`, which is free and keeps them off the subscription limits. Nothing in Hermes depends on `cheap` directly, so it can be retired without touching this file.
- **Hermes refuses to build an agent for any model with less than 64,000 tokens of context** (`agent_init._enforce_minimum_context`). `local` is llama-server with `-c 262144 -np 2`: two slots of 131072 tokens (LFM3-1.7B is trained to 262144), so it stays usable as an auxiliary model while a slot stays at or above 64000 (see `.claude/memory/reference_hermes_64k_context_floor.md`). It serves two requests at a time.
- Text-to-speech is off (2026-11-13): there is no `tts` section and both profiles list `tts` in `agent.disabled_toolsets`. Removing the section alone is not enough, because Hermes then falls back to Edge TTS, a cloud service outside the AI gateway. To bring voice back, run an OpenAI-compatible Piper server behind the gateway and point `tts.provider: openai` with `tts.openai.base_url` at the gateway; the Home Assistant Piper speaks only the Wyoming protocol, which Hermes cannot use. Speech-to-text (Speaches) is not restored either.
- `hermes.profileOverlays.<name>` (`default`, `worker`) is deep-merged into that profile's `config.yaml` on every pod start. The seeders **only add or overwrite keys, never delete**: to move a profile to another provider, overwrite `model.provider`, `model.default`, `model.base_url`, `model.api_key` and `model.context_length` explicitly, otherwise a stale value keeps traffic on the old endpoint. `hermes chat -q "ping"` (or `hermes -p <name> chat -q "ping"`) in the pod is the quickest check that an agent can start.
- `${LITELLM_API_KEY}` in `default`'s config and in Managed Scope is expanded from the pod environment; in `worker`'s config it is expanded from the profile's `.env` (see `hermes.profileSecretEnv`). If `hermes chat -q "ping"` reports an authentication error, check that expansion first.
- GPU rules, memory budget and recovery for `local`: see `docs/src/k8s/nv1-jetson.md`.

## Security Notes

- All secrets come from Bitwarden via ExternalSecret — no credentials in git. The ExternalSecret store reads only the `cluster` Bitwarden project, so every `HERMES_*` item must be in that project; an item elsewhere answers 404.
- The pod holds no GitHub token. The workspace SSH keys are mounted only into the `ssh-key-seeder` init container and copied to `/opt/data/ssh/` with mode 600.
- Private keys stored in Bitwarden must end with a newline, or `ssh-keygen` fails with "error in libcrypto".
- `cluster-secrets` plugin resolves `<secret:private-domain>` in HTTPRoute hostname
- gitleaks pre-commit hook blocks accidental secret commits (bws IDs are annotated with `#gitleaks:allow`)
- Dashboard is loopback-only internally; nginx rewrites Host to `127.0.0.1` so the hermes host-header guard passes
