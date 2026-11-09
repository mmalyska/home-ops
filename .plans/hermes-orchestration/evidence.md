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

## Upgrade notes

Written for task T04 on 2026-11-09. Sources: the GitHub release notes of `NousResearch/hermes-agent` for every release after `v2026.9.24` (v0.21.6, v0.21.7, v0.22.0 to v0.22.7, v0.23.0), the Docker Hub tag list, and the Dockerfile, `docker/` scripts, `pm/` and `hermes_cli/` sources at both tags. All of it is untrusted text and was only read, not followed. The image was not run or inspected (no container runtime here), so everything below about image contents comes from source at the tags.

### Target

- Latest `v0.x` tag on 2026-11-09: `v0.23.0` (released 2026-11-05). The digest is the multi-arch index digest of Docker Hub tag `v0.23.0` (`stable` and `latest` point at the same digest); it was pinned in `cluster/apps/ai/hermes-agent/values.yaml` as `v0.23.0@sha256:adb7890916de63245523492be8f68f9d2095fecbec4e2a6dab7960381f0fc002`.
- The previous pin `v2026.9.24` is the same release as GitHub's "v0.21.5 (v2026.9.24)". The scheme changed with v0.21.6 (2026-10-08): CalVer tags stopped and SemVer `vX.Y.Z` began. Docker tags `v0.22.x` and `v0.23.0` also exist, plus `-desktop` variants that this chart does not use.
- The release notes for v0.21.6 to v0.22.7 are short roll-ups; their full curated notes ship in v0.22.0 and v0.23.0, which were read in full for upgrade notes, breaking changes, gateway, session, plugin, Docker, config and security sections.

### Changes that affect this chart

- **`uv` is no longer on the image PATH (v0.22.0 Docker rework; verified in the v0.23.0 Dockerfile).** The old image copied `/usr/local/bin/uv`. The new one stages uv inside the package manager store (`/opt/hermes/tools`) and symlinks only `python3`, `node`, `npm`, `npx`, `ffmpeg`, `ffprobe` and `rg` into `/usr/local/bin`. The upstream `pm/AGENTS.md` says: "Do not mutate Hermes environments with raw pip or uv" and "Callers receive an interpreter or tool path, not uv". The chart's `postStart` runs `VIRTUAL_ENV=/opt/hermes/.venv uv pip install honcho-ai piper-tts`. If `uv` is missing it exits 127, and a failed `postStart` hook makes Kubernetes kill the container, which would crash-loop the pod. This was not confirmed on the running image. Left unchanged, see decisions below.
- **The venv is sealed and `/opt/hermes` is root-owned and read-only by design.** Upstream: on-demand dependencies go to package-manager "generations" under `/opt/data/installs`, "the sealed /opt/hermes/.venv is never written". `HERMES_DISABLE_LAZY_INSTALLS` and `HERMES_LAZY_INSTALL_TARGET=/opt/data/lazy-packages` from the old image are gone. A raw `uv pip install` into the venv is therefore at odds with the new design even if `uv` were found.
- **Honcho left core and is now a catalog plugin (v0.22.0).** Upstream: "Existing users are migrated on update or first start, with data intact" (`hermes_cli/memory_provider_migration.py`). It installs the catalog entry `honcho` (version 1.1.0, pinned to a reviewed commit in `plastic-labs/honcho`) under `HERMES_HOME/plugins/honcho` when `memory.provider: honcho` is configured and the provider cannot be found, and the plugin brings its own dependencies. Same provider name, same settings, same `honcho.json` read path and tool names. The install needs network access to GitHub from the pod; on failure it retries with backoff (1 hour doubling up to 7 days) and reports it in chat and logs. If the migration fails the provider stays missing, which means no memory. The `honcho-seeder` init container and the `honcho.json` it writes are still the documented configuration, so they need no change.
- **`piper-tts` is still not baked into the image or in the lazy-dependency list.** The TTS tool still says to select Piper under `hermes tools`. Whether the new design installs it on first use was not determined.
- **One gateway serves every profile (v0.22.0, default).** `hermes update` folds per-profile gateways into the default multiplexed gateway "when nothing conflicts"; `gateway.standalone: true` is a temporary opt-out; `gateway.multiplex_profile_allowlist` was removed (config step 42 to 43). The image adds an s6 service `profile-gateways`. The `gateway run --replace` args and the `HERMES_DASHBOARD`, `HERMES_DASHBOARD_HOST`, `HERMES_DASHBOARD_PORT` variables are unchanged in the scripts at v0.23.0 (`--replace` still exists in the CLI; the dashboard run script still reads those variables). `HERMES_DASHBOARD_TUI` was not found in the scripts read; it is harmless if unused. In v0.23.0 every local session (CLI, TUI, API, bots, cron) attaches to one gateway per profile.
- **Config schema 46 to 52.** `_config_version` was 46 at v2026.9.24 and is 52 at v0.23.0. On every container start, `stage2-hook.sh` runs `scripts/docker_config_migrate.py` on `/opt/data/config.yaml`: it copies `config.yaml` and `.env` into `backups/config/` first (label `pre-docker-migrate`), migrates, and restores the copies if the migration fails. Steps in range that touch this chart's area: none of the keys the chart sets are renamed or removed. A one-time personality reset (33 to 34) is below the live version and does not apply. All the chart's `auxiliary.*` keys (including `kanban_decomposer`, `profile_describer`, `triage_specifier`, `skills_hub`, `curator`) and `approvals`, `display.show_cost`, `dashboard.show_token_analytics`, `discord.*`, `memory.provider` and `tts.*` still exist in the v0.23.0 defaults. The live `_config_version` was not read (no exec).
- **Session auto-prune.** v0.22.0 turned `sessions.auto_prune` on by default (ended sessions inactive 90 days deleted at startup). v0.23.0 made it opt-in again. At the target, nothing is pruned unless configured. The chart does not set it.
- **No idle or daily chat reset (v0.22.0).** `session_reset` idle/daily modes are retired; the chart does not set them.
- **Browser tools replaced (v0.23.0).** The ten `browser_*` tools and agent-browser are gone; use `browser_exec`. The chart does not name them.
- **Other v0.23.0 upgrade notes that do not apply here:** `hermes mcp serve` is now `hermes mcp-serve`, the three Office skills merged into `microsoft-office`, the Webapp is off by default, Desktop needs macOS 13+.
- **Tool renames (v0.22.0):** `todo`, `cronjob`, `process` became `todo_list`, `cronjob_manage`, `process_manage`; the old names still work.
- **Security fixes in v0.21.6:** dashboard sign-in hardening (rate limit, body size, loopback-only login codes), git filter hardening, email allowlist. None need a chart change.
- **Image base and size.** Debian 13 base, full Chromium through the package manager, new `tmux`, Office and PDF libraries; `ripgrep` and `ffmpeg` come from pm instead of apt. The image is larger than before (index size about 1.1 GB per arch at the target); the pod memory limit was not re-measured.

