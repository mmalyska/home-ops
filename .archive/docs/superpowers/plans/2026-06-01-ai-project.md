# AI ArgoCD Project Space Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a dedicated `ai` ArgoCD project + ApplicationSet and migrate ollama, open-webui, litellm, hermes-agent, and honcho into it from the `default` and `home-automation` projects.

**Architecture:** New `cluster/projects/ai.yaml` AppProject and `cluster/appsets/appset-ai.yaml` ApplicationSet mirror the existing `home-automation` pattern. Apps are moved by `git mv` from their current category directory to `cluster/apps/ai/`. The `preserveResourcesOnDeletion: true` flag on `appset-default` is set before any moves to prevent cascade-delete of K8s resources when the old Applications are removed; ollama's old namespace is cascade-deleted intentionally (models re-download). Each app is its own PR, verified healthy before proceeding.

**Tech Stack:** ArgoCD ApplicationSet, Kubernetes (kubectl), Helm (`helm template`), `task lint:all`

---

## Files to Create / Modify

| File | Action | Notes |
|------|--------|-------|
| `cluster/projects/ai.yaml` | Create | AppProject, same spec as home-automation.yaml |
| `cluster/appsets/appset-ai.yaml` | Create | ApplicationSet, glob `cluster/apps/ai/*/app-config.yaml` |
| `cluster/apps/ai/.gitkeep` | Create | Placeholder so directory is tracked |
| `cluster/appsets/appset-default.yaml` | Modify line 13 | `preserveResourcesOnDeletion: false` → `true` |
| `cluster/apps/home-automation/ollama/` | Move → `cluster/apps/ai/ollama/` | Also update namespace in app-config.yaml |
| `cluster/apps/default/open-webui/` | Move → `cluster/apps/ai/open-webui/` | No content changes |
| `cluster/apps/default/litellm/` | Move → `cluster/apps/ai/litellm/` | No content changes |
| `cluster/apps/default/hermes-agent/` | Move → `cluster/apps/ai/hermes-agent/` | No content changes |
| `cluster/apps/default/honcho/` | Move → `cluster/apps/ai/honcho/` | No content changes |
| `cluster/appsets/appset-default.yaml` | Modify line 13 | Restore `preserveResourcesOnDeletion: false` |

---

## Task 1: Create the `ai` AppProject, ApplicationSet, and directory (PR 1)

**Files:**
- Create: `cluster/projects/ai.yaml`
- Create: `cluster/appsets/appset-ai.yaml`
- Create: `cluster/apps/ai/.gitkeep`

- [ ] **Step 1: Create `cluster/projects/ai.yaml`**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ai
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  clusterResourceWhitelist:
    - group: "*"
      kind: "*"
  description: AI, LLM, and code-agent apps
  destinations:
    - name: "*"
      namespace: "*"
      server: "*"
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
  sourceRepos:
    - "*"
