---
name: lingarr-api-key-ui-only
description: Lingarr (1.4.1) sends no Authorization header for a LOCAL_AI_API_KEY env var; the key must be entered in the UI, which stores it encrypted
metadata:
  type: reference
---

Lingarr's `LOCAL_AI_API_KEY` env var is written to the `settings` table (`/app/config/local.db`) as plain text and the logs say "Updated setting", but the gateway then answers 401 "No api key passed in" (Bazarr sees a 500). A key saved in Settings, Translation, Local AI is stored encrypted (`CfDJ8...`, keys in `/app/config/keys`) and works (200s, verified 2026-10-26). Cause of the plain-value failure not found; the docs list the env var as supported.

**Why:** the key for the `lingarr` team (`LiteLLMVirtualKey`, Secret `lingarr-litellm` in `media`) cannot be GitOps-injected. Rotating the virtual key means pasting the new one into the UI again.

**How to apply:**
- Do not set `LOCAL_AI_API_KEY` (or `_FILE`) in `cluster/apps/media/lingarr/values.yaml`; a restart would overwrite the UI value with the plain one.
- Reading `local.db` for checks: copy `local.db`, `-wal` and `-shm` together, or the result is stale; print lengths and shape only, never the key.
- Lingarr has `auth_enabled` on, so its settings API needs a login; use the UI.
- Related: [[reference-ai-gateway]]
