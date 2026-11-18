---
name: argocd-github-webhooks
description: ArgoCD refreshes on GitHub push webhooks (seconds), polling is a 1h fallback; where to look when a merge does not show up
metadata:
  type: reference
---

Since 2026-11-18 ArgoCD gets GitHub push webhooks.

- **Hook host:** `argocd-hook.PRIVATE_DOMAIN`, on envoy-external, with a Cloudflare WAF allow-list for GitHub's `hooks` ranges.
- **Two receivers:** `/api/webhook` goes to argocd-server, and `/appset/api/webhook` to the ApplicationSet controller.
- **Secret:** `webhook.github.secret` in `argocd-secret`.
- **What refreshes:** a merged change shows up within seconds, and only for the apps whose folder changed (`manifest-generate-paths: .`).
- **Polling:** only a fallback now. `timeout.reconciliation` is 1h, and `requeueAfterSeconds` is 3600 on the git generators.

So when a merge has not applied after a minute, suspect a missed delivery and refresh by hand. Do not wait for polling.

Check GitHub's Recent Deliveries, which only the owner can see; the devcontainer's token gets 403 on hooks. Then check
the argocd-server log for `refreshing app from webhook`. Envoy has no access logs.

A change only under `charts/` refreshes no app unless the dependency version in the app's `Chart.yaml` is bumped (see
the `dev-workflow` skill). Details: `docs/src/k8s/argocd-webhook.md`.
