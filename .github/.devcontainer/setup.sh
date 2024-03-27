#!/bin/bash -i
sudo git config --global --add safe.directory "${1}"
sudo git config --global gpg.program gpg
sudo git config --global commit.gpgsign true
sudo git config --global user.signingkey F6F676C60A077962
sudo git config --global pull.rebase true

echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc
echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc

direnv allow

task init

echo "Done!"
