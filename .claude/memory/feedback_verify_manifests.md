---
name: Always verify rendered manifests after Helm/Kustomize changes
description: Run helm template or kubectl kustomize after every values.yaml or kustomization edit
type: feedback
---

Run `helm dependency update . && helm template <release> . -f values.yaml` or `kubectl kustomize .` after every values.yaml or kustomization edit.

**Why:** Values keys don't always map where expected (e.g. `gitea.deployment.strategy` had no effect; correct key was `gitea.strategy`). Silent mismatches deploy wrong config with no error at commit time.

**How to apply:** Always render before committing Helm/Kustomize changes. Scan rendered output for the specific field you changed to confirm it landed correctly.
