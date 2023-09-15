#!/bin/bash -i
git gc --prune=now
brew update
brew upgrade

KUBECONFIG=/home/vscode/.kube/config

task init
task init-subtasks

echo "Done!"
