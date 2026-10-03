---
name: coredns-argo-bootstrap-deadlock
description: Deleting the coredns Deployment kills ArgoCD too (repo-server needs cluster DNS); create the Argo app first, delete/replace only afterwards
metadata:
  type: reference
---

CoreDNS is self-provisioned (Talos `cluster.coreDNS.disabled: true`) and managed by the `coredns` ArgoCD app (upstream Helm chart, `policy sequential`). The chart's Deployment selector differs from the old one, so the first migration needed a delete.

**Why:** with CoreDNS gone, ArgoCD's applicationset controller cannot reach argocd-repo-server (`lookup ... on 10.96.0.10:53: no route to host`), so it cannot generate a missing app. Deleting before the app existed caused a cluster-wide DNS outage until the rendered Deployment was applied by hand, then the appset controller was restarted.

**How to apply:** before any delete/replace of coredns, confirm `kubectl -n argocd get application coredns` exists and is synced; keep a rendered manifest ready (`helm template ... --show-only charts/coredns/templates/deployment.yaml`). CoreDNS reads node resolvers only at pod start, so restart it after changing node nameservers. See [[gateway-and-dns-architecture]].
