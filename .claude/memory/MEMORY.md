# home-ops Repository Memory

## Secrets Architecture (post-migration, completed 2026-03-11)

SOPS and Doppler are fully removed. **Bitwarden Secrets Manager is the single secret provider.** Three mechanisms now in use:

1. **`cluster-secrets`** K8s Secret (namespace: `argocd`, sourced from Bitwarden via ESO) — mounted into ArgoCD repo-server sidecars at `/cluster-secrets`. Resolves `<secret:key>` tokens in non-injectable fields (hostnames, cert dnsNames, values.yaml strings, ConfigMap data, etc.) via `argocd-secret-replacer secret --mount /cluster-secrets`.
   - Plugin trigger: `SECRET_PROVIDER: cluster-secrets` in `app-config.yaml`
   - ExternalSecret: `cluster/apps/core/argocd/resources/cluster-secrets-externalsecret.yaml`

2. **Per-app `ExternalSecret`** (Bitwarden `ClusterSecretStore` named `bitwarden`) — for credentials in K8s Secret `data`/`stringData` fields, consumed via `secretKeyRef` or ESO template rendering. Always use individual `data[]` entries with Bitwarden UUIDs — `dataFrom.extract` is NOT supported by the Bitwarden ESO provider.

3. **Terraform `bitwarden-secrets` provider** — Cloudflare credentials read directly from Bitwarden in `provision/terraform/cloudflare/doppler_secrets.tf` using `data "bitwarden-secrets_secret"` resources.

**The rule**: Token in `Secret data/stringData` → ExternalSecret. Token in any other field → `cluster-secrets` + plugin. Terraform secrets → `bitwarden-secrets` provider.

**Key pattern for ESO inside Helm `templates/`**: wrap `{{ }}` in Go raw string literals so Helm passes them through:
```yaml
VALUE: "{{ `{{ .MY_KEY }}` }}"
```

## Standing Rules
- NEVER write secrets, tokens, passwords, API keys, IPs of external services, or any sensitive data to this file or any other repo file
- Secret values belong in Bitwarden Secrets Manager only (SOPS and Doppler are fully removed)
- The private domain is a SECRET — never write it in any file committed to git (use `<secret:private-domain>` placeholder instead)

## Project Type
GitOps home-lab: Talos Linux + ArgoCD. See CLAUDE.md at repo root for full guide.

## Key Facts
- 3 Lenovo M720q nodes (mc1/mc2/mc3) as control plane at 192.168.48.2-4
- Talos v1.11.3, Kubernetes v1.34.5 (in provision/talos/talconfig.yaml, updated by Renovate)
- CNI: Cilium (NOT flannel). L2 announcements for LoadBalancer IPs (no metallb)
- Secrets: Bitwarden Secrets Manager (BWS) via .envrc + ESO ClusterSecretStore `bitwarden`
- ArgoCD uses `secret-replacer-plugin` CMP sidecar for `<secret:key>` token substitution

## App Pattern
`cluster/apps/{category}/{app-name}/app-config.yaml` — toggle with `enabled: "true|false"`
Categories: core, system, default, games, home-automation

## Important Files
- CLAUDE.md — full developer guide (created 2026-03-07)
- .envrc — sets KUBECONFIG, TALOSCONFIG, BWS secrets
- provision/talos/talconfig.yaml — Talos cluster config
- cluster/bootstrap-application.yaml — root app-of-apps

## Tooling
- `task --list` to see all tasks
- `task lint:all` / `task format:all` for linting/formatting
- Linter configs in .github/linters/
- Pre-commit: yamllint, helmlint, gitleaks, prettier

## CLAUDE.md Key Patterns (as of 2026-03-07)
- Secret injection: `<secret:key>` (plain) resolved from `cluster-secrets` mount by plugin
- ClusterIssuer name: `lets-encrypt-dns01-production-cf`
- Cluster VIP: 192.168.48.1 (kube-apiserver endpoint, TALHELPER_CLUSTERENDPOINTIP)
- Cilium LB pool: 192.168.48.20-50. Known IPs: envoy-external=.20, envoy-internal=.21, Minecraft=.23, Home-auto=.27, VintageStory=.28, Traefik(legacy)=.50
- Do NOT edit: `provision/talos/clusterconfig/`, renovate comment lines, `.terraform.lock.hcl`
- Branch: main, feat/fix/chore prefixes, MegaLinter CI on PRs, labels required

## Gateway & DNS Architecture (as of 2026-03-09)

Single domain split across two Envoy Gateway instances:
- **envoy-external** (192.168.48.20): internet-facing via Cloudflare Tunnel (`cloudflared`), currently DISABLED (app-config.yaml enabled: "false")
- **envoy-internal** (192.168.48.21): internal network only, resolved by AdGuard Home on RPI (192.168.50.9)

