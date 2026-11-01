# Permission Matrix

Detailed policy behind the classes and consent protocol in [`AGENTS.md`](../../AGENTS.md). This file owns the per-tool command lists, the read-only `exec` allowlist and the merge-impact map.

Nothing in this file authorizes a mutation. Every command under GITOPS_TRIGGER, RUNTIME_MUTATION and DESTRUCTIVE needs fresh consent from the user in the current session, naming the action, the target and the effect.

**Unlisted rule:** an operation that is not listed takes the stricter class. A command whose effect cannot be told from its text (for example `gh api` with the method set late in the command) is treated as consent-required.

**Format:** a backticked span that starts with `Bash` and a parenthesis is a Claude Code permission pattern and must match `.claude/settings.json` exactly (the `test_permissions_parity` test checks both directions, and checks that the class here fits the list `allow`, `ask` or `deny` there). Text outside such spans is policy for every harness.

## READ

Reads that expose no secret value. Allowed.

Claude patterns (`allow`):

- Kubernetes: `Bash(kubectl get *)`, `Bash(kubectl describe *)`, `Bash(kubectl logs *)`, `Bash(kubectl top *)`, `Bash(kubectl diff *)`, `Bash(kubectl config *)`, `Bash(kubectl version*)`, `Bash(kubectl rollout status *)`, `Bash(kubectl rollout history *)`, `Bash(kubectl auth can-i *)`
- Talos: `Bash(talosctl get *)`, `Bash(talosctl health*)`, `Bash(talosctl logs *)`, `Bash(talosctl version*)`, `Bash(talosctl dmesg*)`, `Bash(talosctl ps*)`, `Bash(talosctl services*)`, `Bash(talosctl disks*)`, `Bash(talosctl memory*)`, `Bash(talosctl cpu*)`
- Terraform: `Bash(terraform show*)`, `Bash(terraform state list*)`, `Bash(terraform state show*)`
- ArgoCD: `Bash(argocd app list*)`, `Bash(argocd app get *)`, `Bash(argocd app diff *)`, `Bash(argocd proj list*)`
- Helm: `Bash(helm list*)`, `Bash(helm status *)`, `Bash(helm get *)`, `Bash(helm show *)`, `Bash(helm repo *)`, `Bash(helm search *)`
- Task: `Bash(task --list*)`
- Git: `Bash(git status*)`, `Bash(git log *)`, `Bash(git diff *)`, `Bash(git branch)`, `Bash(git branch --list*)`, `Bash(git branch --show-current)`, `Bash(git branch -a*)`, `Bash(git branch -r*)`, `Bash(git branch -v*)`, `Bash(git branch -vv*)`
- GitHub: `Bash(gh pr view*)`, `Bash(gh pr list*)`, `Bash(gh pr diff*)`, `Bash(gh pr checks*)`, `Bash(gh pr status*)`, `Bash(gh run view*)`, `Bash(gh run list*)`, `Bash(gh run watch*)`, `Bash(gh label list*)`, `Bash(gh api --method GET *)`, `Bash(gh api -X GET *)`

Policy (all harnesses):

- `argocd app get/list/diff`, `talosctl get`, `kubectl get/describe/logs` are allowed; `kubectl get secret` and the other secret reads are SECRET_ACCESS.
- `kubectl port-forward` and `kubectl exec` of an allowlisted command (below) are READ. Claude prompts for every `exec` and for `port-forward`, which is stricter than this policy.
- `ceph`, CNPG plugin (`status`, `psql` read queries) and `bws secret list` are READ when they print no secret value.
- `gh api` is READ only with an explicit GET method and no field or input flags. The allow patterns are prefix matches, so a later flag in the same command can change the method; the `ask` patterns under GITOPS_TRIGGER cover the known cases and every other form falls back to a prompt.
- `helm get values` can print secret values: it is SECRET_ACCESS even though `helm get *` is allowed. The `deny` rule wins.

### Read-only `exec` allowlist

`kubectl exec` is RUNTIME_MUTATION unless the exact command is on this list: `ceph status`, `ceph health detail`, `ceph df`, `ceph osd perf`, `ceph osd tree`, `ceph config get`. Run it in the `rook-ceph-tools` deployment. Any other command, any pipe or shell wrapper, any added argument not listed here is RUNTIME_MUTATION.

## LOCAL_CHECK

Render, lint, test, diff, plan. Allowed. Treat `plan` and `helm template` output as sensitive: do not paste Secret manifests into plans, PRs or logs.

Claude patterns (`allow`): `Bash(terraform plan*)`, `Bash(helm template *)`, `Bash(task lint:*)`, `Bash(helm lint *)`, `Bash(yamllint *)`

Policy: `kubectl kustomize`, `terraform fmt/validate`, `prettier --check`, `shellcheck`, `pre-commit run`, `bash .agents/tests/run.sh`, `git diff --check`.

## REPO_WRITE

Edits in the working tree. Allowed in a linked worktree only. No Claude patterns: file edits are governed by the worktree rule in `AGENTS.md`.

## DELIVERY

`git commit` on a feature branch is allowed for implementation tasks. `git push` of that branch and `gh pr create` happen only on an explicit instruction or when plainly part of the currently assigned task; there is no general authorization.

Claude patterns:

- `allow`: `Bash(git add *)`, `Bash(git commit *)`
- `ask`: `Bash(git push --force*)`, `Bash(git push -f *)`, `Bash(gh pr create*)`
- `deny`: `Bash(git commit*--no-verify*)`, `Bash(git commit -n*)`, `Bash(git commit* -n)`, `Bash(git commit* -n *)`, `Bash(git push*--no-verify*)`, `Bash(git push*origin main*)`

Policy: never push to `main`, never skip hooks (`--no-verify`, and `git commit -n`, which is the same thing). The `-n` patterns also match a message that contains `-n`; rewrite the message. Residual: `-n` bundled behind another short flag (for example `-an`) is not matched by any pattern, so it relies on this instruction and on review, never force-push without consent. PR comments are DELIVERY and need an instruction.

## SECRET_ACCESS

Reading secret values. Denied. Use references and schemas; never write values to tracked files, plans, logs or prompts.

Claude patterns (`deny`): `Bash(kubectl get secret*)`, `Bash(kubectl describe secret*)`, `Bash(kubectl get serviceaccount*)`, `Bash(kubectl config view*--raw*)`, `Bash(talosctl get secret*)`, `Bash(sops -d *)`, `Bash(sops --decrypt *)`, `Bash(helm get values*)`, `Bash(bws secret get*)`, `Bash(printenv*)`, `Bash(env)`

Policy: also `talosctl kubeconfig`/`talosconfig` output, `kubectl exec ... env`, `cat` of `.envrc` or token files, `bws secret get` through any wrapper.

## GITOPS_TRIGGER

Anything whose effect is a deploy through Git or CI. Fresh consent per action with an impact statement from the merge-impact map.

Claude patterns (`ask`): `Bash(gh pr merge*)`, `Bash(gh api *POST*)`, `Bash(gh api *PUT*)`, `Bash(gh api *PATCH*)`, `Bash(gh api *DELETE*)`, `Bash(gh api graphql*)`, `Bash(gh api * -f *)`, `Bash(gh api * -F *)`, `Bash(gh api * --field *)`, `Bash(gh api * --raw-field *)`, `Bash(gh api * --input *)`

Policy: merging a PR by any route (UI, `gh pr merge`, `--auto`, the API), enabling auto-merge, editing Renovate automerge rules, changing `syncPolicy` or `enabled` in `app-config.yaml`. **A merge may deploy.** Renovate PRs that automerge are an owner-configured path outside agent authority.

The impact statement names: which paths change, which Applications will sync (prune on or off), whether HCP Terraform will apply, whether a tuppr upgrade resource changes, and the rollback (revert PR plus any live step).

### Merge-impact map

