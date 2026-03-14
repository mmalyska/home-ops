---
name: Memory must be written to repo, not home directory
description: /home/vscode/ is ephemeral in the devcontainer — always write memory files to /workspaces/home-ops/.claude/memory/
type: feedback
---

Always write memory files to `/workspaces/home-ops/.claude/memory/`, NOT to `/home/vscode/.claude/projects/...`.

**Why:** The devcontainer's home directory (`/home/vscode/`) is ephemeral and lost on container rebuild. The workspace mount (`/workspaces/home-ops/`) is persisted.

**How to apply:** Every time you would write a memory file, use `/workspaces/home-ops/.claude/memory/` as the base path. Update `/workspaces/home-ops/.claude/memory/MEMORY.md` as the index.
