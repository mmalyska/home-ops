#!/bin/bash -i
eval "$(direnv export bash)"
task talos:init

# Symlink all Claude Code memory files from repo into the expected location.
# New memory files should be created in .claude/memory/ in the repo (not in the ephemeral dir)
# and they will be automatically linked on next container start.
MEMORY_DIR="${HOME}/.claude/projects/-workspaces-home-ops/memory"
mkdir -p "${MEMORY_DIR}"
for f in /workspaces/home-ops/.claude/memory/*.md; do
  ln -sf "${f}" "${MEMORY_DIR}/$(basename "${f}")"
done

echo "Done!"
