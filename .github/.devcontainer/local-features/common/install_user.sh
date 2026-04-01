#!/bin/bash -i

/home/linuxbrew/.linuxbrew/bin/brew update
/home/linuxbrew/.linuxbrew/bin/brew bundle install --file=Brewfile && /home/linuxbrew/.linuxbrew/bin/brew bundle upgrade --file=Brewfile

echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc
echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc
