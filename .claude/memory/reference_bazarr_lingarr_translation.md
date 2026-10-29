---
name: bazarr-lingarr-translation
description: How Bazarr and Lingarr behave when translating subtitles, and how to find what really produced a Polish .srt (Bazarr history DB)
metadata:
  type: reference
---

- Lingarr translates in **40-line batches** (log "Progress: 12% (Subtitle 40 of 330)"), not the whole file; a 330-cue episode took 32 s on the `cheap` alias (2026-10-29).
- Bazarr's score for a translated subtitle is a fixed-looking number (251/360 = 69.72% for its own translator, 288/360 for Lingarr), not a quality score.
- **Bazarr silently replaces translations**: it upgrades the Polish file from opensubtitlescom later (Fuller House, 2026-10-27), so a `.pl.srt` on disk is not necessarily the translator's output. Check the real origin read-only: `kubectl exec -n media deploy/bazarr -- python3 -c` with `sqlite3.connect("file:/config/db/bazarr.db?mode=ro", uri=True)` and table `table_history` (columns action, provider, score, description, subtitles_path; action 6 = translated, 3 = upgraded, 1 = downloaded, 7 = extracted). `table_episodes.missing_subtitles` lists missing languages.
- A subtitle credit cue ("translated with gemini-3.5-flash") in cue 1 identifies the translator of that file.
- Lingarr logs an "API settings are not configured correctly" error before each run; it does not stop the translation (not investigated).
- After changing the model in git, Lingarr's UI value overrides the env: set it in the UI too. Related: [[lingarr-api-key-ui-only]], [[ai-gateway]]