### State, migrations and one-way steps (risk R8)

- `docker_config_migrate.py` rewrites `config.yaml` to schema 52 on first start. It keeps a copy in `backups/config/` on the volume. Downgrading is unsupported upstream: `gateway/runtime_downgrade_exit.py` says "Downgrading is unsupported" and `update_downgrade_guard.py` exists. A rollback of the image alone would run an older release against a migrated config.
- The gateway runtime added a `session_admissions` ledger table to the SQLite session store (v0.22.0 and v0.22.1). The state database schema is migrated forward on start. Upstream tests a "genuine SQLite full rollback" but names no supported downgrade path. Treat `state.db` migration as one-way.
- v0.22.2 notes a known issue: sessions that ran under the v0.22.1 gateway cannot be deleted in v0.22.2. v0.22.1 was built from the wrong commit and is not a target here.
- The package manager refreshes dependency "generations" under `/opt/data/installs` on every boot (`refresh_dependencies`) and garbage-collects unused ones. That directory is new on the volume.
- The honcho plugin is installed under `/opt/data/plugins/honcho` on first start (see above). The Honcho server data (in the `honcho` namespace) is not touched.
- Volume layout is otherwise the same: `HERMES_HOME=/opt/data`, `/opt/data/profiles/<name>/` for profiles, `kanban.db` files still handled by the existing `fix-kanban-db-permissions` init container. Container start is still as root under s6 with services running as UID 10000 (`hermes`). Profile directories are chowned to `hermes` on every boot.
- A `volsync` backup exists in this chart (`backup:` in values); the conductor runs the pre-upgrade backup.

### What was adjusted and why

- The image pin in `values.yaml`, and the `postStart` hook is removed. The owner chose removal on 2026-11-09: the hook would very likely crash-loop the pod on v0.23.0. Honcho comes from the catalog plugin; `piper-tts` is not installed (`.plans/TODO.md`).

