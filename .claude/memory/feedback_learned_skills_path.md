---
name: Learned skills must go to workspace path
description: Save learned skills to /workspaces/home-ops/.claude/skills/learned/ not ~/.claude/skills/learned/
type: feedback
---

Save learned skills to `/workspaces/home-ops/.claude/skills/learned/` NOT `~/.claude/skills/learned/`.

**Why:** The devcontainer is ephemeral — `/home/vscode/.claude/` is lost on rebuild. The workspace path is in the repo volume and symlinked by the devcontainer on start.

**How to apply:** Any time writing a new skill file, always use the workspace-rooted path.