```

- [ ] **Step 2: Create `cluster/appsets/appset-ai.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: appset-ai
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  syncPolicy:
    applicationsSync: create-update
    preserveResourcesOnDeletion: false # To prevent an Application's child resources from being deleted when the parent Application is deleted set this to true
  generators:
    - git:
        repoURL: https://github.com/mmalyska/home-ops
        revision: main
        files:
          - path: cluster/apps/ai/*/app-config.yaml
        values:
          appName: '{{.path.basename}}'
      selector:
        matchExpressions:
          - key: enabled
            operator: In
            values:
              - "true"
  template:
    metadata:
      name: '{{.values.appName}}'
      namespace: argocd
      annotations:
        argocd.argoproj.io/compare-options: ServerSideDiff=true
        argocd.argoproj.io/manifest-generate-paths: .
    spec:
      project: ai
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{.namespace}}'
      syncPolicy:
        syncOptions:
          - CreateNamespace=true
          - PruneLast=true
          - RespectIgnoreDifferences=true
          - ServerSideApply=true
          - ApplyOutOfSyncOnly=true
        automated:
          prune: false
          selfHeal: true
  templatePatch: |
    {{- if or (hasKey . "appSubfolder") (hasKey . "syncWave") }}
    metadata:
      {{- if hasKey . "appSubfolder" }}
      name: '{{.values.appName}}-{{.appSubfolder}}'
      {{- end }}
      {{- if hasKey . "syncWave" }}
      annotations:
        argocd.argoproj.io/sync-wave: "{{.syncWave}}"
      {{- end }}
    {{- end }}
    spec:
      source:
        repoURL: https://github.com/mmalyska/home-ops
        targetRevision: main
      {{- if hasKey . "appSubfolder" }}
        path: '{{.path.path}}/{{.appSubfolder}}'
      {{- else }}
        path: '{{.path.path}}'
      {{- end }}
      {{- if hasKey . "plugin" }}
        plugin:
          {{- .plugin | toYaml | nindent 12 }}
      {{- end }}
      syncPolicy:
      {{- if hasKey . "managedNamespaceMetadata" }}
        managedNamespaceMetadata:
          {{- .managedNamespaceMetadata | toYaml | nindent 10 }}
      {{- end }}
        automated:
          enabled: {{ .syncPolicy.enabled }}
          prune: {{ .syncPolicy.prune }}
          selfHeal: {{.syncPolicy.selfHeal}}
      {{- if hasKey . "ignoreDifferences" }}
      ignoreDifferences:
        {{- .ignoreDifferences | toYaml | nindent 12 }}
      {{- end }}
```

- [ ] **Step 3: Create the placeholder directory**

```bash
touch cluster/apps/ai/.gitkeep
```

- [ ] **Step 4: Lint**

```bash
task lint:all
```

Expected: all checks pass (yamllint, helmlint, prettier).

- [ ] **Step 5: Commit and open PR**

```bash
git checkout -b feat/ai-project-infrastructure
git add cluster/projects/ai.yaml cluster/appsets/appset-ai.yaml cluster/apps/ai/.gitkeep
git commit -m "feat(argocd): add ai AppProject and ApplicationSet"
```

Open PR → merge → verify in ArgoCD UI: project `ai` exists, `appset-ai` ApplicationSet is present with 0 applications.

---

## Task 2: Enable safe migration — set preserveResourcesOnDeletion on appset-default (PR 2)

**Files:**
- Modify: `cluster/appsets/appset-default.yaml` line 13

- [ ] **Step 1: Update the flag**

In `cluster/appsets/appset-default.yaml`, change line 13:

```yaml
    preserveResourcesOnDeletion: false # To prevent an Application's child resources from being deleted when the parent Application is deleted set this to true
```

to:

```yaml
    preserveResourcesOnDeletion: true # To prevent an Application's child resources from being deleted when the parent Application is deleted set this to true
```

- [ ] **Step 2: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 3: Commit and open PR**

```bash
git checkout -b chore/appset-default-preserve-resources
git add cluster/appsets/appset-default.yaml
git commit -m "chore(argocd): set preserveResourcesOnDeletion=true on appset-default before ai migration"
```

Open PR → merge → verify in ArgoCD UI: `appset-default` ApplicationSet shows `preserveResourcesOnDeletion: true` in its spec.

---

## Task 3: Migrate ollama (PR 3)

**Files:**
- Move: `cluster/apps/home-automation/ollama/` → `cluster/apps/ai/ollama/`
- Modify: `cluster/apps/ai/ollama/app-config.yaml` (namespace)

- [ ] **Step 1: Move the directory**

```bash
git mv cluster/apps/home-automation/ollama cluster/apps/ai/ollama
```

- [ ] **Step 2: Update namespace in app-config.yaml**

In `cluster/apps/ai/ollama/app-config.yaml`, change:

```yaml
  namespace: ha-ollama
```

to:

```yaml
  namespace: ollama
```

- [ ] **Step 3: Render the chart to verify it still produces valid manifests**

```bash
cd cluster/apps/ai/ollama && helm dependency update && helm template ollama . -f values.yaml
```

Expected: renders without error.

- [ ] **Step 4: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 5: Commit and open PR**

```bash
git checkout -b feat/migrate-ollama-to-ai-project
git add cluster/apps/ai/ollama cluster/apps/home-automation/ollama
git commit -m "feat(argocd): migrate ollama to ai project"
```

Open PR → merge, then verify:

- [ ] **Step 6: Verify**
  - ArgoCD: `ollama` Application exists in `ai` project, status `Synced + Healthy`
  - No `ollama` Application remains in `home-automation` project
  - Old `ha-ollama` namespace is gone: `kubectl get namespace ha-ollama` → NotFound
  - New namespace created: `kubectl get pods -n ollama` → ollama pod Running
  - Models downloading: `kubectl logs -n ollama deployment/ollama | head -20`

---

## Task 4: Migrate open-webui (PR 4)

**Files:**
- Move: `cluster/apps/default/open-webui/` → `cluster/apps/ai/open-webui/`

- [ ] **Step 1: Move the directory**

```bash
git mv cluster/apps/default/open-webui cluster/apps/ai/open-webui
```

- [ ] **Step 2: Render the chart**

```bash
cd cluster/apps/ai/open-webui && helm dependency update && helm template open-webui . -f values.yaml
```

Expected: renders without error.

- [ ] **Step 3: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 4: Commit and open PR**

```bash
git checkout -b feat/migrate-open-webui-to-ai-project
git add cluster/apps/ai/open-webui cluster/apps/default/open-webui
git commit -m "feat(argocd): migrate open-webui to ai project"
```

Open PR → merge, then verify:

- [ ] **Step 5: Verify**
  - ArgoCD: `open-webui` Application in `ai` project, `Synced + Healthy`
  - No `open-webui` Application in `default` project
  - Pods running: `kubectl get pods -n open-webui`
  - UI reachable: navigate to `https://chat.<private-domain>` in browser

---

## Task 5: Migrate litellm (PR 5)

**Files:**
- Move: `cluster/apps/default/litellm/` → `cluster/apps/ai/litellm/`

- [ ] **Step 1: Move the directory**

```bash
git mv cluster/apps/default/litellm cluster/apps/ai/litellm
```

- [ ] **Step 2: Render the chart**

```bash
cd cluster/apps/ai/litellm && helm dependency update && helm template litellm . -f values.yaml
```

Expected: renders without error.

- [ ] **Step 3: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 4: Commit and open PR**

```bash
git checkout -b feat/migrate-litellm-to-ai-project
git add cluster/apps/ai/litellm cluster/apps/default/litellm
git commit -m "feat(argocd): migrate litellm to ai project"
```

Open PR → merge, then verify:

- [ ] **Step 5: Verify**
  - ArgoCD: `litellm` Application in `ai` project, `Synced + Healthy`
  - No `litellm` Application in `default` project
  - Pods running: `kubectl get pods -n litellm`
  - CNPG cluster healthy: `kubectl get cluster -n litellm` → status `Cluster in healthy state`

---

## Task 6: Migrate hermes-agent (PR 6)

**Files:**
- Move: `cluster/apps/default/hermes-agent/` → `cluster/apps/ai/hermes-agent/`

- [ ] **Step 1: Move the directory**

```bash
git mv cluster/apps/default/hermes-agent cluster/apps/ai/hermes-agent
```

- [ ] **Step 2: Render the chart**

```bash
cd cluster/apps/ai/hermes-agent && helm template hermes-agent . -f values.yaml
```

Expected: renders without error.

- [ ] **Step 3: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 4: Commit and open PR**

```bash
git checkout -b feat/migrate-hermes-agent-to-ai-project
git add cluster/apps/ai/hermes-agent cluster/apps/default/hermes-agent
git commit -m "feat(argocd): migrate hermes-agent to ai project"
```

Open PR → merge, then verify:

- [ ] **Step 5: Verify**
  - ArgoCD: `hermes-agent` Application in `ai` project, `Synced + Healthy`
  - No `hermes-agent` Application in `default` project
  - Pods running: `kubectl get pods -n hermes-agent`
  - Volsync sources healthy: `kubectl get replicationsource -n hermes-agent` → both `hermes` and `hermes-signal` show no error condition

---

## Task 7: Migrate honcho (PR 7)

**Files:**
- Move: `cluster/apps/default/honcho/` → `cluster/apps/ai/honcho/`

- [ ] **Step 1: Move the directory**

```bash
git mv cluster/apps/default/honcho cluster/apps/ai/honcho
```

- [ ] **Step 2: Render the chart**

```bash
cd cluster/apps/ai/honcho && helm dependency update && helm template honcho . -f values.yaml
```

Expected: renders without error.

- [ ] **Step 3: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 4: Commit and open PR**

```bash
git checkout -b feat/migrate-honcho-to-ai-project
git add cluster/apps/ai/honcho cluster/apps/default/honcho
git commit -m "feat(argocd): migrate honcho to ai project"
```

Open PR → merge, then verify:

- [ ] **Step 5: Verify**
  - ArgoCD: `honcho` Application in `ai` project, `Synced + Healthy`
  - No `honcho` Application in `default` project
  - Pods running: `kubectl get pods -n honcho`
  - CNPG cluster healthy: `kubectl get cluster -n honcho` → status `Cluster in healthy state`
  - hermes-agent still connecting to honcho (cluster-local service URL unchanged): check hermes-agent logs for honcho connection errors: `kubectl logs -n hermes-agent deployment/hermes-agent --tail=20`

---

## Task 8: Restore preserveResourcesOnDeletion on appset-default (PR 8)

**Files:**
- Modify: `cluster/appsets/appset-default.yaml` line 13

- [ ] **Step 1: Restore the flag**

In `cluster/appsets/appset-default.yaml`, change line 13 back:

```yaml
    preserveResourcesOnDeletion: true # To prevent an Application's child resources from being deleted when the parent Application is deleted set this to true
```

to:

```yaml
    preserveResourcesOnDeletion: false # To prevent an Application's child resources from being deleted when the parent Application is deleted set this to true
```

- [ ] **Step 2: Lint**

```bash
task lint:all
```

Expected: all checks pass.

- [ ] **Step 3: Confirm no migrated apps remain in default project**

In ArgoCD UI, open the `default` project. Confirm none of: `open-webui`, `litellm`, `hermes-agent`, `honcho` appear. The `home-automation` project should have no `ollama` Application either.

- [ ] **Step 4: Commit and open PR**

```bash
git checkout -b chore/restore-appset-default-preserve-resources
git add cluster/appsets/appset-default.yaml
git commit -m "chore(argocd): restore preserveResourcesOnDeletion=false on appset-default after ai migration"
```

Open PR → merge.

- [ ] **Step 5: Update plan index**

Move the plan to archive:

```bash
mkdir -p .archive/.plans
mv .plans/ai-project .archive/.plans/ai-project
```

Update `.plans/list.md` — remove the `ai-project` entry.
Update `.archive/.plans/list.md` — add the entry with completion date 2026-06-01.