| Path changed                                                                                         | Effect of merging to `main`                                                          |
| ---------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `cluster/apps/**`, `cluster/appsets/**`, `cluster/projects/**`, `cluster/bootstrap-application.yaml` | ArgoCD auto-sync (`selfHeal`); prune per app                                         |
| `cluster/apps/system/tuppr/**`                                                                       | Node and Kubernetes upgrades                                                         |
| `provision/terraform/cloudflare/**`                                                                  | HCP Terraform auto-apply                                                             |
| `charts/**`                                                                                          | Through the apps that depend on them; bump `Chart.yaml` version for `file://` charts |
| `.github/renovate*`                                                                                  | Renovate automerge policy                                                            |
| `.github/workflows/**`, `docs/**`                                                                    | CI behaviour and public docs publication                                             |
| `provision/talos/**`                                                                                 | None automatically (manual `task talos:apply`)                                       |
| `AGENTS.md`, `CLAUDE.md`, `.agents/**`, `.claude/**`, `.plans/**`                                    | None                                                                                 |

## RUNTIME_MUTATION

Changes to live state. Fresh consent per action naming target and effect.

Claude patterns (`ask`):

- GitHub: `Bash(gh workflow run*)`, `Bash(gh run rerun*)`
- Kubernetes: `Bash(kubectl apply*)`, `Bash(kubectl create*)`, `Bash(kubectl delete*)`, `Bash(kubectl patch*)`, `Bash(kubectl replace*)`, `Bash(kubectl edit*)`, `Bash(kubectl set *)`, `Bash(kubectl annotate*)`, `Bash(kubectl label*)`, `Bash(kubectl taint*)`, `Bash(kubectl scale*)`, `Bash(kubectl exec*)`, `Bash(kubectl cp *)`, `Bash(kubectl drain*)`, `Bash(kubectl cordon*)`, `Bash(kubectl uncordon*)`, `Bash(kubectl rollout restart*)`, `Bash(kubectl rollout undo*)`, `Bash(kubectl rollout pause*)`, `Bash(kubectl rollout resume*)`
- ArgoCD: `Bash(argocd app sync*)`, `Bash(argocd app set*)`, `Bash(argocd app patch*)`, `Bash(argocd app create*)`, `Bash(argocd app delete*)`, `Bash(argocd app rollback*)`
- Talos: `Bash(talosctl apply-config*)`, `Bash(talosctl upgrade*)`, `Bash(talosctl patch*)`, `Bash(talosctl edit*)`, `Bash(talosctl bootstrap*)`, `Bash(talosctl reboot*)`, `Bash(talosctl shutdown*)`
- Terraform: `Bash(terraform apply*)`, `Bash(terraform import*)`, `Bash(terraform state mv*)`, `Bash(terraform state rm*)`, `Bash(terraform taint*)`, `Bash(terraform refresh*)`
- Bitwarden: `Bash(bws secret create*)`, `Bash(bws secret edit*)`, `Bash(bws secret delete*)`
- Task wrappers: `Bash(task talos:apply*)`, `Bash(task talos:upgrade*)`, `Bash(task argocd:sync*)`, `Bash(task terraform:apply*)`, `Bash(task bootstrap:*)`

Policy (no Claude pattern, covered by the unlisted rule): `argocd app` forced refresh, `ceph tell ... config set`, `ceph osd out`, CNPG `backup`, `promote`, `restart`, `hibernate`, `helm install/upgrade/uninstall/rollback`, `kubectl exec` of anything not on the allowlist.

## DESTRUCTIVE

Data or identity loss. Use the deepest review level, record backup and rollback evidence, and obtain consent immediately before each action.

Claude patterns:

- `ask`: `Bash(talosctl reset*)`
- `deny`: `Bash(terraform destroy*)`

Policy: PVC, namespace or CRD deletion; Ceph OSD, pool or mon removal (`ceph osd purge`); CNPG cluster or backup deletion; S3 backup bucket changes; key or credential rotation; node reset. `terraform destroy` stays denied. `kubectl delete` is RUNTIME_MUTATION in general and DESTRUCTIVE for the objects above.

## Enforcement per harness

| Harness     | Enforcement                                                                                                  |
| ----------- | ------------------------------------------------------------------------------------------------------------ |
| Claude Code | `.claude/settings.json` mirrors this file; the `git-workflows` plugin hook is a backstop, not a dependency   |
| Codex       | Instruction only until the PR-2 spike; any execution-policy rules would live in the user-level configuration |
| OpenCode    | Manual contract: read `AGENTS.md` and this file; no parity claim                                             |
| All         | pre-commit (gitleaks, attribution), CI, review. A model can disobey an instruction; these are the backstop   |