### What could not be determined

- Whether `uv` is on the PATH of the v0.23.0 image at runtime; the source says it is not.
- Whether `piper-tts` can still be installed into the sealed venv, and how it should be installed in the new design.
- Whether the honcho catalog migration succeeds from the pod network and brings the `honcho-ai` dependency itself.
- Whether the multiplexed-gateway auto migration changes how the three existing worker profiles (researcher, devops, orchestrator) get their Discord bot tokens, and whether any of them share the default profile's token. The chart's `profileOverlays` and `honcho.json` host entries for the profiles were not changed.
- The live `_config_version` and `state.db` schema version, because no command was run in the pod.
- Renovate: `.github/renovate/groups.json5` still describes `v2026.x.x` CalVer tags with `versioning: loose`. Under loose ordering `v2026.9.24` sorts above `v0.23.0`, so Renovate may propose the old CalVer tags as an update. This is for the Renovate task, not this one.

### Rollout on 2026-11-09

- The manual `pre-upgrade` backup was not taken before #6192 merged. The restore point is the scheduled VolSync backup that finished at 12:00:36 UTC, before the merge.
- The first start failed in `config-seeder` with `ModuleNotFoundError: No module named 'yaml'`: on v0.23.0 the system `python3` has no YAML module.
  The main container did not start, so no config or `state.db` migration had run at that point.
- The seeders now use `/opt/hermes/.venv/bin/python` and `hermes_yaml`, the module Hermes itself loads configuration with.
- Upstream's Managed Scope (`website/docs/user-guide/managed-scope.md`) layers a read-only `/etc/hermes/config.yaml` over each profile's configuration. It is global to all profiles and covers only `config.yaml` and `.env`.
- Honcho on v0.23.0: the plugin migration runs when the first agent session starts, not at container start (`recover_at_startup`), so it waited for the first Discord message on 12:43 UTC.
  It installed the plugin and built a dependency environment with `honcho-ai` 2.8.0 under `/opt/data/installs`. The gateway that was already running could not see it (`honcho-ai is required`), and a pod restart fixed that.
- After the restart the environment was still there, and a Discord session created a Honcho session against the self-hosted server with no errors.

## Merge requirements

Collected 2026-11-09 from the `hermes-main` workspace as `rudi-the-brain`. `agent-rosie` lists the same 10 repositories.

| Repository                   | Default | Protected | Required checks | Squash / merge / rebase | Active rules |
| ---------------------------- | ------- | --------- | --------------- | ----------------------- | ------------ |
| argocd-secret-replacer       | main    | yes       | none            | yes / no / no           | 0            |
| claude-plugins               | main    | no        | none            | yes / yes / yes         | 0            |
| containers                   | main    | yes       | none            | yes / yes / yes         | 0            |
| dotfiles                     | main    | no        | none            | yes / yes / yes         | 0            |
| github-workflows             | main    | yes       | none            | yes / yes / yes         | 0            |
| helm-charts                  | main    | no        | none            | yes / yes / yes         | 0            |
| homelab-portal               | main    | yes       | none            | yes / yes / yes         | 5            |
| home-ops                     | main    | yes       | none            | yes / no / no           | 0            |
| renovate-config              | main    | no        | none            | yes / yes / yes         | 0            |
| vintagestory-mods-downloader | master  | yes       | none            | yes / yes / yes         | 6            |

- `argocd-secret-replacer` and `containers` report required status checks with `non_admins` enforcement, but an empty list of checks.
- `homelab-portal`: ruleset `default` has no force push or deletion, PR required, required signatures, merge methods rebase and squash; `deletion-no` blocks deletion.
- `vintagestory-mods-downloader`: ruleset `Main` has no force push, deletion or creation, PR required, required signatures and linear history, so a merge commit would be refused even though the repository setting allows it.
- V8 passed: each account pushed an empty signed commit to `dotfiles` over HTTPS with a classic token, GitHub reported `verified=true`, and the scratch branches were deleted.

## Bitwarden projects

The cluster's only store, `bitwarden`, reads the `cluster` Bitwarden project. An item in any other project answers 404 to External Secrets, even when `bws` in the devcontainer can read it. On 2026-11-09 the six `HERMES_*` items were in `devcontainer`, which broke the Hermes rollout until the owner moved them to `cluster`.
