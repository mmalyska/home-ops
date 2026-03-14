---
name: Always verify rendered manifests after changes
description: After editing values.yaml or kustomization files, always run helm template or kustomize build to verify the output renders correctly before committing
type: feedback
---

After editing any Helm `values.yaml` or Kustomize file, always verify the rendered output before considering the change done.

**Why:** Values keys don't always map where you expect (e.g. `gitea.deployment.strategy` had no effect — the correct key was `gitea.strategy` at the subchart level). Silent mismatches cause the wrong config to be deployed with no error at commit time.

**How to apply:**
- Helm apps: `helm dependency update . && helm template <release> . -f values.yaml` — check the relevant resource type
- Kustomize apps: `kubectl kustomize .` from the app directory
- Always do this after any structural change (strategy, resources, securityContext, etc.), not just after adding new keys
