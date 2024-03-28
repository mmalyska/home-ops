#!/bin/bash -i
echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc
echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc

direnv allow

task init

echo "Done init!"
