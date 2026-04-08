# home-ops Repository Memory

## Memory Location
**All memory is now stored in beads.** Use `bd remember "..."` to save and `bd memories <keyword>` to search.

Do NOT write new `.md` memory files. The old file-based memory has been fully migrated to beads.

## Standing Rules (search beads for full content)

- `bd memories docs` — always update README/CLAUDE.md/docs proactively after changes
- `bd memories render` — always verify rendered manifests after Helm/Kustomize changes
- `bd memories gateway` — check native Gateway API support before writing manual HTTPRoute
- `bd memories skills` — learned skills go to `/workspaces/home-ops/.claude/skills/learned/`
- `bd memories nvgpu patch` — full 5-step audit required after every nvgpu patch change
- Never write secrets, tokens, passwords, or sensitive data to any repo file
- The private domain is a secret — use `<secret:private-domain>` placeholder only
- Secret values belong in Bitwarden Secrets Manager only
