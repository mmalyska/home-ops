#!/bin/bash -i

su - "$_REMOTE_USER"  <<EOF
  set -ex
  pwd
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
