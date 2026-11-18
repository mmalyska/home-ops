# ArgoCD GitHub webhooks tasks

## Execution contract

Repository `mmalyska/home-ops`.

- **Where to work.** Work in a linked worktree on a branch from the current `origin/main`. Run `.agents/bin/worktree-preflight`
  before the first edit.
- **What is forbidden.** Never read secret values. Never write the private domain, a Bitwarden identifier or a webhook
  secret into any file, log or PR text. Never mutate the cluster, apply Terraform or merge. Never bypass hooks.
- **Hostname.** In manifests the hook hostname is `argocd-hook.<secret:private-domain>`. In Terraform it is built from the
  existing domain variable.
- **Delivery.** Workers may commit on their branch. They do not push or open PRs. The conductor reviews the work, runs the
  gates, and pushes and opens the PR only on the owner's instruction.
- **Consent.** Human-only tasks (H*) and every step marked consent-gated stay with the owner, with fresh consent per action.

## H1 - HUMAN ONLY: create the webhook secret in Bitwarden

- **Owner:** repository owner. **Dependencies:** none.
- **What to do:**
  - Generate a random secret of at least 32 bytes (for example `openssl rand -hex 32`, run locally).
  - Store it in Bitwarden Secrets Manager as `argocd-github-webhook-secret`, in the project the `bitwarden`
    ClusterSecretStore reads.
  - Give the conductor the new secret's UUID, never its value. The UUID goes into the ExternalSecret like the other
    `remoteRef.key` entries.
- **Done when:** the conductor has the UUID.

## T1 - Add `webhook.github.secret` to the argocd-oidc-secret ExternalSecret

- **Owner:** worker (mechanical). **Dependencies:** H1. **Branch:** `feat/argocd-github-webhook` (PR 1).
- **File:** `cluster/apps/core/argocd/resources/argocd-oidc-externalsecret.yaml`.
- **Change:**
  - Add a second item under `spec.data`: `secretKey: webhook.github.secret` with `remoteRef.key` set to the UUID from H1.
  - Use the same `#gitleaks:allow #ARGOCD_GITHUB_WEBHOOK_SECRET` trailing comment style as the existing entry.
  - Do not touch `target` or `template`.
- **Optional:** rename the ExternalSecret? **No.** Keep `argocd-oidc-secret`, because renaming would delete and recreate
  it. Add a one-line comment saying it now also carries the webhook secret.
- **Checks:**
  - `kubectl kustomize cluster/apps/core/argocd`: the rendered ExternalSecret has both data entries.
  - `task lint:all`: read the output.
- **Done when:** both checks pass and the diff touches only that file.

## T2 - Cloudflare WAF rules for the hook hostname

- **Owner:** worker. **Dependencies:** none. **Branch:** `feat/argocd-github-webhook` (PR 1).
- **Files:** `provision/terraform/cloudflare/firewall.tf`, and `providers.tf` only if the `http` provider is not
  declared yet. Read `zone.tf`, `variables.tf` and `bitwarden_secrets.tf` to find how the domain is referenced.
- **Change:**
  1. Add `data "http" "github_meta"` for `https://api.github.com/meta`, with the header `Accept: application/json`.
     Add a local: `github_hook_cidrs = jsondecode(data.http.github_meta.response_body).hooks`.
  2. Add a local `argocd_hook_host = "argocd-hook.${<domain reference used elsewhere>}"`.
  3. Insert two rules at the **top** of `cloudflare_ruleset.zone_level_custom_waf.rules`, before the country and bot rules:
     - **Skip rule.** `action = "skip"`, `action_parameters = { ruleset = "current" }`. Expression:
       `(http.host eq "<host>" and ip.src in {<cidrs joined by space>})`. Description: "Allow GitHub webhook deliveries
       to the ArgoCD hook host". Logging enabled. Follow the commented UptimeRobot rule in the file for the shape.
     - **Block rule.** `action = "block"`, expression `(http.host eq "<host>")`. Description: "Block all other traffic to
       the ArgoCD hook host".
- **Checks:**
  - `terraform fmt -check` and `terraform validate` in `provision/terraform/cloudflare`.
  - `terraform plan` if `TF_TOKEN_app_terraform_io` is available. Treat its output as sensitive and do not paste it;
    report only that the plan shows exactly one in-place update of the ruleset.
- **Done when:** fmt and validate pass, and plan passes or is reported NOT RUN with the reason.

## H2 - HUMAN ONLY: merge PR 1 and confirm the key exists

- **Owner:** repository owner. **Dependencies:** T1, T2, PR 1 opened by the conductor.
- **Merge.** Merging deploys the ExternalSecret change through ArgoCD and auto-applies the WAF change through HCP Terraform
  (GITOPS_TRIGGER). The owner merges with fresh consent.
