#!/bin/bash -i
git gc --prune=now

KUBECONFIG=/home/vscode/.kube/config

task init
task init-subtasks

echo "Done!"
