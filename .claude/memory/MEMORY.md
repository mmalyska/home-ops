# home-ops Repository Memory

## Standing Rules
- NEVER write secrets, tokens, passwords, API keys, IPs of external services, or any sensitive data to this file or any other repo file
- Secret values belong in SOPS-encrypted `*.sec.yaml` files or Bitwarden Secrets Manager only

## Project Type
GitOps home-lab: Talos Linux + ArgoCD + SOPS. See CLAUDE.md at repo root for full guide.

## Key Facts
- 3 Lenovo M720q nodes (mc1/mc2/mc3) as control plane at 192.168.48.2-4
- Talos v1.11.3, Kubernetes v1.34.5 (in provision/talos/talconfig.yaml, updated by Renovate)
- CNI: Cilium (NOT flannel). L2 announcements for LoadBalancer IPs (no metallb)
- Secrets: SOPS Age encryption + Bitwarden Secrets Manager (BWS) via .envrc
- ArgoCD uses KSOPS plugin for decryption at sync time

## App Pattern
`cluster/apps/{category}/{app-name}/app-config.yaml` — toggle with `enabled: "true|false"`
Categories: core, system, default, games, home-automation

## Important Files
- CLAUDE.md — full developer guide (created 2026-03-07)
- .sops.yaml — SOPS age key config
- .envrc — sets KUBECONFIG, TALOSCONFIG, BWS secrets
- provision/talos/talconfig.yaml — Talos cluster config
- cluster/bootstrap-application.yaml — root app-of-apps

## Tooling
- `task --list` to see all tasks
- `task lint:all` / `task format:all` for linting/formatting
- Linter configs in .github/linters/
- Pre-commit: yamllint, helmlint, gitleaks, prettier

## CLAUDE.md Key Patterns (as of 2026-03-07)
- Secret injection: `<secret:key>` (plain) and `<secret:key|base64>` (K8s Secret data fields)
- ClusterIssuer name: `lets-encrypt-dns01-production-cf`
- Cluster VIP: 192.168.48.1 (kube-apiserver endpoint, TALHELPER_CLUSTERENDPOINTIP)
- Cilium LB pool: 192.168.48.20-50. Known IPs: Traefik=.21, Minecraft=.23, Home-auto=.27, VintageStory=.28
- Do NOT edit: `provision/talos/clusterconfig/`, renovate comment lines, `.terraform.lock.hcl`
- Branch: main, feat/fix/chore prefixes, MegaLinter CI on PRs, labels required

## ExternalSecret Template Gotcha (ESO inside Helm templates/)

When `ExternalSecret` lives in `templates/`, Helm processes it first — so ESO template expressions like `{{ .MY_KEY }}` get consumed by Helm and resolve to empty strings before ESO ever runs.

**Fix**: wrap ESO expressions in Go raw string literals so Helm passes them through untouched:
```yaml
CF_TUNNEL_INGRESS: |
  {{ `{{ .CLOUDFLARE_TUNNEL_INGRESS }}` }}
CF_TUNNEL_SECRET: |-
  {{ `{{ toJson (dict "a" .ACCOUNT "t" .TUNNEL_ID "s" .SECRET) | b64enc }}` }}
```

**Symptom**: ESO status shows `secret synced / True` but all rendered secret values are empty/null.

## README/Docs Status (as of 2026-03-07)
- README.md updated: removed flannel/metallb, added Cilium, Keycloak, ESO, prometheus-stack, CloudNative-PG, VolSync; updated repo structure section
- docs/src/index.md updated: replaced broken image tech stack with proper tables
