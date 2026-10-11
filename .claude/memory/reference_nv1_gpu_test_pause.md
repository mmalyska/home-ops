---
name: reference_nv1_gpu_test_pause
description: nv1 has one GPU; a test pod needs llama-server paused through git (selfHeal reverts a scale), about 30-40 min downtime
metadata:
  type: reference
---

nv1 advertises exactly one `nvidia.com/gpu` and `llama-server` holds it, so a GPU test pod needs llama-server down.
`kubectl scale` and patching the Application's `selfHeal` do not stick: `llm-server` self-heals the replica count and the ApplicationSet resets the Application's syncPolicy. Pause through git.

1. PR: `cluster/apps/ai/llm/server/values.yaml` `server.replicaCount: 0`, marked TEMPORARY. Merge, then `kubectl -n argocd annotate application llm-server argocd.argoproj.io/refresh=hard --overwrite` (it only polls every 24h).
2. Test pod in a namespace labelled `pod-security.kubernetes.io/enforce: privileged` (hostPath is refused under baseline), `nodeName: nv1`, `resources.limits.nvidia.com/gpu: 1`, models on a `/var/lib/<name>` hostPath. Mount the parent directory: a `type: Directory` check on a subdirectory failed with "is not a directory".
3. Revert PR (`replicaCount: 1`) right away; delete the namespace and wipe the hostPath with a one-shot pod.

`LlamaServerUnavailable` is critical after 10 minutes and the sequence takes 30-40 minutes with two PR merges, so warn the user and have the revert PR ready before starting. Hermes aux tasks and Honcho fall back to cloud models meanwhile.

**Why:** JetPack 7.2 Ollama benchmark and PTX JIT test, 2026-10-10/11 (PRs #5626, #5631, #5632).
**How to apply:** use before any nv1 GPU experiment (vLLM, a new engine, a benchmark). CUDA image rules: [[reference_jetson_llama_cuda_tag]].
