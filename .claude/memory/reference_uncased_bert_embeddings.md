---
name: reference_uncased_bert_embeddings
description: nomic-embed-text is uncased BERT; llama-server lowercases input but Ollama >=0.20 does not, so Ollama vectors drift with text case
metadata:
  type: reference
---

llama-server (llm-embeddings) lowercases text for `nomic-embed-text`; Ollama 0.20.5 does not, so its vectors for mixed-case text differ (cosine 0.44-0.93 vs llama-server, 0.99999 once lowercased). Honcho's stored vectors match llama-server exactly (cos 1.00000), which is why moving embeddings to llama-server needed no re-embed (S4, 2026-09-25).

**Why:** a raw cosine gate against Ollama looked like a failure; the real cause was Ollama's missing lowercasing.
**How to apply:** when comparing embeddings across engines, compare on lowercased input first; do not re-embed stored vectors just because a cross-engine check on mixed-case text falls below 0.999.
