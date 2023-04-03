#!/bin/bash -i
sudo git config --system --add safe.directory "${1}"

direnv allow

task init
task precommit:init
task ansible:init
task terraform:init:cloudflare

echo "Done!"
