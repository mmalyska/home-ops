#!/bin/bash -i
git gc --prune=now

eval "$(direnv export bash)"
task init
task precommit:init
task cilium:init
if [ -z "${CODESPACES}" ]; then
  task terraform:upgrade:cloudflare
  task talos:init
fi

echo "Done!"
