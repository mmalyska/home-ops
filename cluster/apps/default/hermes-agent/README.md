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
└──────────────────────────────────────────────┘
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

## Helm Values (`values.yaml`)

The declarative configuration lives in `values.yaml` and covers:

- **`hermes.image`** — Container image (`nousresearch/hermes-agent`)
- **`hermes.resources`** — CPU/memory requests and limits
- **`hermes.config`** — Core config (model, approvals, timezone, Discord settings, provider routing, fallback providers, auxiliary models). Gets rendered into a ConfigMap, then merged into `/opt/data/config.yaml` by an init container on every pod start.
- **`signalCli`** — Signal CLI sidecar image and resources
- **`externalSecrets`** — Bitwarden secret references for API keys
- **`backup`** — VolSync schedule and retention

The init container merges the ConfigMap template into the existing config.yaml on the PVC — so values changed in `values.yaml` are picked up on the next restart, while runtime state (sessions, memory, kanban board) survives on the PVC.

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
