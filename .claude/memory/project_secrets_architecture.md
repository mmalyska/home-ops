---
name: Secrets architecture (Bitwarden-only, post-migration 2026-03-11)
description: Three mechanisms for secrets in this cluster — when to use each
type: project
---

Three mechanisms (post-migration 2026-03-11):

1. **`cluster-secrets` K8s Secret** in `argocd` namespace — resolves `<secret:key>` tokens in non-injectable fields; trigger: `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`

2. **Per-app ExternalSecret** with `ClusterSecretStore 'bitwarden'` — for K8s Secret `data`/`stringData` fields; always use individual `data[]` entries with UUIDs — `dataFrom.extract` is NOT supported

3. **Terraform bitwarden-secrets provider** — Cloudflare creds

**Rule:** Token in `Secret data/stringData` → ExternalSecret. Any other field → `cluster-secrets` + plugin.

**ESO inside Helm `templates/`:** wrap `{{ }}` in Go raw string literals.

**Why:** Using the wrong mechanism causes either unresolved tokens or broken ESO sync.

**How to apply:** Check where the secret value is consumed before deciding which mechanism to use.
