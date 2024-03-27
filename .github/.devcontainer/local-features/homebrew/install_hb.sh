#!/bin/bash -i

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

case "${SHELL}" in
  */bash*)
    echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> ${HOME}/.bashrc
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
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
brew analytics off
