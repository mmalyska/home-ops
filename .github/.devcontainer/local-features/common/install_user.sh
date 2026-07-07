#!/bin/bash

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"

/home/linuxbrew/.linuxbrew/bin/brew update
/home/linuxbrew/.linuxbrew/bin/brew trust go-task/tap
/home/linuxbrew/.linuxbrew/bin/brew trust hashicorp/tap
/home/linuxbrew/.linuxbrew/bin/brew trust int128/kubelogin
/home/linuxbrew/.linuxbrew/bin/brew bundle install --file=Brewfile && /home/linuxbrew/.linuxbrew/bin/brew bundle upgrade --file=Brewfile

echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc
echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc

npm install -g @anthropic-ai/claude-code
