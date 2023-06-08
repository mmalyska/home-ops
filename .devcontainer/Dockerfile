# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.245.2/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:3cb26c96497bfc785273ed8f2aa6983a68f26138dbf119b4444421d434037700
USER vscode

ENV LC_ALL=en_US.UTF-8

# [Optional] Uncomment this section to install additional OS packages.
RUN sudo apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && sudo apt-get -y install gnupg2 gcc build-essential --no-install-recommends \
    && sudo ln -s /bin/gcc /bin/gcc-5 \
    && sudo apt-get clean -y && sudo rm -rf /var/lib/apt/lists/*

# Pre install brew packages
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)" \
    && eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" >> /home/vscode/.profile \
    && brew analytics off
ENV PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
RUN brew install go-task/tap/go-task
RUN brew install \
    gcc \
    age \
    ansible \
    direnv \
    gitleaks \
    go-task/tap/go-task \
    helm \
    ipcalc \
    jq \
    kubernetes-cli \
    kustomize \
    pre-commit \
    prettier \
    sops \
    stern \
    terraform \
    yamllint \
    yq \
    argocd \
    int128/kubelogin/kubelogin \
    ansible-lint \
    k9s

RUN echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc \
    && echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc

# install Talos
RUN curl -sL https://talos.dev/install | sh
RUN talosctl completion bash > ~/.talos/completion.bash.inc \
    &&  printf " \
        # talosctl shell completion
        source '$HOME/.talos/completion.bash.inc' \
        " >> $HOME/.bash_profile \
    && source $HOME/.bash_profile

# install talhelper https://github.com/budimanjojo/talhelper
RUN curl https://i.jpillora.com/budimanjojo/talhelper\! | sudo bash
