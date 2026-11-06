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
- Accounts: `rudi-the-brain` (created 2026-11-06 09:44 UTC), `agent-rosie` (created 2026-11-06 09:20 UTC). PR #6133 adds `* @rudi-the-brain` to CODEOWNERS and is open.
- The owner's devcontainer token cannot read rulesets or branch protection (HTTP 403). T6 reads them with the main token.
- Fine-grained PATs cannot reach repositories where the account is only a collaborator, and pushing or merging changes to workflow files needs the `workflow` scope. Both come from general GitHub knowledge, not from a check run here; T6 verifies them.

## Hermes upstream

- Docker Hub, 2026-11-05: `v0.23.0`, `stable` and `latest`. The GitHub releases list v0.21.7 (2026-10-11) through v0.23.0 (2026-11-05). The CalVer scheme is no longer used. The Renovate rule's `versioning: loose` therefore never proposes an upgrade.
- Changes relevant here (from release-note summaries; T4 reads them in full): v0.22.0 "one backend and one gateway for every profile", v0.22.5 pluggable delegation backends (model map, profile routes), v0.22.6 `hermes cron cancel` and per-job missed-run policy, v0.23.0 the advanced-delegation plugin and stopping a running cron job.

## Hermes docs (hermes-agent.nousresearch.com/docs, read 2026-11-06)

- Profiles: each has its own HERMES_HOME (`config.yaml`, `.env`, SOUL.md, skills, memory, sessions, cron, gateway state). Created with `hermes profile create <name> [--clone] --description "..."`. A profile without a gateway is fine.
- SSH backend: `terminal.backend: ssh`, with the target from env `TERMINAL_SSH_HOST/USER/PORT/KEY`, `TERMINAL_SSH_PERSISTENT`, and `terminal.cwd`. The client uses `BatchMode=yes`, `StrictHostKeyChecking=accept-new`, ControlMaster `auto` and `ControlPersist=300`. `~/.hermes` is synced to the remote. **Whether file tools and `execute_code` run on the SSH host is not documented** (spike S1).
- Approvals: `approvals.mode` smart|manual|off, `approvals.deny` fnmatch globs (applied before yolo and on every backend), `cron_mode` and `unattended_mode` default `deny`, buttons on Discord. Dangerous-command checks are skipped only on container backends, not on ssh.
- GitHub: there is no toolset. The bundled `github` skill uses the `gh` CLI in the terminal environment, with `GITHUB_TOKEN`/`GH_TOKEN`.
- Kanban: SQLite board; `kanban_create` with `parents`; states `triage|todo|ready|running|blocked|review|done|archived`; `kanban_block` with kind `needs_input`; the dispatcher runs in the gateway (`dispatch_in_gateway`, `dispatch_interval_seconds`, `dispatch_profiles`, `failure_limit`). `orchestrator_profile`, `default_assignee`, `max_in_progress_per_profile` and `notify_in_gateway` come from summaries only; T8 confirms them.
- Cron: jobs are in `<home>/cron/jobs.json` per profile, not in `config.yaml`. They are created with `hermes cron create`. Delivery `origin|local|<platform>:<target>`, Discord home channel `DISCORD_HOME_CHANNEL`. Whether a cron session can use kanban is not documented (spike S2).
- Delegation: `delegate_task`. Routing to another profile works only through the advanced-delegation plugin (`delegation.backend: profile_routes`).

## Spikes

(T9 fills this in.)

## Upgrade notes

(T4 fills this in.)

## Merge requirements

(T6 fills this in.)

## Ramp

(T14 fills this in.)
