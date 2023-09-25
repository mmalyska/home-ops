# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.245.2/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:f3d8b50bba24b731a5c0437642e1f8050b7655a654fc806eccd2cecf7e3291ee

# renovate: datasource=github-releases depName=budimanjojo/talhelper
ARG TALHELPER=v1.13.0
# renovate: datasource=github-releases depName=mmalyska/talos-images
ARG TALOS_CLI=v1.5.3

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
    kubectl \
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
    k9s \
    mkdocs

RUN echo 'eval "$(direnv hook zsh)"' >> /home/vscode/.zshrc \
    && echo 'eval "$(direnv hook bash)"' >> /home/vscode/.bashrc

# install Talos
RUN curl -sL https://talos.dev/install | sed "s+siderolabs/talos/releases/latest/download+siderolabs/talos/releases/download/${TALOS_CLI}+g" | bash

# install talhelper https://github.com/budimanjojo/talhelper
RUN curl https://i.jpillora.com/budimanjojo/talhelper@${TALHELPER}\! | sudo bash
