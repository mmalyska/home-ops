---
name: Always update docs after code changes
description: After making any code/config changes, proactively check and update README.md, CLAUDE.md, and docs/src/ — do not wait to be reminded
type: feedback
---

After completing any non-trivial change to the repository, always proactively check whether these files need updating — without being asked:

- **README.md** — user-facing deployment and setup instructions
- **CLAUDE.md** — developer guide and AI context (task list, patterns, key fields, bootstrap process)
- **docs/src/** — MkDocs site pages (bootstrap.md, network.md, index.md, etc.)
- **.github/mkdocs/mkdocs.yml** — nav must include any new doc pages

Specifically check for:
- New tasks added to .taskfiles/ → update Key Tasks section in CLAUDE.md and README
- New app-config.yaml fields → update the Key Fields example in CLAUDE.md and the schema in .vscode/app-config.schema.json
- Changed bootstrap flow → update README "Bootstrapping the cluster" section, CLAUDE.md "Bootstrap Process" section, and docs/src/k8s/bootstrap.md
- New doc pages → add to mkdocs.yml nav

The user has had to remind Claude to update docs after changes multiple times. Do this proactively as part of every implementation task.

## Where to create new memory files

**Always create new memory files in the git repo at `.claude/memory/` — NEVER in the ephemeral
Claude path (`~/.claude/projects/...`).** The devcontainer `postStartCommand.sh` automatically
symlinks every `*.md` file from `.claude/memory/` into the expected Claude path on container start.

Correct path: `/workspaces/home-ops/.claude/memory/<name>.md`
Wrong path: `/home/vscode/.claude/projects/-workspaces-home-ops/memory/<name>.md`

After creating a new memory file in the repo, also add a pointer line to
`/workspaces/home-ops/.claude/memory/MEMORY.md` (the index).
