---
name: ai-gateway
description: LiteLLM gateway in ns ai is the single AI endpoint; how clients, keys, fallback and operations work, and the gotchas hit building it
metadata:
  type: reference
---

All AI clients (Hermes, Honcho, opencode in Coder, Lingarr) call `http://litellm.ai.svc.cluster.local:4000/v1` with their own `LiteLLMVirtualKey` (team-scoped model list, Secret written by the operator). Aliases: `main` = ChatGPT subscription, `cheap` = OpenRouter (13 USD cap, Dragonfly counters), `local` = llama-server on nv1, `embed` = CPU nomic-embed-text. Fallback main → cheap → local. Docs: `docs/src/k8s/ai-gateway.md`; closed plan in `.archive/.plans/superpowers/`.

Operational gotchas:
- `kubectl rollout restart` does nothing (the operator owns the pod template); restart with `kubectl -n ai delete pod -l app.kubernetes.io/name=litellm`. `main` is only built at startup, so a ChatGPT login after startup needs that pod delete.
- A change to `managedNamespaceMetadata` (Pod Security labels) is not applied by auto-sync because the apps use `ApplyOutOfSyncOnly=true`; patch an `operation.sync` with `ApplyOutOfSyncOnly=false` onto the Application.
- Probe the gateway with `kubectl exec -i deploy/litellm -- python3 - < script` using the in-pod `LITELLM_MASTER_KEY`; never read the key into a shell variable.
- The Jetson's llama-server is not hardened (owner's decision; `llm` stays on Pod Security `baseline`), but since #5955 it has an ingress-only NetworkPolicy: only the gateway and Prometheus reach it. Clients must use the `local` alias.
- Lingarr's key is entered in its UI, not via env: [[lingarr-api-key-ui-only]].

**Why:** these cost real debugging time (rollout deadlock, stale labels, missing `main`). **How to apply:** read this before touching the gateway or adding a client; a new client also needs adding to the `litellm` NetworkPolicy.
