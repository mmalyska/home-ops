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

**Cascade via the finalizer is not fully reliable — verify, don't trust it.** Confirmed 2026-07-07 disabling 7 apps at once (litellm, ollama, open-webui, botkube, n8n, home-assistant, rabbitmq) by flipping `enabled: "false"` (same orphaning effect as deleting the directory, since the generator selector drops them): `kubectl delete application` returned immediately and the Application object was gone, but per-app cleanup was inconsistent — most namespaces (ollama, open-webui, n8n, ha-home-assistant, ha-rabbitmq) ended up fully empty, while litellm's CNPG `Cluster` CR (`litellmdb-cnpg`, carrying the matching `app.kubernetes.io/instance: litellm` tracking label) and botkube's `Deployment`/`Service` were left running untouched — even though litellm's own app Deployment pod *was* correctly killed. No error, no stuck finalizer, no explanation — the Application was just already gone.

**Updated procedure**: after `kubectl delete application`, always re-run `kubectl get all,pvc -n <namespace>` per app before considering it done. Anything still present (commonly: CNPG `Cluster` CRs, RabbitmqCluster CRs, or plain Deployments) needs a manual `kubectl delete` — deleting a CNPG `Cluster` CR also cascade-deletes its Pods/Services/PVCs via normal k8s ownerReferences, no extra step needed there. CNPG `Backup`/`ScheduledBackup` CRs (backup metadata pointing at external S3/barman-cloud storage, see [[reference_qnap_s3_barman_caveat]]) get removed with the namespace, but the actual backup files in the external object store are untouched — out-of-band cleanup if desired.

Once a namespace is confirmed fully empty, deleting the namespace itself is a *separate* decision from deleting the Applications/PVCs — get explicit confirmation for it on its own, even during a full multi-app purge in one sitting, and don't fold an app that wasn't part of the confirmed batch into a bulk namespace-delete just because it also happens to be empty (e.g. harbor was already disabled before a later batch and was correctly excluded).
