#!/bin/bash -i
eval "$(direnv export bash)"
task talos:init

# Symlink Claude Code memory file from repo into the expected location
MEMORY_DIR="${HOME}/.claude/projects/-workspaces-home-ops/memory"
mkdir -p "${MEMORY_DIR}"
ln -sf "/workspaces/home-ops/.claude/memory/MEMORY.md" "${MEMORY_DIR}/MEMORY.md"

echo "Done!"
