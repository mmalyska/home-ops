---
name: reference_tuppr_upgrades
description: tuppr facts not derivable from the repo - shared os:admin, pre-hooks suppress inter-batch checks, Failed terminal until reset, alias tag re-pointed by the fork
metadata:
  type: reference
---

tuppr (namespace `tuppr`) runs the Talos and Kubernetes upgrades. Runbook: `docs/src/k8s/tuppr.md`.

- `KubeTalosAPIAccessConfig` has one roles list and one namespaces list, so giving `tuppr` `os:admin` also gives it to `talos-backup`.
- Pre-hooks suppress the inter-batch health checks, so the health gate uses `healthChecks` only, no hooks.
- `Failed` is terminal until the `tuppr.home-operations.com/reset` annotation or a spec edit.
- nv1's install image in git is the alias tag `custom-installer:v<talos>`; the fork `mmalyska/talos-jetson-orin` has to push and re-point it, otherwise the run parks as `WaitingForImage`. A compound tag in git would leave `task talos:diff` dirty because tuppr patches the live image to the alias.

**Why:** found reading tuppr's source for the design; none of it shows in the manifests. The first real run is still to be confirmed.
**How to apply:** before touching the CRs, the Talos API access document or nv1's installer image.
