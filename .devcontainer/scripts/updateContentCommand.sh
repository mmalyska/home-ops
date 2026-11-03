#!/bin/bash -i
git gc --prune=now

eval "$(direnv export bash)"
task init
task precommit:init
task cilium:init
if [ -z "${CODESPACES}" ]; then
  task terraform:upgrade:cloudflare
  # The Coder workspace has no TALHELPER_* secrets (it uses a mounted os:reader config).
  if [ -n "${TALHELPER_OSCERT}" ]; then
    task talos:init
  fi
fi

echo "Done!"
