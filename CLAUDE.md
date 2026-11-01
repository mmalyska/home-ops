# Claude Code Instructions

@AGENTS.md

Claude-specific facts only. Everything that applies to every harness is in `AGENTS.md`.

## Claude Code Adapter

- `.claude/settings.json` is the Claude enforcement of the permission matrix in `.agents/policy/permissions.md`. Change them together; `bash .agents/tests/run.sh` checks they agree.
- The `git-workflows` plugin hook that guards the primary checkout is a backstop. The worktree rule in `AGENTS.md` does not depend on it.
- A command that the permission rules block or ask about can be run by the user with the `!` prefix in the prompt, so its output lands in the session.
- `.claude/skills/` is generated from `.agents/skills/` by `.agents/bin/sync-skills`. Edit a skill in `.agents/skills/`, run the script and commit both; never edit `.claude/skills/` by hand.
- The statusline is configured in `.claude/statusline/settings.json`.

## Memory

Memory files and the `MEMORY.md` index live in `.claude/memory/` (git-tracked). `~/.claude/projects/-workspaces-home-ops/memory/` only holds symlinks into it, and anything written there directly is lost on a devcontainer rebuild.

Future memory edits go to `.claude/memory/` directly and get committed on the branch I'm working on.
