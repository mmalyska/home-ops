# home-ops Repository Memory

## Feedback — How to Work

- [Always update docs after code changes](feedback_update_docs.md) — proactively update CLAUDE.md/docs/README after any non-trivial change
- [Always verify rendered manifests](feedback_verify_manifests.md) — helm template / kubectl kustomize after every values.yaml edit
- [Check native Gateway API support first](feedback_check_native_gateway.md) — before writing manual HTTPRoute, check chart values
- [Deployment strategy patch required](feedback_deployment_strategy_patch.md) — RollingUpdate→Recreate needs live object kubectl patch before ArgoCD sync
- [Claude files belong in workspace .claude/](feedback_claude_files_in_workspace.md) — config/artifacts go in /workspaces/home-ops/.claude/, not ~/.claude/ (ephemeral); skills are edited in .agents/skills
- [Cluster access permission rules](feedback_cluster_access_rules.md) — read-only free, mutating ops need user confirmation
- [talosctl talosconfig location](feedback_talosctl_config.md) — use TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
- [Push and PR only on instruction](feedback_push_and_pr_after_branch.md) — no standing authorization (D4); commit is allowed, push and gh pr create need an instruction
- [Never write the private domain literally](feedback_no_domain_in_comments.md) — not in comments, not in memory files; grep before writing
- [Grafana: no anonymous access, ever](feedback_grafana_no_anonymous_access.md) — user's explicit call, even though Grafana route is LAN-only

## Project Context

- [Secrets architecture (post-2026-03-11)](project_secrets_architecture.md) — three mechanisms; when to use each
- [Plans location convention](project_plans_location_convention.md) — plans in .plans/<slug>/ for every harness, finished ones in .archive/.plans/ (history, not instructions); .plans/superpowers/ is legacy

## Reference

- [Gateway and DNS architecture](reference_gateway_dns_architecture.md) — two Envoy Gateway instances; HTTPRoute annotation rules
- [Home network hardware](reference_home_network_hardware.md) — router/NAS/RPi IPs and roles
- [QNAP QuObjects + barman-cloud caveat](reference_qnap_s3_barman_caveat.md) — boto3 ≥1.34 checksum fix required; set AWS_REQUEST_CHECKSUM_CALCULATION=when_required on all CNPG ObjectStores
- [App removal procedure](reference_app_removal_procedure.md) — deleting the app dir never auto-prunes; manual `kubectl delete application` + separate PVC check required
- [Ceph alert job scoping gotcha](reference_ceph_alert_job_scoping.md) — Ceph-mixin PrometheusRules lack job filters, can false-positive on non-cluster targets (router); fix via prometheusRuleOverrides
- [Talos taints need manual kubectl on registered nodes](reference_talos_taint_noderestriction.md) — NodeRestriction blocks workers changing taints after registration (official, no Talos fix); kubectl taint as admin, then Talos adopts; steps in the talos-node-taints skill
- [Talos workload isolation (sandboxd)](reference_talos_workload_isolation.md) — on for all four nodes since 2026-10-07; the v1.14 contract base carries it on, the repo sets it explicitly (guarded); switching needs a node reboot
- [llama-server nv1 memory budget](reference_llama_server_nv1_memory.md) — default cache/checkpoints OOM the node; 12Gi limit kills pod; thinking off by default
- [nv1 CUDA image rules](reference_jetson_llama_cuda_tag.md) — JetPack 7 runs CUDA 13; builds without native sm_87 code need libnvidia-ptxjitcompiler (in the CDI libs since #5630)
- [nv1 GPU test needs llama-server paused](reference_nv1_gpu_test_pause.md) — one GPU; pause via git replicaCount 0 (selfHeal reverts a scale), 30-40 min, critical alert after 10
- [nv1 META DHCP key](reference_nv1_meta_dhcp.md) — Talos META 0x0a DHCP operator flapped IP, restarted kubelet, GPU dropped to 0
- [Uncased BERT embeddings](reference_uncased_bert_embeddings.md) — llama-server lowercases nomic-embed-text, Ollama does not; no re-embed needed
- [Hermes 64K context floor](reference_hermes_64k_context_floor.md) — Hermes stack archived 2026-10-21 (restore: .archive/cluster/ai/README.md); it rejects models <64K context per slot
- [Matter/Thread cross-VLAN setup](reference_matter_thread_cross_vlan.md) — prod HA/OTBR not in repo; static route + firewall + mDNS needed for phone commissioning
- [Music Assistant in the cluster](reference_music_assistant_cluster.md) — VLAN 48 macvlan .62; base_url vs bind_port gotchas; NFS library via k8s volume; edit provider settings in the UI, never settings.json while running
- [Check live IPs before assigning one](feedback_check_live_ips_before_assigning.md) — list live LB IPs + pools first; update the network.md table in the same PR
- [CoreDNS/Argo bootstrap deadlock](reference_coredns_argo_bootstrap_deadlock.md) — deleting coredns kills Argo's DNS; create the app before deleting
- [Talos live config + apply health quirk](reference_talos_live_config_yq_spec.md) — yq needs two passes on .spec; task talos:apply health step fails on cp nodes after a good apply
- [tuppr upgrades](reference_tuppr_upgrades.md) — os:admin credential in tuppr's Secret, pre-hooks suppress inter-batch checks, Failed terminal until reset, nv1 alias tag and run-wide PrePullFailed
- [Qwen3.6 on nv1 benchmark](reference_qwen36_nv1_benchmark.md) — 35B-A3B at 2-bit loads but leaves 0.4 GB node headroom; IQ2_M fails to load; next step is hardware
- [Gemma 4 single slot on nv1](reference_gemma4_single_slot_swap.md) — SUPERSEDED by LFM3 2026-10-28, history only; served 2026-10-15 to 10-28; 0/66 corrupt; -np 2 and bigger prompt cache do not fit; watch node MemAvailable not kubectl top
- [QNAP /media share layout](reference_qnap_media_share_layout.md) — one share mounted as /data by all media pods; hardlinks need a single mount; File Station cannot write, use a root pod; old shares retire 2026-10-30
- [Talos log shipping to Loki](reference_talos_log_shipping.md) — UDP via Alloy loki.source.syslog raw (TCP stalls minutes after a receiver pod restart); Alloy/ArgoCD gotchas hit building it
- [container_fs_writes double count](reference_container_fs_writes_double_count.md) — pod-level series next to per-container ones; unfiltered sums are 2x; use container!=""
- [LAN route for external-only apps](reference_lan_route_for_external_apps.md) — external-only HTTPRoute gets no AdGuard record, LAN traffic hairpins via Cloudflare (114 KB/s uploads); add an envoy-internal route
- [AI gateway](reference_ai_gateway.md) — LiteLLM endpoint, aliases, restart/label-sync/probe gotchas; Jetson llama-server has an ingress policy only
- [Lingarr API key is UI-only](reference_lingarr_api_key_ui_only.md) — LOCAL_AI_API_KEY env sends no header (401/500); paste the key in the UI, never restart before the env is gone
- [Drop Gemma, go multi-model on nv1](project_nv1_drop_gemma_multi_model.md) — owner decision 2026-10-28; LFM3 + tailored models, plan in .archive/.plans/lfm3-llama-server
- [Bazarr and Lingarr translation behaviour](reference_bazarr_lingarr_translation.md) — 40-line batches, Bazarr upgrades from opensubtitles overwrite translations, read the history DB to see the real origin
- [Ceph OSD discard](reference_ceph_osd_discard.md) — bdev_async_discard alone does nothing; both options on since 2026-10-29, owner accepted ~2 ms extra write latency; wear check 2026-11-12
