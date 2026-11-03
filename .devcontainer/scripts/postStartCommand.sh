#!/bin/bash -i
REPO_ROOT="$(git rev-parse --show-toplevel)"
eval "$(direnv export bash)"

if [ -n "${CODESPACES}" ] && [ -n "${WG_PRIVATE_KEY}" ]; then
  if ! sudo wg show wg0 &>/dev/null; then
    envsubst '${WG_PRIVATE_KEY} ${WG_ENDPOINT}' \
      < "${REPO_ROOT}"/.devcontainer/wireguard/wg0.conf.tmpl \
      | sudo tee /etc/wireguard/wg0.conf > /dev/null
    sudo chmod 600 /etc/wireguard/wg0.conf
    sudo wg-quick up wg0
  fi
  if ! grep -q "^nameserver 192.168.50.9$" /etc/resolv.conf; then
    tmp=$(mktemp)
    { echo "nameserver 192.168.50.9"; echo "options timeout:1 attempts:1"; cat /etc/resolv.conf; } > "$tmp"
    cat "$tmp" > /etc/resolv.conf
    rm "$tmp"
  fi
fi

# The Coder workspace has no TALHELPER_* secrets and reaches Talos through a mounted os:reader config.
if [ -n "${TALHELPER_OSCERT}" ]; then
  task talos:init
fi

# Symlink all Claude Code memory files from repo into the expected location.
# New memory files should be created in .claude/memory/ in the repo (not in the ephemeral dir)
# and they will be automatically linked on next container start.
PROJECT_KEY="$(printf '%s' "${REPO_ROOT}" | sed 's/[^A-Za-z0-9]/-/g')"
MEMORY_DIR="${HOME}/.claude/projects/${PROJECT_KEY}/memory"
mkdir -p "${MEMORY_DIR}"
for f in "${REPO_ROOT}"/.claude/memory/*.md; do
  [ -e "${f}" ] && ln -sf "${f}" "${MEMORY_DIR}/$(basename "${f}")"
done

echo "Done!"
