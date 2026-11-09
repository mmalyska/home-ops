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
| **hermes-agent**               | Main process — gateway server (Discord), kanban dispatcher, dashboard                                                                                     |
| **nginx**                      | Reverse proxy in front of hermes-agent; rewrites Host to `127.0.0.1` so hermes gateway loopback guard passes                                              |
| **PVC `hermes-agent-data`**    | Persistent state — config, profiles, skills, sessions, memory, logs                                                                                       |
| **VolSync**                    | Restic backups of the PVC to S3 (every 6 hours)                                                                                                           |
| **ExternalSecret**             | Discord, GitHub and sandbox SSH credentials from Bitwarden → K8s Secret → env vars in pod                                                                 |
| **LiteLLMVirtualKey `hermes`** | Team key for the AI gateway; the operator writes it to Secret `hermes-litellm`, the pod reads it as `LITELLM_API_KEY` (no provider key in this namespace) |
| **Honcho**                     | Self-hosted memory server (separate namespace) — provides persistent cross-session user memory via Theory-of-Mind reasoning and vector recall             |

## Helm Values (`values.yaml`)

The declarative configuration lives in `values.yaml` and covers:

- **`hermes.image`** — Container image (`nousresearch/hermes-agent`)
- **`hermes.resources`** — CPU/memory requests and limits
- **`hermes.config`** — Settings shared by every profile (approvals mode, display, timezone, TTS, auxiliary models; all through the gateway).
  Rendered to a ConfigMap and mounted read-only as `/etc/hermes/config.yaml` (Hermes Managed Scope, single file by `subPath`; the image keeps other files in `/etc/hermes`).
  A managed value beats every profile for that exact key and a managed list replaces the profile's list, so a key that differs between profiles must not go here.
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

## Profiles — Not in `values.yaml`

**Profiles are NOT declared in the Helm chart.** They are created imperatively inside the running container and survive on the PVC. This is by design — profiles are stateful (skills, memory, sessions) and are managed as runtime objects, not infrastructure templates.

### How Profiles Survive Pod Restarts

On every container boot, the s6-overlay `02-reconcile-profiles` script walks `/opt/data/profiles/<name>/gateway_state.json` and re-registers each profile's gateway as an s6 service. Profiles whose prior state was `"running"` are auto-started. This makes profiles durable across pod restarts and image upgrades without any Helm involvement.

### Current Profile Fleet

| Profile     | Role                                                                                | Workspace (SSH terminal) | Model        |
| ----------- | ----------------------------------------------------------------------------------- | ------------------------ | ------------ |
| **default** | Interactive Discord profile and kanban orchestrator                                 | `hermes-main`            | `main`       |
| **worker**  | Executes well-defined tasks from the orchestrator, spawned by the kanban dispatcher | `hermes-worker`          | `main-cheap` |

The `orchestrator`, `devops`, `researcher`, `dotnet-dev`, `node-dev` and `mobile-dev` profiles stay on the volume but are retired: no overlay, no kanban dispatch. Kanban only claims cards assigned to `worker` (`kanban.dispatch_profiles`).

### Creating a New Profile

Access the pod and use `hermes profile create`:

```bash
kubectl exec -it deploy/hermes-agent -n hermes-agent -- bash -c \
  'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH" && \
   hermes profile create <name> --clone --description "..."'
```

`--clone` copies API keys from the default profile. `--description` is critical — the kanban decomposer uses it to route tasks to the right specialist.

### Profile Configuration

