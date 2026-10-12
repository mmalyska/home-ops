---
name: reference_tuppr_upgrades
description: tuppr facts that are not derivable from the repo - shared os:admin, upgrade order, Failed is terminal until reset, alias tag re-pointed by the fork, pre-hooks suppress inter-batch checks
metadata:
  type: reference
---

tuppr (namespace `tuppr`, `TalosUpgrade/cluster`, `KubernetesUpgrade/kubernetes`) runs the Talos and Kubernetes upgrades. Runbook: `docs/src/k8s/tuppr.md`.

- `KubeTalosAPIAccessConfig` has one roles list and one namespaces list, so giving `tuppr` `os:admin` also gives it to `talos-backup`.
- Order: the node running the tuppr controller first, then by name; nv1 last (the controller cannot schedule there).
- `Failed` is terminal until the `tuppr.home-operations.com/reset` annotation or a spec edit.
- nv1's install image in git is the alias tag `custom-installer:v<talos>`; the fork `mmalyska/talos-jetson-orin` has to push and re-point it, otherwise the run parks as `WaitingForImage`. A compound tag in git would leave `task talos:diff` dirty because tuppr patches the live image to the alias.
- Pre-hooks suppress the inter-batch health checks, so the health gate uses `healthChecks` only, no hooks.
- With `waitForVolumeDetach: true` tuppr drains the node itself with a hardcoded 10 min timeout; the CR's `drainTimeout` is dead config. A failed drain uncordons and requeues after 1 min, no reboot.
- Only the largest health-check `timeout` bounds the gate; after it the run retries each minute instead of failing.

**Why:** these were found reading tuppr's source for the design; none of it shows in the manifests.
**How to apply:** before touching the CRs, the Talos API access document or nv1's installer image. The first real run is still to be confirmed.
