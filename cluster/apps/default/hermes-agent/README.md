# Hermes Agent — Kubernetes Deployment

Hermes Agent deployed as a single-pod application on the home Kubernetes cluster, managed declaratively via ArgoCD with Bitwarden secrets.

## Architecture

```
┌──────────────────────────────────────────────┐
│                   Pod                         │
│                                               │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐  │
│  │  nginx   │  │  hermes  │  │ signal-cli  │  │
│  │  :9119   │→ │  :9120   │  │   :8080     │  │
│  └──────────┘  └──────────┘  └────────────┘  │
│       ↑              │              │          │
│       │         ┌────┴────┐    ┌───┴───┐      │
│  HTTPRoute     │  PVC     │    │  PVC  │      │
│  (envoy)       │  1Gi     │    │  1Gi  │      │
│                └─────────┘    └───────┘      │
└───────────────────────┬──────────────────────┘
                        │ memory.provider: honcho
                        ▼
          http://honcho.honcho.svc.cluster.local:8000
          (namespace: honcho — see ../honcho/README.md)
```

| Component | Purpose |
|-----------|---------|
| **hermes-agent** | Main process — gateway server (Discord + Signal), kanban dispatcher, dashboard |
| **nginx** | Reverse proxy in front of hermes-agent; rewrites Host to `127.0.0.1` so hermes gateway loopback guard passes |
| **signal-cli** | Sidecar REST API wrapping Signal CLI for Signal messaging |
| **PVC `hermes-agent-data`** | Persistent state — config, profiles, skills, sessions, memory, logs |
| **PVC `hermes-signal-data`** | Signal CLI state (registration, key material) |
| **VolSync** | Restic backups of both PVCs to S3 (every 6 hours) |
| **ExternalSecret** | API keys from Bitwarden → K8s Secret → env vars in pod |
| **Honcho** | Self-hosted memory server (separate namespace) — provides persistent cross-session user memory via Theory-of-Mind reasoning and vector recall |

## Helm Values (`values.yaml`)

The declarative configuration lives in `values.yaml` and covers:

- **`hermes.image`** — Container image (`nousresearch/hermes-agent`)
- **`hermes.resources`** — CPU/memory requests and limits
- **`hermes.config`** — Core config (model, approvals, timezone, Discord settings, provider routing, fallback providers, auxiliary models). Gets rendered into a ConfigMap, then merged into `/opt/data/config.yaml` by an init container on every pod start.
- **`signalCli`** — Signal CLI sidecar image and resources
- **`externalSecrets`** — Bitwarden secret references for API keys
- **`backup`** — VolSync schedule and retention

Two init containers run on every pod start:

1. **`config-seeder`** — deep-merges the `hermes-agent-config` ConfigMap (rendered from `values.yaml`) into `/opt/data/config.yaml` on the PVC. Values changed in `values.yaml` are picked up on next restart; runtime state (sessions, kanban board) survives on the PVC.
2. **`honcho-seeder`** — deep-merges `hermes-agent-honcho` ConfigMap into `/opt/data/.hermes/honcho.json`. Declares all 7 Hermes profiles as Honcho memory hosts. Runtime additions made by `hermes honcho sync` are preserved across restarts (deep-merge, not overwrite).

## HTTPRoute

The dashboard is exposed at `hermes.<private-domain>` via Envoy Gateway (HTTPS). A `cluster-secrets` plugin token resolves the private domain from Bitwarden at ArgoCD sync time.

## Profiles — Not in `values.yaml`

**Profiles are NOT declared in the Helm chart.** They are created imperatively inside the running container and survive on the PVC. This is by design — profiles are stateful (skills, memory, sessions) and are managed as runtime objects, not infrastructure templates.

### How Profiles Survive Pod Restarts

On every container boot, the s6-overlay `02-reconcile-profiles` script walks `/opt/data/profiles/<name>/gateway_state.json` and re-registers each profile's gateway as an s6 service. Profiles whose prior state was `"running"` are auto-started. This makes profiles durable across pod restarts and image upgrades without any Helm involvement.

### Current Profile Fleet

| Profile | Role | Gateway | Key Tools |
|---------|------|---------|-----------|
| **default** | Interactive user-facing profile | ✅ (Discord + Signal) | Full tools |
| **orchestrator** | Decomposes goals into kanban tasks, routes to workers | ❌ | `kanban`, `web`, `memory` only |
| **devops** | Home infrastructure: K8s, Proxmox, NAS, network, CI/CD | ❌ | `terminal`, `file`, `web`, `github` |
| **researcher** | Technology research, feature planning, comparisons | ❌ | `terminal`, `file`, `web` |
| **dotnet-dev** | .NET / C# development | ❌ | `terminal`, `file`, `web`, `github` |
| **node-dev** | Node.js / TypeScript backend and CLI | ❌ | `terminal`, `file`, `web`, `github` |
| **mobile-dev** | Cross-platform mobile (Expo / React Native) | ❌ | `terminal`, `file`, `web`, `github` |

Only the **default** profile runs a gateway — it handles Discord and Signal messaging. Worker profiles are spawned by the kanban dispatcher on demand.

### Creating a New Profile

Access the pod and use `hermes profile create`:

```bash
kubectl exec -it deploy/hermes-agent -n hermes-agent -- bash -c \
  'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH" && \
   hermes profile create <name> --clone --description "..."'
```

`--clone` copies API keys from the default profile. `--description` is critical — the kanban decomposer uses it to route tasks to the right specialist.

