#!/bin/bash -i
if [ "$SYNC_LOCALHOST_CONFIGS" = "true" ]; then
    mkdir -p "$HOME"/.kube
    sudo cp -r /usr/local/share/kube-localhost/* "$HOME"/.kube
    sudo chown -R "$(id -u)" "$HOME"/.kube

    mkdir -p "$HOME"/.config/sops
    sudo cp -r /usr/local/share/sops-localhost/* "$HOME"/.config/sops
    sudo chown -R "$(id -u)" "$HOME"/.config/sops

    mkdir -p "$HOME"/.ssh
    sudo cp -r /usr/local/share/ssh-localhost/* "$HOME"/.ssh
    sudo chown -R "$(id -u)" "$HOME"/.ssh
    sudo chmod 755 "$HOME"/.ssh
    sudo chmod 600 "$HOME"/.ssh/*
    sudo chmod 644 "$HOME"/.ssh/known_hosts
fi

direnv allow

git gc --prune=now

echo "Done!"
