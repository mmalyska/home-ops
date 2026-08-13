---
name: feedback-claude-files-in-workspace
description: Claude skills, settings, memory and artifacts belong in /workspaces/home-ops/.claude/, never in ~/.claude/, which is ephemeral devcontainer home and is lost on rebuild
metadata:
  type: feedback
---

Write Claude-related files to `/workspaces/home-ops/.claude/` — the git-tracked
workspace directory — not to `~/.claude/` (`/home/vscode/.claude/`).

Tracked in the repo under `.claude/`:

- `skills/` — project skills (`add-app`, `cluster-reference`, `dev-workflow`, …)
- `memory/` — memory files and `MEMORY.md`
- `settings.json`, `statusline/`

`~/.claude/` holds only devcontainer-local runtime state: `.credentials.json`,
`cache/`, `history.jsonl`, `file-history/`, `ide/`, `backups/`, `hooks/`.

**Why:** `~/.claude/` lives in the devcontainer's home directory, which is
rebuilt from the image. Anything written there is silently lost on the next
rebuild, and it is invisible to git, code review and every other machine. The
workspace copy is versioned, reviewable and portable.

**How to apply:** Before writing any Claude file, check the destination path. If
it resolves under `/home/vscode/.claude/`, redirect it to
`/workspaces/home-ops/.claude/`.

The project-memory directory is the trap worth knowing:
`~/.claude/projects/-workspaces-home-ops/memory/` is a **real directory whose
entries are symlinks** into `/workspaces/home-ops/.claude/memory/`. Because the
directory itself is not a symlink, a newly created file lands there as a real
file and looks correct while being ephemeral. After creating a memory, verify
and fix:

```sh
ls -l ~/.claude/projects/-workspaces-home-ops/memory/   # every entry should be a symlink
mv -f ~/.claude/projects/-workspaces-home-ops/memory/<f> /workspaces/home-ops/.claude/memory/<f>
ln -sfn /workspaces/home-ops/.claude/memory/<f> ~/.claude/projects/-workspaces-home-ops/memory/<f>
```

Editing `MEMORY.md` through the symlinked path is refused outright ("Refusing to
write through symlink") — edit `/workspaces/home-ops/.claude/memory/MEMORY.md`
directly.

Related: [[project-plans-location-convention]] — the same instinct applied to
plans, which live in `docs/superpowers/` rather than where CLAUDE.md documents.
