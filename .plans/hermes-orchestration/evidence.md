# Evidence: hermes-orchestration

Collected 2026-11-06 by read-only checks (repository, `kubectl get/logs`, `gh` reads, Docker Hub, Hermes docs). No `exec` was run, so nothing here comes from inside the Hermes pod.

## Repository and cluster

- `cluster/apps/ai/hermes-agent` is enabled. It was restored on 2026-10-26 (#5936) after the archive of 2026-10-21 (#5784). Image `nousresearch/hermes-agent:v2026.9.24`.
- Pod `hermes-agent` runs on mc3, 2/2 Ready. PVC `hermes-agent-data` is 5Gi and 10 days old. Boot log: `reconcile: profile=default prior_state=running action=started`, and no other profile. Discord slash-command sync timed out once (a rate limit, retried).
- `agent-workspaces`: there are no resources in the namespace. `allowedBwsRefs` holds `HERMES_MAIN_GITHUB_TOKEN` and `HERMES_WORKER_GITHUB_TOKEN` (#6119). The template took an optional token and dropped the dotfiles bootstrap in #6121.
- The template `main.tf` writes no git configuration. The signing key is loaded into an ssh-agent at `/run/signing/agent.sock`, and `GITHUB_TOKEN` comes in through the `-env` ExternalSecret.
- The workspace ClusterRole `agent-workspaces-reader` includes `argoproj.io` and no Secrets. It is bound to every ServiceAccount in the namespace.
- The local `coder` CLI is not logged in, so `coder list` could not be read.

## GitHub

- Renovate bot: `app/bendo-bot`. Open bot PRs: home-ops 11, containers 3 (one with failing checks), homelab-portal 12 (most are majors, the oldest from 2026-06-30).
- Accounts: `rudi-the-brain` (created 2026-11-06 09:44 UTC), `agent-rosie` (created 2026-11-06 09:20 UTC). PR #6133 (rudi as code owner) was closed by the owner.
- `homeinfra` was archived by the owner on 2026-11-06. No non-archived repository is private (`gh repo list`, 2026-11-06).
- The owner's devcontainer token cannot read branch protection details (HTTP 403), but `GET repos/<repo>/rulesets` and `GET repos/<repo>/rules/branches/main` both answer it (0 rules on 2026-11-08). `main` has classic branch protection.
- Fine-grained PATs cannot reach repositories where the account is only a collaborator, and pushing or merging changes to workflow files needs the `workflow` scope. Both come from general GitHub knowledge, not from a check run here (spec V8).
- `.github/labels.yaml` is synced with `delete-other-labels: true`, so a label missing from that file is deleted on the next sync. `meta-enforce-labels` bans only `do-not-merge`.
- `.agents/bin/check-plans` accepts a folder holding only `spec.md` (#6175). The first plan draft for this work is in git history at commit `e403e963`; it predates the spec, and the plan PR reconciles it with the spec.
- Argo CD polls the repository: `timeout.reconciliation` is `1h` in `cluster/apps/core/argocd/patches/argocd-cm.yaml` and live (2026-11-08), with no webhook configured in that app.

## Hermes upstream

- Docker Hub, 2026-11-05: `v0.23.0`, `stable` and `latest`. The GitHub releases list v0.21.7 (2026-10-11) through v0.23.0 (2026-11-05). The CalVer scheme is no longer used. The Renovate rule's `versioning: loose` therefore never proposes an upgrade.
- Changes relevant here (from release-note summaries; to be read in full before the upgrade): v0.22.0 "one backend and one gateway for every profile", v0.22.5 pluggable delegation backends (model map, profile routes), v0.22.6 `hermes cron cancel` and per-job missed-run policy, v0.23.0 the advanced-delegation plugin and stopping a running cron job.

## Hermes docs (hermes-agent.nousresearch.com/docs, read 2026-11-06)

- Profiles: each has its own HERMES_HOME (`config.yaml`, `.env`, SOUL.md, skills, memory, sessions, cron, gateway state). Created with `hermes profile create <name> [--clone] --description "..."`. A profile without a gateway is fine.
- SSH backend: `terminal.backend: ssh`, with the target from env `TERMINAL_SSH_HOST/USER/PORT/KEY`, `TERMINAL_SSH_PERSISTENT`, and `terminal.cwd`. The client uses `BatchMode=yes`, `StrictHostKeyChecking=accept-new`, ControlMaster `auto` and `ControlPersist=300`. `~/.hermes` is synced to the remote. **Whether file tools and `execute_code` run on the SSH host is not documented** (spec V1).
- Approvals: `approvals.mode` smart|manual|off, `approvals.deny` fnmatch globs (applied before yolo and on every backend), `cron_mode` and `unattended_mode` default `deny`, buttons on Discord. Dangerous-command checks are skipped only on container backends, not on ssh.
- GitHub: there is no toolset. The bundled `github` skill uses the `gh` CLI in the terminal environment, with `GITHUB_TOKEN`/`GH_TOKEN`.
- Kanban: SQLite board; `kanban_create` with `parents`; states `triage|todo|ready|running|blocked|review|done|archived`; `kanban_block` with kind `needs_input`; the dispatcher runs in the gateway (`dispatch_in_gateway`, `dispatch_interval_seconds`, `dispatch_profiles`, `failure_limit`). `orchestrator_profile`, `default_assignee`, `max_in_progress_per_profile` and `notify_in_gateway` come from summaries only (spec V9).
- Cron: jobs are in `<home>/cron/jobs.json` per profile, not in `config.yaml`. They are created with `hermes cron create`. Delivery `origin|local|<platform>:<target>`, Discord home channel `DISCORD_HOME_CHANNEL`. Whether a cron session can use kanban is not documented (spec V2).
- Delegation: `delegate_task`. Routing to another profile works only through the advanced-delegation plugin (`delegation.backend: profile_routes`).

## Added 2026-11-08 (Hermes docs and source)

- Context files: `AGENTS.md`, `CLAUDE.md` and similar are loaded from the working directory, with progressive discovery in subdirectories. `agent/subdirectory_hints.py` uses local `Path` calls on the Hermes host and no terminal-backend call, so it does not see a repository that exists only in an SSH workspace. The startup loader was not read in full, so its behaviour over SSH is inferred (spec V4).
- Discord: one bot can list many channels. Per-channel settings include `discord.free_response_channels`, `discord.channel_prompts`, `discord.ignored_channels` and `DISCORD_ALLOWED_CHANNELS`. Cron delivery is documented as `discord` (home channel) and `discord:#name`. Delivery by channel ID or to a thread is not documented (spec V3).
- Webhooks: a GitHub webhook can trigger a run, but port 8644 must be reachable from the sender.
- Kanban human tasks: creating a card directly as blocked is not documented; `hermes kanban block <id>` after creation is. `kanban_unblock` is an orchestrator tool. Whether the orchestrator can complete a card for a person is not documented (spec V6).

## Added 2026-11-08 (Renovate docs, version 44.222.4)

- Labels: "Renovate will keep PR labels in sync with configured labels, provided that no other user or bot has made changes to the labels after PR creation. If labels are changed by any other account, Renovate will stop making further changes."
- `rebaseWhen: auto` uses `behind-base-branch` only if automerge is on or the repository requires up-to-date PRs; otherwise `conflicted`.
- A commit by another author marks the PR as modified: "Renovate won't perform any further commits".
- Closing a PR with a unique version makes Renovate ignore that version; for a major, the whole major line. A grouped PR without a unique version is not safely ignorable.

## Added 2026-11-08 (models and routing)

- OpenAI model table, input / output per MTok: Astra $10 / $50, 6.1 Sol $2 / $10, 6.1 Terra $1 / $5, 6 Luna $0.10 / $0.50. The Codex pages list all four. How much of a subscription's limits each uses is not published, and availability varies by plan and client (spec V7).
- Hermes: a model per profile, per scheduled job (`hermes cron create/edit --model`, a pin the agent cannot change), `/model` in Discord, and `delegation.backend: model_map` where the orchestrator picks by description, with children running as the parent profile. Kanban per-task overrides are documented only for CLI and dashboard use. Automatic routing by complexity is not documented.

## T01 prerequisites (2026-11-09)

- Repositories: `gh repo list` shows 10 non-archived non-fork repositories (home-ops, containers, dotfiles, claude-plugins, homelab-portal, argocd-secret-replacer, github-workflows, renovate-config, vintagestory-mods-downloader, helm-charts).
  The plan's earlier count of 12 was wrong; the owner confirmed 10.
- Invitations: `rudi-the-brain` and `agent-rosie` are collaborators with write access on all 10 (`collaborators/<user>` answers 204).
- Tokens: the owner ran the check and it printed the login and scopes only. `HERMES_MAIN_GITHUB_TOKEN` is `rudi-the-brain`, `HERMES_WORKER_GITHUB_TOKEN` is `agent-rosie`, both classic with `repo` and `workflow`.
- Bitwarden: the four key items exist and hold passphrase-free OpenSSH private keys. The private halves of the signing keys match the keys on each GitHub account.
  The public halves are not stored there: signing keys are on GitHub, and workspace public keys become the `authorized_key` parameter in T07.
- **An OpenSSH private key stored in Bitwarden must end with a newline.** Without it, `ssh-keygen` and `ssh-add` fail with "error in libcrypto". All four values needed this fix.
- Discord: the owner created `#hermes-renovate` and confirmed that the bot can post and create threads there, and that the channel in `discord.free_response_channels` is `#hermes`.
- `coder` CLI: logged in on the devcontainer, where T07 runs.

## To be filled in during Build

Live checks V1 to V9, upgrade notes, each repository's merge requirements, and the results of the report-only runs.
