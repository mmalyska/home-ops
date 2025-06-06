#!/bin/bash -i

/home/linuxbrew/.linuxbrew/bin/brew install age direnv gitleaks go-task/tap/go-task helm ipcalc jq kubectl kustomize prettier sops stern terraform yamllint yq argocd int128/kubelogin/kubelogin k9s pre-commit mkdocs

echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc
echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc
