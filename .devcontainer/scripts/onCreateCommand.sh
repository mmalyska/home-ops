#!/bin/bash -i
sudo git config --system --add safe.directory "${1}"

brew install go-task/tap/go-task

task init
task precommit:init
task ansible:init
task terraform:init:cloudflare

# shellcheck disable=SC2016
echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc
# shellcheck disable=SC2016
echo 'eval "$(direnv hook bash)"' >> ~/.bashrc
direnv allow

echo "Done!"
