# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.245.2/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:0726560e7005578d778ccb965a9e5e3f1295c637111425ffe4ab21785a6044b7

# renovate: datasource=github-releases depName=budimanjojo/talhelper
ARG TALHELPER=v3.0.4
# renovate: datasource=github-releases depName=mmalyska/talos-images
ARG TALOS_CLI=v1.7.5

ENV LC_ALL=en_US.UTF-8

# [Optional] Uncomment this section to install additional OS packages.
RUN sudo apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && sudo apt-get -y install gnupg2 gcc build-essential --no-install-recommends \
    && sudo ln -s /bin/gcc /bin/gcc-5 \
    && sudo apt-get clean -y && sudo rm -rf /var/lib/apt/lists/*

# install Talos
RUN curl -sL https://talos.dev/install | sed "s+siderolabs/talos/releases/latest/download+siderolabs/talos/releases/download/${TALOS_CLI}+g" | bash

# install talhelper https://github.com/budimanjojo/talhelper
RUN curl https://i.jpillora.com/budimanjojo/talhelper@${TALHELPER}\! | sudo bash
