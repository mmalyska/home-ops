# home-ops Repository Memory

## Feedback — How to Work

- [Update plan tasks as work completes](feedback_update_plan_tasks.md) — mark tasks.md [x] immediately after each item is done, not in batch at end
- [Always update docs after code changes](feedback_update_docs.md) — proactively update CLAUDE.md/docs/README after any non-trivial change
- [Always verify rendered manifests](feedback_verify_manifests.md) — helm template / kubectl kustomize after every values.yaml edit
- [Check native Gateway API support first](feedback_check_native_gateway.md) — before writing manual HTTPRoute, check chart values
- [Deployment strategy patch required](feedback_deployment_strategy_patch.md) — RollingUpdate→Recreate needs live object kubectl patch before ArgoCD sync
- [Claude files belong in workspace .claude/](feedback_claude_files_in_workspace.md) — skills/config/artifacts go in /workspaces/home-ops/.claude/, not ~/.claude/ (ephemeral)
- [Cluster access permission rules](feedback_cluster_access_rules.md) — read-only free, mutating ops need user confirmation
- [talosctl talosconfig location](feedback_talosctl_config.md) — use TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
- [Non-interactive shell flags](feedback_noninteractive_shell.md) — always use -f/-rf for cp/mv/rm (aliased to -i in devcontainer)
- [Always push and open PR after branch work](feedback_push_and_pr_after_branch.md) — push + gh pr create immediately after committing on a feature branch

## Project Context

- [Secrets architecture (post-2026-03-11)](project_secrets_architecture.md) — three mechanisms; when to use each

## Reference

- [Gateway and DNS architecture](reference_gateway_dns_architecture.md) — two Envoy Gateway instances; HTTPRoute annotation rules
- [Home network hardware](reference_home_network_hardware.md) — router/NAS/RPi IPs and roles
