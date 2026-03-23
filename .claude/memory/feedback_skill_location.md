---
name: Learned skills location
description: Learned skill files must be saved to the workspace .claude folder, not ~/.claude, to survive container rebuilds
type: feedback
---

Always save learned skills to `/workspaces/home-ops/.claude/skills/learned/` — NOT to `~/.claude/skills/learned/`.

**Why:** The devcontainer is ephemeral. `/home/vscode/.claude/` is lost on rebuild. The workspace path `/workspaces/home-ops/.claude/` is persisted (it's inside the repo volume) and symlinked by the devcontainer on start.

**How to apply:** Any time `/learn` or a similar skill-extraction flow produces files destined for `~/.claude/skills/learned/`, redirect to `/workspaces/home-ops/.claude/skills/learned/` instead.
