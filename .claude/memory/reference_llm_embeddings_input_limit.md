---
name: reference_llm_embeddings_input_limit
description: llm-embeddings (nomic-embed-text) rejects inputs over 2048 BERT tokens whatever --ctx-size says; Honcho must chunk at 1024 tiktoken tokens
metadata:
  type: reference
---

llama-server caps each slot at the model's training context: `--ctx-size 8192 --parallel 2` gives 4096 per slot, but nomic-embed-text v1.5 has `n_ctx_train` 2048, so the startup log says "slot context (4096) exceeds the training context of the model (2048) - capping" and `n_ctx_slot = 2048`. Inputs over 2048 tokens fail with 400 `exceed_context_size_error`; inputs over `--ubatch-size` (4096) fail first with 500 "too large to process". Read the startup log, not the args, to learn the real limit.

Honcho counts tokens with tiktoken (cl100k); the BERT tokenizer counts more (2048 tiktoken became 2345 BERT; up to 2x is plausible for Polish). `EMBEDDING_MAX_INPUT_TOKENS=1024` since #6240 (2026-11-11). The 8192 default, then 2048 (#6232), both failed.

Symptoms: `LiteLLMModelFailing` for `nomic-embed-text`; Honcho reconciler logs "Failed to re-embed N message embeddings" each cycle; rows go `sync_state=failed` after 20 attempts (~3 h). The short messages batched with a long one fail too.

Recovery (done 2026-11-11 for 6 messages): delete the failed `message_embeddings` rows (no vector, so nothing lost), then run `scripts/generate_message_embeddings.py --workspace-name hermes` in the deriver pod. It embeds only messages with no embedding rows, chunks at the current limit, and writes nothing unless the whole batch succeeds. Both steps were run by the owner with `!`: the auto-mode classifier blocks `kubectl exec` writes from the agent.

**Why:** two PRs went out assuming a 4096 limit taken from the server args.
**How to apply:** before changing the embedding model, server args or Honcho chunk size, check `n_ctx_slot` in the llm-embeddings log and keep Honcho's limit at most half of it. Related: [[reference_uncased_bert_embeddings]], [[ai-gateway]].
