#!/bin/bash -i

apt-get update
export DEBIAN_FRONTEND=noninteractive
apt-get -y install build-essential procps curl file git --no-install-recommends
apt-get clean -y
rm -rf /var/lib/apt/lists/*

su - "$_REMOTE_USER" <<EOF
  set -ex
  cd pwm
  ./install_hb.sh
EOF

case "${SHELL}" in
  */bash*)
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "${HOME}/.bashrc"
    ;;
  */zsh*)
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "${ZDOTDIR:-"${HOME}"}/.zshrc"
    ;;
  */fish*)
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "${HOME}/.config/fish/config.fish"
    ;;
  *)
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "${ENV:-"${HOME}/.profile"}"
    ;;
esac

su - "$_REMOTE_USER" <<EOF
  set -ex
  brew config
EOF
