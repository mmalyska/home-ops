# Plan: AI ArgoCD Project Space

## Goal

Create a dedicated `ai` ArgoCD project and application category (`cluster/apps/ai/`) for all AI, LLM, code-agent and workflow apps. Migrate existing apps from `default` and `home-automation` categories into it without data loss.

## Context

The cluster has five ArgoCD AppProjects: `core`, `system`, `default`, `games`, `home-automation`. AI/LLM workloads are scattered across `default` and `home-automation` with no logical grouping.

**Apps to migrate:**

| App | Source | Namespace change | Data risk |
|-----|--------|-----------------|-----------|
| ollama | home-automation | `ha-ollama` → `ollama` (update app-config.yaml) | PVC deleted intentionally — models re-download |
| open-webui | default | none | none |
| litellm | default | none | none — CNPG backed up to S3 |
| hermes-agent | default | none | none — volsync running |
| honcho | default | none | none — CNPG backed up to S3 |

**n8n stays in `default`** — general-purpose tool, not AI-specific.

## Key Decisions

### Namespaces stay the same (except ollama)

Only `ha-ollama` is renamed to `ollama`. All other namespaces are preserved to avoid PVC/database migration complexity. The ArgoCD project grouping change is purely a directory + AppProject + ApplicationSet restructuring.

### Migration safety: preserveResourcesOnDeletion toggle

When an ApplicationSet's glob no longer matches an app directory (file moved), ArgoCD deletes the ArgoCD Application. With `preserveResourcesOnDeletion: false` (default), this cascades to K8s resources — data loss risk.

**Mitigation:** Set `preserveResourcesOnDeletion: true` on `appset-default` before any moves. K8s resources are orphaned (not deleted) when the old Application is removed. The new `ai` appset creates a new Application that adopts the existing resources.

`appset-home-automation` is left at `false` — ollama's 100Gi PVC contains only downloaded model weights that can be re-pulled, so cascade deletion is intentional and avoids a manual namespace cleanup.

### One PR per app

Each app move is its own PR. Verify `Synced + Healthy` in ArgoCD before proceeding to the next app.

## Architecture

New files:
```
cluster/projects/ai.yaml          # AppProject (same pattern as home-automation.yaml)
cluster/appsets/appset-ai.yaml    # ApplicationSet → cluster/apps/ai/*/app-config.yaml
cluster/apps/ai/                  # New category directory
  ollama/                         # moved from home-automation/ollama/ + namespace updated
  open-webui/                     # moved from default/open-webui/
  litellm/                        # moved from default/litellm/
  hermes-agent/                   # moved from default/hermes-agent/
  honcho/                         # moved from default/honcho/
```

## PR Sequence

| PR | Change |
|----|--------|
| 1 | Create `ai` project + appset + `.gitkeep` |
| 2 | Set `preserveResourcesOnDeletion: true` on `appset-default` only |
| 3 | Move ollama (namespace `ha-ollama` → `ollama`) |
| 4 | Move open-webui |
| 5 | Move litellm |
| 6 | Move hermes-agent |
| 7 | Move honcho |
| 8 | Restore `preserveResourcesOnDeletion: false` on `appset-default` |

## Design Doc

`docs/superpowers/specs/2026-06-01-ai-project-design.md`

## Current Status

Planning — not started.
