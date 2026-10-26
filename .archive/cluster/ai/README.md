# Archived AI stack (Hermes, Honcho, embeddings, speech-to-text)

Archived 2026-10-21. The stack was not in use: Hermes needs paid API access and only a Claude subscription was available.
Plan: `.archive/.plans/superpowers/plans/2026-10-21-remove-hermes-stack.md`.

| Directory | What it was |
|-----------|-------------|
| `hermes-agent` | Hermes agent (Discord, Signal, SSH terminal backend into Coder workspaces) |
| `llm-stt` | speaches speech-to-text for Hermes (was `llm/stt`) |

Restored 2026-10-26 behind the AI gateway: `honcho` (`cluster/apps/ai/honcho`) and `llm-embeddings` (`cluster/apps/ai/llm/embeddings`). Honcho now has an empty `honchodb` and no provider key; see `docs/src/k8s/ai-gateway.md`.

Still running: `cluster/apps/ai/llm/server` (llama-server on nv1, used by Lingarr) and `cluster/apps/ai/coder` (`devops` workspace only).
Renovate ignores `.archive/**` and the ApplicationSets only read `cluster/apps/**`, so nothing here is deployed or updated.

## Restore

1. `git mv .archive/cluster/ai/hermes-agent cluster/apps/ai/hermes-agent`, same for `honcho`.
2. `git mv .archive/cluster/ai/llm-embeddings cluster/apps/ai/llm/embeddings`, same for `llm-stt` to `stt`.
   Append each one's `app-config.yaml` as a list item to `cluster/apps/ai/llm/app-config.yaml` and add `appSubfolder: embeddings` or `appSubfolder: stt`.
   Then `git rm` the leftover `app-config.yaml` inside the moved directory.
3. **No data was kept.** Honcho needs a new empty `honchodb`, Hermes needs new PVCs, and the Bitwarden secrets named in each `externalsecret.yaml` must exist again.
4. Re-add the Renovate rule for `nousresearch/hermes-agent` from the history of `.github/renovate/groups.json5`.
5. Hermes refuses models with under 64K context per slot: check `cluster/apps/ai/llm/server/values.yaml` still gives that.
6. Re-create the Coder workspaces Hermes profiles pointed at, if needed (see `cluster/apps/ai/coder/README.md`).
