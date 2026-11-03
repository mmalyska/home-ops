#!/bin/bash -i
git config --global --add safe.directory "${1}"
if gpg --list-secret-keys F6F676C60A077962 &>/dev/null; then
  git config --global gpg.program gpg
  git config --global commit.gpgsign true
  git config --global user.signingkey F6F676C60A077962
fi
git config --global pull.rebase true

direnv allow

chezmoi init --apply mmalyska/dotfiles

if [ -n "${CODESPACES}" ]; then
  sudo apt-get install -y --no-install-recommends wireguard-tools iputils-ping
fi

# The dev-workstation image ships kubectl-browse_pvc, so krew is only needed where it is missing.
if ! kubectl browse-pvc --help &>/dev/null; then
  (
    set -x; cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    tar zxvf "${KREW}.tar.gz" &&
    ./"${KREW}" install krew
  )
  KREW_PATH_LINE='export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"'
  for rc in "${HOME}/.zshrc" "${HOME}/.bashrc"; do
    # .zshrc is only touched when zsh is installed
    if [ "${rc}" = "${HOME}/.zshrc" ] && ! command -v zsh >/dev/null 2>&1; then continue; fi
    grep -qxF "${KREW_PATH_LINE}" "${rc}" 2>/dev/null || echo "${KREW_PATH_LINE}" >> "${rc}"
  done
  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
  kubectl krew install browse-pvc
fi

# npm install -g @mariozechner/pi-coding-agent

echo "Done!"
