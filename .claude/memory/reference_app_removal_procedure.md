---
name: reference-app-removal-procedure
description: How to actually remove an app in this repo — deleting the git directory alone does not prune ArgoCD resources
metadata:
  node_type: memory
  type: reference
  originSessionId: e5b87569-7586-476d-bfc7-a55046614dae
---

Every ApplicationSet in this repo (`appset-system`, `appset-default`, `appset-core`, `appset-ai`, `appset-home-automation`, `appset-games`, in `cluster/appsets/`) is configured with `syncPolicy.applicationsSync: create-update` — deliberately not `create-update-delete`. This is repo-wide and deliberate, not an oversight.

**Consequence:** deleting an app's directory (e.g. `cluster/apps/home-automation/vernemq/`) and merging that PR does *not* remove the ArgoCD `Application` object. It's left behind indefinitely reporting `ComparisonError: app path does not exist` — it will never self-resolve.

**Full manual removal procedure** (confirmed working, used to remove VerneMQ 2026-07-07):
1. Merge the PR deleting the app directory from git.
2. `kubectl delete application <name> -n argocd` — this is a live-cluster mutation, always confirm with the user first. The `resources-finalizer.argocd.argoproj.io` finalizer (present by default) cascade-deletes everything ArgoCD directly applied: Deployments/StatefulSets, pods, Services, etc.
3. Check for PVCs separately: if the app used a StatefulSet with `volumeClaimTemplates`, those PVCs are provisioned by the StatefulSet controller at runtime, not applied directly by ArgoCD from the git manifest — so step 2 does **not** delete them. They're left `Bound` and orphaned.
4. Decide explicitly whether to `kubectl delete pvc <name> -n <namespace>` for each — this is irreversible data loss, always confirm with the user first, independent from the confirmation in step 2.

See [[project_secrets_architecture]] for the related secrets-mechanism split in this repo, and the RabbitMQ/VerneMQ migration plan (`docs/superpowers/plans/2026-07-06-rabbitmq-operator.md`) for the incident this was learned from.
