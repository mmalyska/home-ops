#!/bin/bash

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"

# .envrc sets this via direnv for every later shell in the repo; brew's tap/formula
# trust store location depends on it, so it must match here too or trust granted
# during image build won't be found once direnv is active (see task init failures).
export XDG_CONFIG_HOME="$HOME/.config"

/home/linuxbrew/.linuxbrew/bin/brew update
/home/linuxbrew/.linuxbrew/bin/brew trust go-task/tap
/home/linuxbrew/.linuxbrew/bin/brew trust hashicorp/tap
/home/linuxbrew/.linuxbrew/bin/brew trust int128/kubelogin
/home/linuxbrew/.linuxbrew/bin/brew bundle install --file=Brewfile && /home/linuxbrew/.linuxbrew/bin/brew bundle upgrade --file=Brewfile

echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc
echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc

npm install -g @anthropic-ai/claude-code
