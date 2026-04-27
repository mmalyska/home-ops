#!/bin/bash

apt-get update
export DEBIAN_FRONTEND=noninteractive
apt-get -y install build-essential procps curl file git --no-install-recommends
apt-get clean -y
rm -rf /var/lib/apt/lists/*

# Pre-create the Homebrew prefix so the installer doesn't need sudo
mkdir -p /home/linuxbrew
chown "${_REMOTE_USER}" /home/linuxbrew

sudo -Hn -u "${_REMOTE_USER}" NONINTERACTIVE=1 ./install_user.sh