Each profile has its own `config.yaml` at `/opt/data/profiles/<name>/config.yaml` (the `default` profile's is `/opt/data/config.yaml`). The main config values to adjust per profile:

```bash
# Set the model for a specific profile
hermes -p <name> config set model.default "cheap"

# Enable/disable toolsets
hermes -p <name> tools enable terminal file web
hermes -p <name> tools disable browser cronjob

# Set profile description (used by kanban decomposer for routing)
# Edit /opt/data/profiles/<name>/profile.yaml directly
```

### Kanban Wiring

Kanban settings live in the `default` overlay in `values.yaml`: `orchestrator_profile: default`, `default_assignee: worker`, `dispatch_profiles: [worker]`, `max_in_progress_per_profile: 2`.
The `kanban` toolset is off by default per platform; the `worker` overlay enables it under `platform_toolsets.cli`, which is what dispatcher-spawned workers use.

### Filesystem Layout Inside the Container

```
/opt/data/                        ← PVC (hermes-agent-data)
├── config.yaml                   ← Default profile config (overlay merged at start)
├── SOUL.md                       ← Agent personality
├── .env                          ← Environment (API keys injected from Secret)
├── .hermes/                      ← Hermes internal state
├── profiles/                     ← Profile directories
│   ├── <name>/
│   │   ├── config.yaml
│   │   ├── profile.yaml          ← Description + metadata
│   │   ├── SOUL.md
│   │   ├── skills/
│   │   ├── memories/
│   │   ├── sessions/
│   │   ├── .env
│   │   └── gateway_state.json    ← {"state": "running"} — s6 reconciler key
│   └── worker/
├── skills/                       ← Shared skills (symlinked into profiles)
├── logs/
│   ├── agent.log
│   ├── errors.log
│   ├── container-boot.log        ← s6 reconciliation log
│   └── gateways/
└── voice-memos/
```

## Memory (Honcho)

Hermes uses [Honcho](../honcho/README.md) as a persistent memory backend (`memory.provider: honcho` in `config.yaml`). Memory is scoped per-profile: `default` maps to the Honcho host `hermes`. `worker` has no long-term memory and no host.

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

The `hermes.orchestrator`, `hermes.devops` and `hermes.researcher` hosts are disabled (`enabled: false`) so their old memory stays intact.

## Maintenance Tasks

### Viewing Logs

```bash
# Main agent
kubectl logs deploy/hermes-agent -n hermes-agent -c hermes-agent --tail=100

# s6 boot reconciliation
kubectl exec deploy/hermes-agent -n hermes-agent -- tail -50 /opt/data/logs/container-boot.log

# Profile gateway logs (for debugging)
kubectl exec deploy/hermes-agent -n hermes-agent -- ls /opt/data/logs/gateways/
kubectl exec deploy/hermes-agent -n hermes-agent -- tail -50 /opt/data/logs/gateways/default/current
```

### Checking Gateway Status

```bash
kubectl exec deploy/hermes-agent -n hermes-agent -- hermes profile list
```

### Updating the Image

Edit `values.yaml` → update `hermes.image.tag` → commit → ArgoCD syncs. The s6 reconciler restores profile gateways from PVC state on restart.

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

Hermes holds no provider key. `model.base_url` is the gateway, `model.api_key` is `${LITELLM_API_KEY}` (the `hermes` team key), and `model.default` is `main` (the ChatGPT/Codex subscription). Fallback is the gateway's job (`main` → `cheap` → `local`, budget cap on `cheap`), so there is no `fallback_providers` block. The team may call `main`, `cheap` and `local` only.

- `model.context_length` is 200000: `main` has 272K at the gateway, but Hermes cannot see that, and a low value makes compression start far too early. A session that outgrows `local` (64K) and falls all the way back to it will fail; `cheap` is the first fallback and is large enough.
- Auxiliary tasks follow "prefer `main`" (subscription, no budget cap): `web_extract`, `compression`, `approval`, `mcp` and `kanban_decomposer` use `main`. `vision` uses `local-think` since 2026-10-29 (the server runs LFM3-VL-2B, which reads images; reasoning on, because a dashboard screenshot was misread with it off). Small background tasks (`title_generation`, `triage_specifier`, `profile_describer`, `curator`, `skills_hub`) stay on `local`, which is free and keeps them off the subscription limits. Nothing in Hermes depends on `cheap` directly, so it can be retired without touching this file.
- **Hermes refuses to build an agent for any model with less than 64,000 tokens of context** (`agent_init._enforce_minimum_context`). `local` is llama-server with `-c 65536 -np 1`, one slot of 65536 tokens, so it only stays usable as an auxiliary model while that slot stays at or above 64000 (see `.claude/memory/reference_hermes_64k_context_floor.md`). It serves one request at a time.
- Text-to-speech is configured for Piper (voices cached under `cache/piper-voices/` in each profile home), but **`piper-tts` is not installed since the v0.23.0 upgrade**, so voice output does not work. The image no longer ships `uv` and its virtual environment is sealed; see `.plans/TODO.md`. Speech-to-text (Speaches) is not restored.
- Profiles are not created by the chart; their config lives on the PVC. `hermes.profileOverlays.<name>` (`default`, `worker`) is deep-merged into that profile's `config.yaml` on every pod start. The seeders **only add or overwrite keys, never delete**: to move a profile to another provider, overwrite `model.provider`, `model.default`, `model.base_url`, `model.api_key` and `model.context_length` explicitly, otherwise a stale value keeps traffic on the old endpoint. `hermes chat -q "ping"` (or `hermes -p <name> chat -q "ping"`) in the pod is the quickest check that an agent can start.
- `${LITELLM_API_KEY}` in `config.yaml` is expanded by Hermes from the pod environment. If `hermes chat -q "ping"` reports an authentication error, check that expansion first.
- GPU rules, memory budget and recovery for `local`: see `docs/src/k8s/nv1-jetson.md`.

## Security Notes

- All secrets come from Bitwarden via ExternalSecret — no credentials in git
- `cluster-secrets` plugin resolves `<secret:private-domain>` in HTTPRoute hostname
- gitleaks pre-commit hook blocks accidental secret commits (bws IDs are annotated with `#gitleaks:allow`)
- Dashboard is loopback-only internally; nginx rewrites Host to `127.0.0.1` so the hermes host-header guard passes
