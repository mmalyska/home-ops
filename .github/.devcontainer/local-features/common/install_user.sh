#!/bin/bash -i

echo $PATH

/home/linuxbrew/.linuxbrew/bin/brew config

brew install age ansible direnv gitleaks go-task/tap/go-task helm ipcalc jq kubectl kustomize prettier sops stern terraform yamllint yq argocd int128/kubelogin/kubelogin ansible-lint k9s pre-commit mkdocs
