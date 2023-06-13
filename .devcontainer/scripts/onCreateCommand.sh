#!/bin/bash -i
sudo git config --global --add safe.directory "${1}"
sudo git config --global gpg.program gpg

direnv allow

task init
task precommit:init
task ansible:init
task terraform:init:cloudflare

echo "Done!"
