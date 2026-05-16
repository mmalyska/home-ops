#!/bin/bash -i
sudo git config --global --add safe.directory "${1}"
if gpg --list-secret-keys F6F676C60A077962 &>/dev/null; then
  sudo git config --global gpg.program gpg
  sudo git config --global commit.gpgsign true
  sudo git config --global user.signingkey F6F676C60A077962
fi
sudo git config --global pull.rebase true

direnv allow

if [ -n "${CODESPACES}" ]; then
  sudo apt-get install -y --no-install-recommends wireguard-tools iputils-ping
fi

(
  set -x; cd "$(mktemp -d)" &&
  OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
  ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
  KREW="krew-${OS}_${ARCH}" &&
  curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
  tar zxvf "${KREW}.tar.gz" &&
  ./"${KREW}" install krew
)
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> /home/vscode/.zshrc
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"' >> /home/vscode/.bashrc
export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"
kubectl krew install browse-pvc

# npm install -g @mariozechner/pi-coding-agent

echo "Done!"
