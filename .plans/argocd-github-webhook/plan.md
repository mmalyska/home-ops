---
status: in-progress
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 585dbafa27e5db97f59d1f87c01aa7506804a944
branch: feat/argocd-github-webhook
worktree: .worktrees/feat/argocd-github-webhook
pr: "#6356"
started: 2026-11-18
updated: 2026-11-18
---

# ArgoCD GitHub webhooks

## Goal

A push to `main` on `mmalyska/home-ops` reaches ArgoCD within seconds through a GitHub webhook, instead of waiting for the
30-minute poll (`timeout.reconciliation: "30m"` in `cluster/apps/core/argocd/patches/argocd-cm.yaml`). Both receivers get the
event:

- `argocd-server` (`/api/webhook`): refreshes the Applications whose source changed.
- `argocd-applicationset-controller` (`/api/webhook` on port 7000): re-runs the git generators, so a new or changed
  `app-config.yaml` creates or updates its Application at once.

Polling stays as the fallback.

## Context (verified 2026-11-18)

- ArgoCD is the Kustomize app `cluster/apps/core/argocd`, upstream `cluster-install` v3.6.1. Its only route,
  `resources/httproute.yaml`, attaches to `envoy-internal`; nothing in ArgoCD is reachable from the internet.
- `argocd-secret` already gets keys from the ExternalSecret `argocd-oidc-secret` (`resources/argocd-oidc-externalsecret.yaml`,
  `creationPolicy: Merge`, `mergePolicy: Merge`). `webhook.github.secret` is not set.
- Rendered Services: `argocd-server` port 80 to 8080; `argocd-applicationset-controller` port `webhook` 7000. The upstream
  NetworkPolicies already allow ingress from any namespace to both (`argocd-server-network-policy` allows all;
  appset policy allows 7000 from `namespaceSelector: {}`), so the Envoy proxy in `envoy-gateway` can reach them.
- All seven ApplicationSets in `cluster/appsets/` already set `argocd.argoproj.io/manifest-generate-paths: .` on the
  generated Applications. A webhook push therefore refreshes only the apps whose path changed; no edit needed.
  `root-app` (`cluster/bootstrap-application.yaml`) has no annotation. It is a multi-source app with three sources
  (`cluster/projects`, `cluster/appsets`, and `cluster` for itself), so it would refresh on every push. T1b adds it.
- Polling today: `timeout.reconciliation: "30m"` for Applications. The ApplicationSet git generators set no
  `requeueAfterSeconds`, so they use the controller default (3 minutes).
- `cloudflared` sends all tunnel traffic to `envoy-external`; external-dns (`cluster/apps/system/cloudflare-dns`) publishes
  every hostname of an HTTPRoute attached to `envoy-external` (annotation
  `external-dns.alpha.kubernetes.io/controller: dns-controller`). No tunnel config change is expected; T4 verifies it.
- The zone WAF ruleset (`provision/terraform/cloudflare/firewall.tf`) blocks some countries and
  `cf.client.bot or cf.threat_score gt 14`. GitHub's delivery IPs could be caught by the bot rule.
- Merging a Terraform change triggers an HCP Terraform auto-apply (`.agents/policy/validation.md`).

## Decisions

1. **One dedicated hostname, `argocd-hook.<private-domain>`**, attached to `envoy-external` only. It is written in manifests
   as `argocd-hook.<secret:private-domain>`, and in Terraform it is built from the existing domain variable. The ArgoCD
   UI and API hostname stays internal only.
2. **Two paths on that hostname, POST only**, in one HTTPRoute:
   - `/api/webhook` (Exact) to `argocd-server:80`.
   - `/appset/api/webhook` (Exact) to `argocd-applicationset-controller:7000`, with a `URLRewrite` filter
     (`ReplacePrefixMatch` is not usable with Exact, so use `ReplaceFullPath: /api/webhook`).
   - Every other path or method gets 404 from Envoy.

   This needs one DNS record and two GitHub webhooks.

