# ArgoCD GitHub webhooks

A push to `main` on `mmalyska/home-ops` reaches ArgoCD within seconds through two GitHub webhooks.
Polling stays as the fallback for a missed delivery: Applications every hour (`timeout.reconciliation: "1h"` in
`argocd-cm`), and the ApplicationSet git generators every hour (`requeueAfterSeconds: 3600`). After a missed delivery a change can
take up to about an hour to apply; a manual refresh in the UI or `argocd app get <app> --refresh` skips the wait.

## How it fits together

| Piece                                 | Where                                                                                  | What it does                                                                                                                                                                  |
| ------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hostname `argocd-hook.PRIVATE_DOMAIN` | `cluster/apps/core/argocd/resources/webhook-httproute.yaml`                            | HTTPRoute on `envoy-external` only, published by external-dns. The ArgoCD UI stays on `envoy-internal`.                                                                       |
| `POST /api/webhook`                   | same route                                                                             | goes to `argocd-server`. It refreshes the Applications whose source paths changed.                                                                                            |
| `POST /appset/api/webhook`            | same route                                                                             | goes to `argocd-applicationset-controller:7000`, rewritten to `/api/webhook`. It re-runs the git generators, so a new or changed `app-config.yaml` takes effect at once.      |
| Other paths and methods               | same route                                                                             | 404 from Envoy.                                                                                                                                                               |
| Secret `webhook.github.secret`        | key in `argocd-secret`, from Bitwarden through the `argocd-oidc-secret` ExternalSecret | Both receivers check GitHub's `X-Hub-Signature-256` HMAC against it.                                                                                                          |
| WAF rules                             | `provision/terraform/cloudflare/firewall.tf`                                           | Requests to the hook host from GitHub's `hooks` ranges (read from `api.github.com/meta` on every plan) skip the other custom rules. All other traffic to the host is blocked. |

## Which apps refresh

Every generated Application has `argocd.argoproj.io/manifest-generate-paths: .`, which is relative to the app's own
source path. A push refreshes only the apps whose folder changed. `root-app` lists its three sources as absolute
paths (`/cluster/projects;/cluster/appsets;/cluster/bootstrap-application.yaml`).

A change to a local chart under `charts/` alone refreshes no app. The local-chart rule in the `dev-workflow` skill
already requires bumping the dependency version in each app's `Chart.yaml`, and that bump is inside the app folder, so
it triggers the refresh.

## The secret

GitHub does not generate the secret. The owner generates a random string, stores it in Bitwarden, and pastes the same
value into the "Secret" field of both webhooks. GitHub never shows it again, so Bitwarden is the place to read it.
To rotate it:

1. Update the Bitwarden secret.
2. Wait for the ExternalSecret refresh (1h), or force it.
3. Update both webhooks in GitHub.

Deliveries in between fail and are covered by polling.

If the key is missing from `argocd-secret`, ArgoCD accepts **unsigned** payloads. Check it before exposing the host
(key names only):

```sh
kubectl -n argocd get secret argocd-secret -o json | jq -r '.data | keys[]'
```

## GitHub settings

Repository, Settings, Webhooks. Create two webhooks with these settings:

- Payload URLs: `https://argocd-hook.PRIVATE_DOMAIN/api/webhook` and `https://argocd-hook.PRIVATE_DOMAIN/appset/api/webhook`.
- Content type: `application/json`.
- Secret: the Bitwarden value.
- SSL verification: on.
- Events: "Just the push event".

To turn webhooks off, uncheck "Active" on both webhooks, or delete them. ArgoCD falls back to polling.

## Troubleshooting a delivery

GitHub shows each delivery's response under the webhook's "Recent Deliveries".

| Response                                                               | Meaning                                                                                                                                                                                          |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 200                                                                    | Received. Check the logs below.                                                                                                                                                                  |
| 403 from Cloudflare                                                    | WAF block. The source IP is not in the `hooks` ranges, or Browser Integrity Check challenged it. If it is Browser Integrity Check, add a configuration rule that turns it off for the hook host. |
| 404                                                                    | Wrong path or method. Only `POST` on the two exact paths is routed.                                                                                                                              |
| Non-200 from ArgoCD, with an HMAC or signature error in the logs below | The secret in GitHub does not match `webhook.github.secret`.                                                                                                                                     |

```sh
kubectl -n argocd logs deploy/argocd-server | grep -i webhook
kubectl -n argocd logs deploy/argocd-applicationset-controller | grep -i webhook
```
