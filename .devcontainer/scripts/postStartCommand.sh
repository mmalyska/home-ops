#!/bin/bash -i
eval "$(direnv export bash)"
if [ -z "${CODESPACES}" ]; then
  task talos:init
fi

if [ -n "${CODESPACES}" ] && [ -n "${WG_PRIVATE_KEY}" ]; then
  envsubst '${WG_PRIVATE_KEY} ${WG_ENDPOINT}' \
    < /workspaces/home-ops/.devcontainer/wireguard/wg0.conf.tmpl \
    | sudo tee /etc/wireguard/wg0.conf > /dev/null
  sudo chmod 600 /etc/wireguard/wg0.conf
  sudo wg-quick up wg0
fi

# Symlink all Claude Code memory files from repo into the expected location.
# New memory files should be created in .claude/memory/ in the repo (not in the ephemeral dir)
# and they will be automatically linked on next container start.
MEMORY_DIR="${HOME}/.claude/projects/-workspaces-home-ops/memory"
mkdir -p "${MEMORY_DIR}"
for f in /workspaces/home-ops/.claude/memory/*.md; do
  ln -sf "${f}" "${MEMORY_DIR}/$(basename "${f}")"
done

echo "Done!"
