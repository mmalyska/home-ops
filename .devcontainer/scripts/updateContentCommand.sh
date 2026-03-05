#!/bin/bash -i
git gc --prune=now

KUBECONFIG=/home/vscode/.kube/config

eval "$(direnv export bash)"
task init
task init-subtasks

echo "Done!"
