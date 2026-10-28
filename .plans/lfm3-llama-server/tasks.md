# Tasks: LFM3-1.7B on nv1

- [ ] Confirm `ghcr.io/mmalyska/llama-cpp-jetson:v0.8.0` is published (run mmalyska/containers/actions/runs/40725111771) and note its digest.
- [ ] Bump image tag+digest in `cluster/apps/ai/llm/server/values.yaml`; render with `helm template llama-server cluster/apps/ai/llm/server -f cluster/apps/ai/llm/server/values.yaml`.
- [ ] Switch `server.model` to LFM3-1.7B Q8_0 (url https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q8_0.gguf, size 1846238496, sha256 8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6), new alias, `-np 1` first.
- [ ] No pause window (ArgoCD selfHeal reverts manual scales and test pods; syncPolicy.enabled:false is a last resort, see #5290). The real llama-server pod is the test subject: merge the values change, ArgoCD Recreates the pod onto LFM3, run the checks against it. Rollback = revert the PR. Confirm with the owner before merging (it swaps the live model for Lingarr/Honcho/Hermes).
- [ ] Verify startup log: `ggml_cuda_init: found 1 CUDA devices`, full offload, `lfm3` arch loaded, chat template tool-call format.
- [ ] Run the corruption harness at -np 1, then -np 2 and 4; keep multi-slot only if 0 corrupt turns.
- [ ] Sample a real Lingarr EN->PL batch and compare against Gemma output.
- [ ] Update `cluster/apps/ai/litellm/templates/models/local.yaml` alias, docs and memory files; `task lint:all`.
- [ ] Open PR from `feat/lfm3-llama-server`; after merge, archive the plan to `.archive/.plans/` and update both list.md files.
- [ ] After the single-model test: choose the multi-model layout (router mode vs CPU pods vs GPU time-slicing; one GPU unit, see plan.md) and map roles to LiteLLM aliases (main, route, translate, vision, embed).
- [ ] (Optional, if router mode falls short) Fork schwankner/talos-jetson-orin `plugins/jetson-device-plugin`: advertise N device IDs from a `GPU_REPLICAS` env var, build as `ghcr.io/mmalyska/jetson-device-plugin` in mmalyska/containers, bump `cluster/apps/system/nvidia/resources/device-plugin.yaml` (cluster change: confirm first), then verify `nvidia.com/gpu: N` allocatable on nv1.
