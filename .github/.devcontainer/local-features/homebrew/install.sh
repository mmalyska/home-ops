#!/bin/bash -i

sudo -u $_REMOTE_USER ./install_hb.sh

PATH=/home/linuxbrew/.linuxbrew/bin:${PATH}
case "${SHELL}" in
  */bash*)
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" >> "${HOME}/.bashrc"
    ;;
  */zsh*)
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" >> "${ZDOTDIR:-"${HOME}"}/.zshrc"
    ;;
  */fish*)
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" >> "${HOME}/.config/fish/config.fish"
    ;;
  *)
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" >> "${ENV:-"${HOME}/.profile"}"
    ;;
esac
