#!/bin/bash -i
git gc --prune=now
brew update
brew upgrade

task init
task init-subtasks

echo "Done!"
