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
- **`hermes.config`** — Settings shared by every profile (approvals mode, display, timezone, TTS, auxiliary models; all through the gateway).
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

Nothing a profile needs is set by hand, except creating the `worker` profile once (see below). Init containers restore all of it from git on every start:

| What                 | Where it comes from                                                                                              | Where it lands                                                                                                |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Shared settings      | `hermes.config`, a ConfigMap mounted by `subPath`                                                                | `/etc/hermes/config.yaml` (Managed Scope, read-only, beats every profile for the same key)                    |
| Per-profile settings | `hermes.profileOverlays`, deep-merged by `profile-config-seeder`                                                 | `/opt/data/config.yaml` for `default`, `/opt/data/profiles/<name>/config.yaml` for the others                 |
| Profile `.env` keys  | `hermes.profileEnv` (plain values) and `hermes.profileSecretEnv` (secrets), written by `profile-env-seeder`      | the profile's `.env`: the `TERMINAL_SSH_*` target, `DISCORD_HOME_CHANNEL`, and `LITELLM_API_KEY` for `worker` |
| Workspace SSH keys   | ExternalSecret items `HERMES_MAIN_WS_SSH_KEY` and `HERMES_WORKER_WS_SSH_KEY`, mounted only into `ssh-key-seeder` | `/opt/data/ssh/hermes-main.key` and `/opt/data/ssh/hermes-worker.key` (mode 600)                              |
| Skills               | `skills/<name>/SKILL.md`, listed per profile in `hermes.profileSkills`                                           | `<profile home>/skills/<name>/SKILL.md`                                                                       |
| SOUL files           | `files/soul-<profile>.md`                                                                                        | `<profile home>/SOUL.md`                                                                                      |
| Honcho settings      | ConfigMap `hermes-agent-honcho`, merged by `honcho-seeder`                                                       | `honcho.json` of each profile except `worker`                                                                 |

Rules that follow from this:

- Seeders only add or overwrite keys, never delete. To change a value for good, overwrite it explicitly.
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

### Command policy

`approvals.deny` in each overlay holds case-insensitive `fnmatch` globs matched against the whole command and each executable in it.
Both profiles refuse force pushes, pushes to `main` or `master`, and `kubectl apply`, `delete`, `patch` and `exec`. `worker` also refuses `gh pr merge`, `gh pr review`, merge calls through `gh api`,
`PUT` and `DELETE` through `gh api`, and `argocd app sync`.
This is a policy, not a sandbox. A bare `git push` on a branch whose upstream is `main` is not matched; the GitHub ruleset stops it. `default` may run `gh pr review` and `gh pr merge`, because it
approves and merges the PRs the merge policy allows.

## Daily Renovate run

The run is a chain of short cards on the kanban board `renovate`, so no single session has to hold every step. Both jobs are declared in the chart.

| Step                                      | Runs as                 | Does                                                                                                                      |
| ----------------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| Job `renovate-daily`, 06:00 Europe/Warsaw | `default`, `main-cheap` | Closes check cards older than the verdict wait, lists auto-merge blocks, creates the coordinator card                     |
| `renovate-coordinator <date>`             | `worker`                | Snapshots open Renovate PRs, sets labels, creates check cards, fix cards for `/hermes fix` comments, and the summary card |
| `renovate-pr-check <repo>#<n>`            | `worker`                | One verdict with evidence: clean, needs the owner, or needs a fix                                                         |
| `renovate-summary <date>`                 | `default`, `main`       | Starts when every check card has finished. Re-checks gates, writes the summary, creates merge cards when merging is on    |
| `renovate-merge <repo>#<n>`               | `default`, `main`       | One PR: re-checks the gates and merges. Cards of one repository are chained, so merges never race                         |
| `renovate-merge-report <date>`            | `default`               | After the merges: the report, and a `post-merge-check` card for the worker                                                |
| Job `renovate-post`, every 10 minutes     | script only, no model   | Posts each finished summary and merge report to `#hermes-renovate`, once                                                  |
| Job `renovate-cleanup`, 05:30             | script only, no model   | Archives done cards older than 14 days; posts only if it fails                                                            |

A PR whose diff hash still matches the worker's earlier verdict keeps its label and gets no new check. A summary arrives after the last check finishes, so a missing summary by mid-morning
means the run failed or a check is stuck: look at the `renovate` board.

**Merging is off until T19.** The switch is `merge_enabled` in `.agents/policy/hermes-merge-policy.md`, and the owner turns it on with a one-line PR after three report-only runs. Until then the summary says "would merge" and nothing is merged.
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

The design is in [`.plans/hermes-orchestration/spec.md`](../../../../.plans/hermes-orchestration/spec.md) and [`plan.md`](../../../../.plans/hermes-orchestration/plan.md); `tasks.md` in the same folder tracks the build.
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

Hermes holds no provider key. `model.base_url` is the gateway, `model.api_key` is `${LITELLM_API_KEY}` (the `hermes` team key), and `model.default` is `main` (the ChatGPT/Codex subscription) for `default` and `main-cheap` for `worker` and the `renovate-daily` job. Fallback is the gateway's job (`main` → `cheap` → `local`; `main-cheap` and `main-lite` fall back through the other subscription models first; budget cap on `cheap`), so there is no `fallback_providers` block. The team may call `main`, `main-cheap`, `main-lite`, `cheap`, `local` and `local-think`.

- `model.context_length` is 200000: `main` has 272K at the gateway, but Hermes cannot see that, and a low value makes compression start far too early. A session that outgrows `local` (128K per slot) and falls all the way back to it will fail; `cheap` is the first fallback and is large enough.
- `model.streaming` is `false` in both overlays. LiteLLM `v1.109.1` drops the arguments of parallel tool calls in a streamed response, so Hermes received empty tool calls
  (390 failed calls in 7 days, and the failed run on 2026-11-13). Unstreamed responses arrive intact. Turn streaming back on only after a LiteLLM version passes the test in `.plans/hermes-orchestration/evidence.md`.
- Auxiliary tasks follow "prefer `main`" (subscription, no budget cap): `web_extract`, `compression`, `approval`, `mcp` and `kanban_decomposer` use `main`. `vision` uses `local-think` since 2026-10-29 (the server runs LFM3-VL-2B, which reads images; reasoning on, because a dashboard screenshot was misread with it off). Small background tasks (`title_generation`, `triage_specifier`, `profile_describer`, `curator`, `skills_hub`) stay on `local`, which is free and keeps them off the subscription limits. Nothing in Hermes depends on `cheap` directly, so it can be retired without touching this file.
- **Hermes refuses to build an agent for any model with less than 64,000 tokens of context** (`agent_init._enforce_minimum_context`). `local` is llama-server with `-c 262144 -np 2`: two slots, each capped at the model's trained context of 128000 tokens, so it stays usable as an auxiliary model while a slot stays at or above 64000 (see `.claude/memory/reference_hermes_64k_context_floor.md`). It serves two requests at a time.
- Text-to-speech is configured for Piper (voices cached under `cache/piper-voices/` in each profile home), but **`piper-tts` is not installed since the v0.23.0 upgrade**, so voice output does not work. The image no longer ships `uv` and its virtual environment is sealed; see `.plans/TODO.md`. Speech-to-text (Speaches) is not restored.
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
