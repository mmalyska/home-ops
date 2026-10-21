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
- nv1's install image in git is the alias tag `custom-installer-jp7:v<talos>` (own repository for the JetPack 7 line; must be public); the fork `mmalyska/talos-jetson-orin` pushes and re-points it (published and public 2026-10-12, branch `pr/jetpack7-r39`), and if it is missing the run-start pre-pull parks the whole run (mc1 to mc3 too) as `Pending` / `PrePullFailed`. A compound tag in git would leave `task talos:diff` dirty because tuppr patches the live image to the alias.

- First real Talos run (v1.14.2 to v1.14.4, 2026-10-21, runbook section "The first real Talos upgrade"): the run-start pre-pull is sequential and holds every node, nv1's 590 MB pull stalled at about 440 MiB three times because nv1 has about 125 MB free with `llama-server` up, then passed on its own. Every node waits about 2 minutes for CSI detach and then proceeds, which is normal. The controller's own node (mc1) goes first and the controller restarts and resumes.
- After every nv1 upgrade expect the stale-UKI problem (Jetson UEFI drops the `LoaderEntryDefault` write): nv1 reboots on the old version, tuppr marks the run `Failed` (`node nv1 version mismatch`) and leaves nv1 cordoned so `llama-server` stays Pending. Recovery: README fix (rename the stale UKI from a privileged pod, reboot nv1), `kubectl uncordon nv1`, then the `reset` annotation, then delete the `.bak` UKI. Ask for the node-lifecycle commands to be allowed up front: the auto-mode classifier blocked pod deletion and `talosctl reboot` until the user ran them with `!`.

**Why:** found reading tuppr's source for the design and confirmed on the first real Talos run; none of it shows in the manifests.
**How to apply:** before touching the CRs, the Talos API access document or nv1's installer image, and when planning any nv1 upgrade (about 30 minutes of LLM downtime).