### Profile Configuration

Each profile has its own `config.yaml` at `/opt/data/profiles/<name>/config.yaml`. The main config values to adjust per profile:

```bash
# Set the model for a specific profile
hermes -p <name> config set model.default "anthropic/claude-sonnet-4"

# Enable/disable toolsets
hermes -p <name> tools enable terminal file web
hermes -p <name> tools disable browser cronjob

# Set profile description (used by kanban decomposer for routing)
# Edit /opt/data/profiles/<name>/profile.yaml directly
```

### Orchestrator Toolsets — Critical Gotcha

The `kanban` toolset is gated — `hermes -p orchestrator tools enable kanban` reports `"Unknown toolset 'kanban'"`. It must be enabled by editing `config.yaml` directly:

```bash
kubectl exec -it deploy/hermes-agent -n hermes-agent -- python3 -c "
import yaml
path = '/opt/data/profiles/orchestrator/config.yaml'
with open(path) as f:
    config = yaml.safe_load(f)
toolsets = config.get('toolsets', [])
if 'kanban' not in toolsets:
    toolsets.append('kanban')
    config['toolsets'] = toolsets
with open(path, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
"
```

The orchestrator must also **not** have `terminal`, `file`, `browser`, or other implementation tools — only `kanban`, `web`, and `memory`. This prevents it from trying to implement tasks instead of routing them.

### Kanban Wiring

```bash
hermes config set kanban.orchestrator_profile orchestrator
hermes config set kanban.default_assignee devops
hermes kanban init
```

This auto-discovers all profiles and registers them as valid assignees.

### Filesystem Layout Inside the Container

```
/opt/data/                        ← PVC (hermes-agent-data)
├── config.yaml                   ← Main config (merged from ConfigMap template)
├── SOUL.md                       ← Agent personality
├── .env                          ← Environment (API keys injected from Secret)
├── .hermes/                      ← Hermes internal state
├── profiles/                     ← Profile directories
│   ├── default/
│   │   ├── config.yaml
│   │   ├── profile.yaml          ← Description + metadata
│   │   ├── SOUL.md
│   │   ├── skills/
│   │   ├── memories/
│   │   ├── sessions/
│   │   ├── .env
│   │   └── gateway_state.json    ← {"state": "running"} — s6 reconciler key
│   ├── orchestrator/
│   ├── devops/
│   ├── researcher/
│   ├── dotnet-dev/
│   ├── node-dev/
│   └── mobile-dev/
├── skills/                       ← Shared skills (symlinked into profiles)
├── logs/
│   ├── agent.log
│   ├── errors.log
│   ├── container-boot.log        ← s6 reconciliation log
│   └── gateways/
└── voice-memos/
```

## Memory (Honcho)

Hermes uses [Honcho](../honcho/README.md) as a persistent memory backend (`memory.provider: honcho` in `config.yaml`). Memory is scoped per-profile — each of the 7 profiles maps to a distinct Honcho host with a shared workspace.

### How it works

- After each conversation turn, the Honcho **deriver** extracts user facts and updates the vector store in the background.
- On the next turn, Honcho injects relevant context from past sessions before the model responds.
- The `dialecticCadence` (default: every 2 messages) controls how often deep recall runs; `contextCadence` (default: every message) controls context injection frequency.

### honcho.json

Honcho configuration lives at `/opt/data/.hermes/honcho.json` on the PVC. It is seeded on each pod start by the `honcho-seeder` init container from the `hermes-agent-honcho` ConfigMap. To change Honcho settings (e.g. `dialecticDepth`, `recallMode`), edit `templates/honcho-configmap.yaml` and restart the pod.

### Useful commands

```bash
# Check memory provider status (run in Discord/Signal)
# hermes honcho status

# Sync profile host registration with Honcho server
# hermes honcho sync

# Inspect the live honcho.json on the PVC
kubectl exec deploy/hermes-agent -n hermes-agent -c hermes-agent -- \
  cat /opt/data/.hermes/honcho.json
```

### Profile → Honcho host mapping

| Hermes profile | Honcho host key | aiPeer |
|----------------|----------------|--------|
| default | `hermes` | `hermes` |
| orchestrator | `hermes.orchestrator` | `orchestrator` |
| devops | `hermes.devops` | `devops` |
| researcher | `hermes.researcher` | `researcher` |
| dotnet-dev | `hermes.dotnet-dev` | `dotnet-dev` |
| node-dev | `hermes.node-dev` | `node-dev` |
| mobile-dev | `hermes.mobile-dev` | `mobile-dev` |

All profiles share `peerName: mmalyska` and `workspace: hermes`.

## Maintenance Tasks

### Viewing Logs

```bash
# Main agent
kubectl logs deploy/hermes-agent -n hermes-agent -c hermes-agent --tail=100

# Signal sidecar
kubectl logs deploy/hermes-agent -n hermes-agent -c signal-cli --tail=50

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

Restart the pod — the init container re-seeds config.yaml from the ConfigMap:

```bash
kubectl rollout restart deploy/hermes-agent -n hermes-agent
```

## Security Notes

- All secrets come from Bitwarden via ExternalSecret — no credentials in git
- `cluster-secrets` plugin resolves `<secret:private-domain>` in HTTPRoute hostname
- gitleaks pre-commit hook blocks accidental secret commits (bws IDs are annotated with `#gitleaks:allow`)
- Dashboard is loopback-only internally; nginx rewrites Host to `127.0.0.1` so the hermes host-header guard passes
