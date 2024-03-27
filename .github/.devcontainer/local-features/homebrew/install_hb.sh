#!/bin/bash -i

apt-get update && export DEBIAN_FRONTEND=noninteractive \
&& apt-get -y install build-essential procps curl file git --no-install-recommends \
&& apt-get clean -y && rm -rf /var/lib/apt/lists/*

case "${SHELL}" in
  */bash*)
    if [[ -n "${HOMEBREW_ON_LINUX-}" ]]
    then
      shell_rcfile="${HOME}/.bashrc"
    else
      shell_rcfile="${HOME}/.bash_profile"
    fi
    ;;
  */zsh*)
    if [[ -n "${HOMEBREW_ON_LINUX-}" ]]
    then
      shell_rcfile="${ZDOTDIR:-"${HOME}"}/.zshrc"
    else
      shell_rcfile="${ZDOTDIR:-"${HOME}"}/.zprofile"
    fi
    ;;
  */fish*)
    shell_rcfile="${HOME}/.config/fish/config.fish"
    ;;
  *)
    shell_rcfile="${ENV:-"${HOME}/.profile"}"
    ;;
esac

/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
&& eval "$(${HOMEBREW_PREFIX}/bin/brew shellenv)" >> ${shell_rcfile} \
&& eval "$(${HOMEBREW_PREFIX}/bin/brew shellenv)"
&& brew analytics off
