# Design: AI ArgoCD Project Space

**Date:** 2026-06-01  
**Status:** Approved

## Goal

Create a dedicated `ai` ArgoCD project and application category (`cluster/apps/ai/`) for all AI, LLM, code-agent and workflow apps. Migrate existing apps from `default` and `home-automation` categories into it without data loss.

## What Gets Created

Three new files following the exact pattern of the `home-automation` project:

- `cluster/projects/ai.yaml` — AppProject named `ai`, same permissive spec as all other projects
- `cluster/appsets/appset-ai.yaml` — ApplicationSet with glob `cluster/apps/ai/*/app-config.yaml`, `project: ai`, identical `templatePatch` to `appset-default.yaml`
- `cluster/apps/ai/` — new category directory (`.gitkeep` until first app lands)

## Apps to Migrate

| App | Source category | Namespace change | Data risk |
|-----|----------------|-----------------|-----------|
| ollama | home-automation | `ha-ollama` → `ollama` (update app-config.yaml) | PVC deleted intentionally — models re-download |
| open-webui | default | none | none |
| litellm | default | none | none — CNPG backed up to S3 |
| hermes-agent | default | none | none — volsync running |
| honcho | default | none | none — CNPG backed up to S3 |

**n8n stays in `default`.** It is a general-purpose workflow tool; its project should reflect what it is, not how it is currently used.

## Migration Strategy

### The cascade-delete problem

When an ApplicationSet's glob no longer matches an app directory (file moved), ArgoCD deletes the ArgoCD Application. With `preserveResourcesOnDeletion: false` (the default), this cascades to K8s resources including PVCs — data loss risk.

### Mitigation: preserveResourcesOnDeletion toggle

Set `preserveResourcesOnDeletion: true` on `appset-default` before any app moves. This orphans K8s resources when the Application is deleted rather than cascade-deleting them. The new `ai` appset then creates a new Application that syncs into the same namespace, adopting the existing resources.

`appset-home-automation` is left unchanged (`preserveResourcesOnDeletion: false`) because ollama's PVC contains only downloaded model weights that can be re-pulled — cascade deletion of `ha-ollama` is intentional and avoids a manual namespace cleanup step.

### PR sequence

| PR | Change |
|----|--------|
| 1 | Create `cluster/projects/ai.yaml`, `cluster/appsets/appset-ai.yaml`, `cluster/apps/ai/.gitkeep` |
| 2 | Set `preserveResourcesOnDeletion: true` on `appset-default` only |
| 3 | Move `ollama` (update namespace `ha-ollama` → `ollama` in app-config.yaml) |
| 4 | Move `open-webui` |
| 5 | Move `litellm` |
| 6 | Move `hermes-agent` |
| 7 | Move `honcho` |
| 8 | Restore `preserveResourcesOnDeletion: false` on `appset-default` |

Each app move PR is merged and verified healthy before the next one proceeds.

## Verification

After each app move PR merges, confirm:

1. ArgoCD Application shows `Synced` + `Healthy` in the `ai` project
2. No Application remains for that app in the old project
3. Pods running: `kubectl get pods -n <namespace>`

App-specific checks:
- **ollama** — new `ollama` namespace exists, pod running, models begin downloading
- **litellm / honcho** — CNPG cluster healthy: `kubectl get cluster -n <namespace>`
- **hermes-agent** — volsync `ReplicationSource` objects present and not erroring: `kubectl get replicationsource -n hermes-agent`
- **open-webui** — chat UI reachable at its HTTPRoute hostname

## Out of Scope

- Renaming other namespaces (e.g. `hermes-agent` → `ai-hermes-agent`)
- Moving n8n
- Adding new AI apps (separate task)