**DNS controllers** split by annotation filter `external-dns.alpha.kubernetes.io/controller`:
- `cloudflare-dns` — filter value `external`, sources: `crd` + `gateway-httproute` from `envoy-external`
- `adguard-dns` — filter value `internal`, sources: `crd` + `gateway-httproute` from `envoy-internal`

**Annotating resources** to control which DNS controller picks them up:
```yaml
annotations:
  external-dns.alpha.kubernetes.io/controller: internal   # or: external
```
For `gateway-httproute` source, the annotation on the Gateway itself is sufficient — routes inherit it.

**Static DNSEndpoints** live in `cluster/apps/system/adguard-dns/templates/dnsendpoints.yaml`:
- Internal: `*.PRIVATE_DOMAIN` → 192.168.48.50 (Traefik legacy), `k8s.` → .48.1, `qnap.` → 192.168.50.8
- External (cloudflare): `haas.PRIVATE_DOMAIN` CNAME → `external.PRIVATE_DOMAIN`

**Key files:**
- `cluster/apps/system/envoy-gateweay/` (note typo in dir name) — GatewayClass, Gateways, policies, HTTPS redirect
- `cluster/apps/system/cloudflare-dns/` — external-dns for Cloudflare
- `cluster/apps/system/adguard-dns/` — external-dns for AdGuard Home webhook provider

## README/Docs Status (as of 2026-03-11)
- README.md: reflects two-gateway setup, Bitwarden-only secrets, Cloudflare token stored in Bitwarden
- docs/src/index.md: Secrets Management table updated — SOPS removed, Bitwarden ESO as single secret store
- docs/src/general/network.md: fully rewritten with gateway architecture, DNS split, IP table

## Local Resource Access (devcontainer)

### Permission Rules
- **Read-only operations**: run freely without asking user
- **Mutating operations** (apply/delete/create/update/destroy/taint/upgrade): ALWAYS ask user for confirmation first

### Kubernetes (kubectl)
- kubeconfig at `~/.kube/config` (default location, no env var needed)
- kubectl v1.35.2 available at `/home/linuxbrew/.linuxbrew/bin/kubectl`
- Safe reads: `kubectl get`, `kubectl describe`, `kubectl logs`, `kubectl top`, `kubectl diff`
- Mutating (confirm first): `kubectl apply`, `kubectl delete`, `kubectl patch`, `kubectl rollout restart`, `kubectl exec`

### Talos (talosctl)
- talosctl v1.11.3 at `/usr/local/bin/talosctl`
- TALOSCONFIG is set in `.envrc` via `${PWD}/provision/talos/clusterconfig/talosconfig` (works with and without direnv)
- Nodes: mc1=192.168.48.2, mc2=192.168.48.3, mc3=192.168.48.4
- Safe reads: `talosctl get`, `talosctl health`, `talosctl logs`, `talosctl version`, `talosctl dmesg`, `talosctl ps`, `talosctl services`, `talosctl disks`, `talosctl memory`, `talosctl cpu`
- Mutating (confirm first): `talosctl apply-config`, `talosctl upgrade`, `talosctl reset`, `talosctl reboot`, `talosctl shutdown`

### Terraform (Cloudflare)
- terraform v1.5.7 at `/home/linuxbrew/.linuxbrew/bin/terraform`
- Working dir: `provision/terraform/cloudflare/`
- Requires Terraform Cloud token (TERRAFORM_TOKEN env var is set; use `task terraform:init:cloudflare` first)
- Safe reads: `terraform show`, `terraform plan`, `terraform state list`, `terraform state show`
- Mutating (confirm first): `terraform apply`, `terraform destroy`, `terraform taint`, `terraform import`

### ArgoCD (argocd)
- argocd CLI at `/home/linuxbrew/.linuxbrew/bin/argocd`
- Login first: `task argocd:login`
- Safe reads: `argocd app list`, `argocd app get`, `argocd app diff`, `argocd proj list`
- Mutating (confirm first): `argocd app sync`, `argocd app delete`, `argocd app set`

### Available namespaces (as of 2026-03-10)
adguard-dns, argocd, botkube, cert-manager, cilium-secrets, cloudflared, cloudflare-dns, cnpg, default, dyndns, external-secrets, gitea, ha-ollama, ha-openwakeword, ha-piper, hass-proxy, ha-vernemq, ha-whisper, homepage, identity, intel-device-plugins-operator, intel-gpu-plugin, jellyfin, keda, kube-system, litellm, metrics-server, minecraft-bedrock, monitoring, n8n, nfs-mounts, nfs-subdir-provisioner, node-feature-discovery, oauth2-proxy, open-webui, qnap-proxy, rook-ceph, snapshot-controller, talos-backup, traefik, vintagestory, volsync