- **Confirm the key.** List key names only; the conductor may run this (READ):

  ```sh
  kubectl -n argocd get secret argocd-secret -o json | jq -r '.data | keys[]'
  ```

- **Done when:** `webhook.github.secret` appears in the key list, the `argocd-oidc-secret` ExternalSecret is `Ready`, and the
  Terraform run in HCP Terraform succeeded.

## T3 - Public HTTPRoute for the two webhook receivers

- **Owner:** worker. **Dependencies:** H2. **Branch:** a new branch `feat/argocd-github-webhook-route` from `origin/main`
  after PR 1 merged (PR 2).
- **Files:** a new `cluster/apps/core/argocd/resources/webhook-httproute.yaml`, plus `cluster/apps/core/argocd/kustomization.yaml`
  (add it to `resources`).
- **Change:** create one HTTPRoute `argocd-webhook` in namespace `argocd` with:
  - Annotation `external-dns.alpha.kubernetes.io/controller: dns-controller`.
  - `parentRefs`: only `envoy-external` in namespace `envoy-gateway`, `sectionName: https`.
  - `hostnames`: `argocd-hook.<secret:private-domain>`.
  - **Rule 1.** Match path Exact `/api/webhook` and method `POST`. Backend `argocd-server`, port 80.
  - **Rule 2.** Match path Exact `/appset/api/webhook` and method `POST`. Filter `URLRewrite` with
    `path: {type: ReplaceFullPath, replaceFullPath: /api/webhook}`. Backend `argocd-applicationset-controller`, port 7000.
- **Checks:**
  - `kubectl kustomize cluster/apps/core/argocd`: the route renders with the `<secret:private-domain>` token intact (the
    CMP replaces it at sync time) and with only the external parent.
  - `task lint:all`: read the output.
- **Done when:** both checks pass.

## T5 - Documentation

- **Owner:** worker (docs). **Dependencies:** T3. **Branch:** same as T3 (PR 2).
- **Files:** `cluster/apps/core/argocd/Readme.md`, and a short "GitHub webhook" section in `docs/src/general/network.md`
  under "External Access via Cloudflare Tunnel" (or in a new `docs/src/k8s/argocd-webhook.md` linked from the docs nav, if
  network.md is the wrong home; the conductor decides).
- **What the docs must state:**
  - The hostname pattern, the two paths, and which receiver each one reaches.
  - That the secret lives in `argocd-secret` and comes from Bitwarden through `argocd-oidc-secret`.
  - The WAF allow-list.
  - That polling stays as the fallback.
  - How to disable the webhooks.
  - No private domain, no UUIDs.
- **Done when:** the docs build check from `dev-workflow` passes or is reported NOT RUN with the reason.

## H3 - HUMAN ONLY: merge PR 2 and add the GitHub webhooks

- **Owner:** repository owner. **Dependencies:** T3, T5, PR 2 opened by the conductor.
- **Merge.** Merging publishes the hostname through external-dns (GITOPS_TRIGGER, fresh consent).
- **Add the webhooks.** Then, in GitHub, open `mmalyska/home-ops`, Settings, Webhooks, and add two webhooks (an
  outward-facing change, done by the owner):
  - Payload URL `https://argocd-hook.<private-domain>/api/webhook`.
  - Payload URL `https://argocd-hook.<private-domain>/appset/api/webhook`.
  - Both: content type `application/json`, the secret from H1, SSL verification on, event "Just the push event".
- **Done when:** both webhooks show a green ping delivery in GitHub. A ping returns 200 from ArgoCD; a 403 from Cloudflare
  means the WAF rule is wrong, and a 404 means the route is wrong.

## T4 - End-to-end verification

- **Owner:** conductor. **Dependencies:** H3.
- **Steps (all READ):**
  1. `dig +short argocd-hook.<private-domain>` from outside the LAN (or a public resolver) returns Cloudflare addresses.
  2. `curl -s -o /dev/null -w '%{http_code}' https://argocd-hook.<private-domain>/api/webhook` from a non-GitHub IP
     returns 403 (WAF block). A GET to `/` from the same IP also returns 403.
  3. After the next real merge to `main`:
     - GitHub's Recent Deliveries shows 200 for both webhooks.
     - `kubectl -n argocd logs deploy/argocd-server | grep -i webhook` shows the received push.
     - `argocd app get <changed-app>` shows the new revision within a minute, while an untouched app's last refresh did not
       move.
  4. `kubectl -n argocd logs deploy/argocd-applicationset-controller | grep -i webhook` shows the push event.
- **If deliveries fail:** check the cloudflared logs and the `envoy-external` access logs for the hostname. Confirm that
  the tunnel ingress has a catch-all to `envoy-external`, and not a fixed hostname list.
- **Done when:** every step passes, or a failing step is reported with its evidence.
