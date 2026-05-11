# home-ops Repository Memory

## Feedback — How to Work

- [Update plan tasks as work completes](feedback_update_plan_tasks.md) — mark tasks.md [x] immediately after each item is done, not in batch at end
- [Always update docs after code changes](feedback_update_docs.md) — proactively update CLAUDE.md/docs/README after any non-trivial change
- [Always verify rendered manifests](feedback_verify_manifests.md) — helm template / kubectl kustomize after every values.yaml edit
- [Check native Gateway API support first](feedback_check_native_gateway.md) — before writing manual HTTPRoute, check chart values
- [Deployment strategy patch required](feedback_deployment_strategy_patch.md) — RollingUpdate→Recreate needs live object kubectl patch before ArgoCD sync
- [nvgpu patch 5-step safety audit](feedback_nvgpu_patch_audit.md) — mandatory after every nvgpu-kernel-compat.patch change
- [nvidia-oot conftest static header approach](feedback_nvidia_oot_conftest.md) — conftest.sh silently fails; use static NV_* compat header instead
- [Claude files belong in workspace .claude/](feedback_claude_files_in_workspace.md) — skills/config/artifacts go in /workspaces/home-ops/.claude/, not ~/.claude/ (ephemeral)
- [Cluster access permission rules](feedback_cluster_access_rules.md) — read-only free, mutating ops need user confirmation
- [talosctl talosconfig location](feedback_talosctl_config.md) — use TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
- [Non-interactive shell flags](feedback_noninteractive_shell.md) — always use -f/-rf for cp/mv/rm (aliased to -i in devcontainer)

## Project Context

- [Jetson GPU (nvgpu) project — nv1](project_jetson_nvgpu.md) — Phase 3 in progress; Orin NX 16GB at .48.5; pkgs+extensions fork details
- [siderolabs-extensions fork](project_siderolabs_extensions_fork.md) — mmalyska fork feat/jetson-nvgpu; produces talos-nv1-installer image
- [siderolabs-pkgs fork](project_siderolabs_pkgs_fork.md) — mmalyska fork feat/jetson-nvgpu; produces nvgpu-driver-pkg
- [Orin /dev/nvgpu device layout](project_orin_dev_nvgpu_layout.md) — /dev/nvgpu is a directory; use /dev/nvgpu/igpu0/* in device lists
- [Jetson container runtime — CSV not CDI](project_jetson_container_runtime.md) — use nvidia-container-runtime CSV/Tegra mode for Orin
- [Secrets architecture (post-2026-03-11)](project_secrets_architecture.md) — three mechanisms; when to use each

## Reference

- [Gateway and DNS architecture](reference_gateway_dns_architecture.md) — two Envoy Gateway instances; HTTPRoute annotation rules
- [L4T packages for CUDA on Orin](reference_l4t_packages.md) — t234 repo URLs, libcuda.so.1 location
- [Home network hardware](reference_home_network_hardware.md) — router/NAS/RPi IPs and roles
- [Plans and TODOs location](reference_plans_todos.md) — `.plans/` for plans, `.plans/TODO.md` for ad-hoc tasks
