#!/bin/bash -i
git gc --prune=now
brew update
brew upgrade
task ansible:init
task terraform:upgrade:cloudflare

echo "Done!"
