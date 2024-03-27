#!/bin/bash -i

apt-get update && export DEBIAN_FRONTEND=noninteractive \
&& apt-get -y install build-essential procps curl file git --no-install-recommends \
&& apt-get clean -y && rm -rf /var/lib/apt/lists/*

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

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
eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
brew analytics off
