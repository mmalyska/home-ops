---
name: Secrets architecture (post-migration)
description: Bitwarden is the single secret provider; three mechanisms depending on where the value is consumed
type: project
---

SOPS and Doppler fully removed (2026-03-11). **Bitwarden Secrets Manager is the single secret provider.**

1. **`cluster-secrets`** K8s Secret (`argocd` namespace, sourced via ESO) — resolves `<secret:key>` tokens in non-injectable fields (hostnames, cert dnsNames, values.yaml strings, ConfigMap data). Trigger: `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`.
   - ExternalSecret: `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`

2. **Per-app `ExternalSecret`** (ClusterSecretStore `bitwarden`) — for K8s Secret `data`/`stringData` fields. Always use individual `data[]` entries with UUIDs — `dataFrom.extract` is NOT supported by the Bitwarden ESO provider.

3. **Terraform `bitwarden-secrets` provider** — Cloudflare credentials in `provision/terraform/cloudflare/bitwarden_secrets.tf`.

**The rule**: Token in `Secret data/stringData` → ExternalSecret. Token in any other field → `cluster-secrets` + plugin. Terraform → `bitwarden-secrets` provider.

**ESO inside Helm `templates/`**: wrap `{{ }}` in Go raw string literals so Helm passes them through:
```yaml
VALUE: "{{ `{{ .MY_KEY }}` }}"
```
