# Tasks: AI ArgoCD Project Space

## Phase 1 — Infrastructure (PR 1)

- [ ] Create `cluster/projects/ai.yaml` (AppProject, same pattern as home-automation.yaml)
- [ ] Create `cluster/appsets/appset-ai.yaml` (ApplicationSet, glob `cluster/apps/ai/*/app-config.yaml`, project: ai, identical templatePatch to appset-default.yaml)
- [ ] Create `cluster/apps/ai/.gitkeep`
- [ ] Run `task lint:all` — confirm passes
- [ ] Open PR, merge — verify ArgoCD creates empty `ai` project and appset

## Phase 2 — Enable safe migration (PR 2)

- [ ] In `cluster/appsets/appset-default.yaml`: set `preserveResourcesOnDeletion: true`
- [ ] Open PR, merge — confirm in ArgoCD UI that appset-default updated

## Phase 3 — Migrate apps (PRs 3–7, one per app)

Each step: `git mv cluster/apps/{old-category}/{app}/ cluster/apps/ai/{app}/`, then verify before next.

- [ ] **PR 3 — ollama**: `git mv cluster/apps/home-automation/ollama/ cluster/apps/ai/ollama/` + update `namespace: ha-ollama` → `namespace: ollama` in app-config.yaml. Verify: new `ollama` namespace exists, pod running, models downloading; old `ha-ollama` namespace gone.
- [ ] **PR 4 — open-webui**: `git mv cluster/apps/default/open-webui/ cluster/apps/ai/open-webui/`. Verify: Application Synced+Healthy in `ai` project, UI reachable.
- [ ] **PR 5 — litellm**: `git mv cluster/apps/default/litellm/ cluster/apps/ai/litellm/`. Verify: Application Synced+Healthy, CNPG cluster healthy (`kubectl get cluster -n litellm`).
- [ ] **PR 6 — hermes-agent**: `git mv cluster/apps/default/hermes-agent/ cluster/apps/ai/hermes-agent/`. Verify: Application Synced+Healthy, volsync ReplicationSources present (`kubectl get replicationsource -n hermes-agent`).
- [ ] **PR 7 — honcho**: `git mv cluster/apps/default/honcho/ cluster/apps/ai/honcho/`. Verify: Application Synced+Healthy, CNPG cluster healthy (`kubectl get cluster -n honcho`).

## Phase 4 — Cleanup (PR 8)

- [ ] In `cluster/appsets/appset-default.yaml`: restore `preserveResourcesOnDeletion: false`
- [ ] Open PR, merge
- [ ] Confirm no Applications remain for migrated apps in `default` or `home-automation` projects
- [ ] Update `.plans/list.md` and move plan to `.archive/.plans/ai-project/`
