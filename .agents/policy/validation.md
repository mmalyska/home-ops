# Validation Matrix

What to run for each kind of change, and how to report it. Summary and rules live in [`AGENTS.md`](../../AGENTS.md); the consent classes behind the live layers are in [`permissions.md`](permissions.md).

This file adds no tool. Every command below already exists in the repository or the devcontainer. The `test_validation_policy` test checks that the scripts and tasks named here exist.

## Layers

| Layer   | What it is                                            | Class            | Rule                                                   |
| ------- | ----------------------------------------------------- | ---------------- | ------------------------------------------------------ |
| L0      | Local deterministic checks (render, lint, test, diff) | LOCAL_CHECK      | Always run before commit                               |
| L1      | CI that runs on the pull request                      | n/a              | The PR waits for it; read the result, do not assume it |
| L2      | Read-only live verification                           | READ             | Allowed; never print a secret value                    |
| L3      | Mutating live validation (apply, sync, upgrade)       | RUNTIME_MUTATION | Fresh consent per action; otherwise report NOT RUN     |
| NOT RUN | A check that was not executed, with the reason        | n/a              | Never a silent skip, never reported as PASS            |

## Reporting

Report each check as `PASS`, `FAIL`, `NOT RUN` (with the reason) or `N/A`. A check you did not execute is `NOT RUN`, even when you expect it to pass. A tool that is not installed locally (for example `markdownlint`, which only CI runs) is `NOT RUN: not installed locally, covered by CI`.

The PR description carries a Validation table with one row per check and an Impact line from the merge-impact map in [`permissions.md`](permissions.md). The template is [`.github/pull_request_template.md`](../../.github/pull_request_template.md).

## Matrix

The profile lines recommend a workflow profile. A profile never lowers a requirement in this file.

### Documentation, plans, comments

- L0: `git diff --check`; `bash .agents/tests/run.sh` when `AGENTS.md`, `CLAUDE.md`, `.agents/` or `.plans/` changed; `prettier --ignore-path .github/linters/.prettierignore --config .github/linters/.prettierrc.yaml --check <files>`; `markdownlint -c .github/linters/.markdownlint.yaml <files>` (NOT RUN when not installed); `pre-commit run --all-files` (includes gitleaks); no private domain in any file.
- L1: Lint (markdownlint, prettier), Agent instructions.
- L2, L3: none.
- Profile: STANDARD.
- Profile for a typo fix: QUICK.

### Plain YAML under `cluster/` (no chart)

- L0: `yamllint -c .github/linters/.yamllint.yaml <files>`; prettier `--check`; gitleaks.
- L1: Lint, kubeconform (CRDs without a schema are ignored, so this is weak), rendered diff.
- L2: `kubectl diff -f <file>` (server-side dry run) on the changed object.
- L3: none in the repo flow; Argo syncs after merge.
- Profile: STANDARD.

### Helm chart, `Chart.yaml`, `values.yaml`, templates

- L0: `helm dependency update . && helm template <release> . -f values.yaml`; confirm the changed field in the rendered output; `helm lint .`; yamllint.
- A local `file://` chart (under `charts/`) needs its `Chart.yaml` `version` bumped and the parent dependency version updated, or Argo keeps the cached chart.
- L1: Lint, helm-lint, rendered diff (`diff-yaml-on-pr`).
- L2: `argocd app diff <app>`; `kubectl get` of the resulting object after sync.
- L3: a Deployment strategy change from RollingUpdate to Recreate needs a live patch of the object before the sync (see the memory note on deployment strategy); that patch is RUNTIME_MUTATION.
- Profile: STANDARD.
- Profile for storage or operators: DEEP.

### Kustomize

- L0: `kubectl kustomize .` and inspect the changed field; yamllint.
- L1: Lint, rendered diff.
- L2: `argocd app diff <app>`.
- L3: none.
- Profile: STANDARD.

### ArgoCD Application, ApplicationSet, AppProject, `app-config.yaml`

