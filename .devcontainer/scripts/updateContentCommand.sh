#!/bin/bash -i
if [ "$SYNC_LOCALHOST_CONFIGS" = "true" ]; then
    mkdir -p "$HOME"/.kube
    sudo cp -r /usr/local/share/kube-localhost/* "$HOME"/.kube
    sudo chown -R "$(id -u)" "$HOME"/.kube

    mkdir -p "$HOME"/.config/sops
    sudo cp -r /usr/local/share/sops-localhost/* "$HOME"/.config/sops
    sudo chown -R "$(id -u)" "$HOME"/.config/sops
fi

task init
task precommit:init

direnv allow

echo "Done!"
