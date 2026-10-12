---
name: reference_tuppr_upgrades
description: tuppr facts not derivable from the repo - Secret with os:admin Talos credential, pre-hooks suppress inter-batch checks, Failed terminal until reset, alias tag and the run-wide PrePullFailed
metadata:
  type: reference
---

tuppr (namespace `tuppr`) runs the Talos and Kubernetes upgrades. Runbook: `docs/src/k8s/tuppr.md`.

- `KubeTalosAPIAccessConfig` has one roles list and one namespaces list; Secret `tuppr/tuppr-talosconfig` holds an `os:admin` Talos credential and tuppr's ClusterRole reads every Secret, so Secret read access in `tuppr` means Talos control.
- Pre-hooks suppress the inter-batch health checks, so the health gate uses `healthChecks` only, no hooks.
- `Failed` is terminal until the `tuppr.home-operations.com/reset` annotation or a spec edit.
- nv1's install image in git is the alias tag `custom-installer-jp7:v<talos>` (own repository for the JetPack 7 line; must be public); the fork `mmalyska/talos-jetson-orin` has to push and re-point it, otherwise the run-start pre-pull parks the whole run (mc1 to mc3 too) as `Pending` / `PrePullFailed`. A compound tag in git would leave `task talos:diff` dirty because tuppr patches the live image to the alias.

**Why:** found reading tuppr's source for the design; none of it shows in the manifests. The first real run is still to be confirmed.
**How to apply:** before touching the CRs, the Talos API access document or nv1's installer image.