- L0: yamllint and prettier; compare the fields with the `add-app` skill; check `enabled`, `syncPolicy`, `syncWave` and `SECRET_PROVIDER`. There is no local ApplicationSet render tool: reason about the generated Application from the template and say so.
- L1: Lint, kubeconform (weak: no CRD schemas).
- L2: `argocd app list`, `argocd app get <app>`, `argocd proj list`.
- L3: Argo sync or refresh. `syncPolicy` and `enabled` changes are GITOPS_TRIGGER.
- Profile: DEEP for ApplicationSets, projects and the bootstrap application.

### Talos patches, config and generated files

- L0: `provision/talos/scripts/check-patches.sh`; `provision/talos/scripts/config-map.sh --check`; `provision/talos/tests/run.sh`. Never hand-edit the generated `provision/talos/clusterconfig/` (see the `cluster-reference` skill).
- L1: the `Talos config` workflow.
- L2: `provision/talos/scripts/diff-live.sh`, `isolation-check.sh`, `pki-parity.sh`; `talosctl get`.
- L3: `task talos:apply`, upgrade, reset, reboot.
- Profile: DEEP for bootstrap, PKI, disks and workload isolation.

### Terraform (`provision/terraform/cloudflare`)

- L0: `terraform fmt -check`; `terraform validate`; `terraform plan` (needs `TF_TOKEN_app_terraform_io`; treat the output as sensitive and do not paste it). Merging triggers an HCP Terraform auto-apply, so record that in the Impact line.
- L1: terraform fmt in MegaLinter (tflint is not enabled).
- L2: `terraform show`, `terraform state list`, `terraform state show`.
- L3: `terraform apply` (consent). Merging is GITOPS_TRIGGER. Never `terraform destroy`.
- Profile: DEEP.

### ExternalSecret and secret handling

- L0: individual `data[]` entries with UUIDs (no `dataFrom.extract`); `ClusterSecretStore` named `bitwarden`; the rule "token in `Secret data/stringData` → ExternalSecret, any other field → `cluster-secrets`"; gitleaks; no value in the diff, a note or the PR text.
- L1: secretlint, kubeconform.
- L2: `kubectl get externalsecret` status only. Never `kubectl get secret` (SECRET_ACCESS).
- L3: Bitwarden changes and rotation.
- Profile: DEEP for architecture changes.

### Storage, CNPG, Ceph

- L0: render; every CNPG `ObjectStore` sets `AWS_REQUEST_CHECKSUM_CALCULATION=when_required`; read the relevant skill (`cnpg-cluster-audit`, `node-disk-health`); write the rollback down.
- L1: Lint, rendered diff.
- L2: `ceph status` through the read-only exec allowlist, `kubectl get cluster,backup`, Prometheus reads.
- L3: any restore, resize, discard setting or OSD change. PVC, Ceph and CNPG deletion is DESTRUCTIVE.
- Profile: DEEP.

### Network (Cilium, gateways, HTTPRoute, DNS, LB IPs)

- L0: render; list the live LB IPs and pools before assigning one; update the network table in `docs/` in the same PR; follow the HTTPRoute annotation rules in the gateway reference.
- L1: Lint, rendered diff.
- L2: `kubectl get svc,gateway,httproute -A`; a DNS query.
- L3: none by the agent.
- Profile: STANDARD.
- Profile for the CNI or the gateway core: DEEP.

### Needs live testing (any of the above)

- Say so in the PR and list the exact L2 commands that were or should be run.
- List the L3 steps; each needs consent. Without it, report NOT RUN with the reason.

## `task lint:*` is advisory

`task lint:all`, `lint:markdown`, `lint:yaml` and `lint:prettier:check` always exit 0 (`ignore_error: true` in `.taskfiles/lint.yml`). Read their output; a zero exit code proves nothing. CI (MegaLinter) is the gate. Making the tasks strict is the open decision D6 in the workflow plan and is not part of this change.
