#!/bin/bash -i

apt-get update
export DEBIAN_FRONTEND=noninteractive
apt-get -y install build-essential procps curl file git --no-install-recommends
apt-get clean -y
rm -rf /var/lib/apt/lists/*

sudo -u ${_REMOTE_USER} ./install_hb.sh

sudo -u ${_REMOTE_USER} /home/linuxbrew/.linuxbrew/bin/brew doctor