3. **Shared secret** `webhook.github.secret` in `argocd-secret`, added as a second `data` entry in the existing
   `argocd-oidc-secret` ExternalSecret, from a new Bitwarden secret the owner creates. Both receivers read the same key.
   GitHub does not generate this value: the owner generates a random string, stores it in Bitwarden, and pastes the
   same string into the "Secret" field of both GitHub webhooks. GitHub signs each delivery with it (HMAC-SHA256,
   `X-Hub-Signature-256`), and ArgoCD checks the signature. Without the key ArgoCD accepts unsigned payloads, so the key must be live **before** the route is published.
4. **WAF: an allow-only hostname.**
   - Rule 1 (first in the ruleset): if the request is for the hook hostname and the source IP is in GitHub's `hooks`
     ranges, skip the rest of the custom ruleset, so the bot and country rules cannot block GitHub.
   - Rule 2: block any other request to the hook hostname.
   - The ranges come from `https://api.github.com/meta` (`hooks`, IPv4 and IPv6) through a Terraform `data "http"` and
     `jsondecode`, refreshed on every plan.
5. **Polling becomes a 1-hour fallback** once webhooks are verified (T6):
   - `timeout.reconciliation: "1h"` (from 30m).
   - `requeueAfterSeconds: 3600` on the git generator of each of the seven ApplicationSets (from the 3-minute default).
   - It goes in last, after T4, so that no window exists in which polling is slow and webhooks are not yet working.
   - The owner allowed 1-2h. 1h is chosen because it bounds the delay after a missed delivery.
   - Self-heal of cluster drift does not depend on this interval: it reacts to watch events.
6. **`root-app` gets `argocd.argoproj.io/manifest-generate-paths`** with absolute repo paths for its three sources:
   `/cluster/projects;/cluster/appsets;/cluster/bootstrap-application.yaml`. It is harmless before webhooks exist, so it
   ships in PR 1.
7. **Webhook events: `push` only**, content type `application/json`, SSL verification on.

## Delivery

Three PRs, in this order:

1. **PR 1, secret + WAF + root-app annotation** (T1, T1b, T2): adds the ExternalSecret key, the WAF rules and the
   `root-app` annotation. Nothing is exposed yet. The hostname has no DNS record, so the WAF rules match nothing.
2. **PR 2, route + docs** (T3, T5): publishes the hostname. It is opened only after H2 confirms the key exists in
   `argocd-secret`.

3. **PR 3, polling to 1h** (T6): opened only after T4 passes.

Between PR 2 and PR 3, the owner adds the two webhooks in GitHub (H3), and T4 verifies end to end.

Merging any of the PRs deploys (GITOPS_TRIGGER), and PR 1 also auto-applies Terraform. Each merge needs the owner's fresh consent
with an impact statement.

## Out of scope

- Webhooks for other repositories (Helm chart repos) or for other git providers.
- Exposing any other ArgoCD API path.

## Rollback

- Revert PR 3 first if webhooks are being removed, so polling returns to 30m and 3 minutes.
- Remove the GitHub webhooks (or mark them inactive in the repo settings): ArgoCD falls back to polling at once.
- Revert PR 2 to unpublish the hostname. external-dns removes the record (`policy: sync`).
- Revert PR 1 to drop the WAF rules and the secret key. With `creationPolicy: Merge`, ESO may leave the old key in
  `argocd-secret`. Check the key list (names only), and if the key is still there, remove it by hand (consent-gated).

## Status

Approved 2026-11-18. H1 done (the owner created the Bitwarden secret). T1, T1b and T2 are implemented on
`feat/argocd-github-webhook` (PR 1, #6356).

- `terraform plan`: NOT RUN, because there is no HCP Terraform token in the session.
- `terraform fmt -check`: already fails on `main` for `account.tf` and `zone.tf`. Only `firewall.tf` was formatted.

Next: H2 (merge #6356 with consent, then confirm the key).
