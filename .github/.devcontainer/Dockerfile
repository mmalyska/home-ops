# See here for image contents: https://github.com/microsoft/vscode-dev-containers/tree/v0.245.2/containers/ubuntu/.devcontainer/base.Dockerfile

# [Choice] Ubuntu version (use ubuntu-22.04 or ubuntu-18.04 on local arm64/Apple Silicon): ubuntu-22.04, ubuntu-20.04, ubuntu-18.04
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04@sha256:daa08ddb48ad4e4e7367c348e0a6f250762f1f0d8348f1f9acbef5f884ce093d

ENV LC_ALL=en_US.UTF-8

# [Optional] Uncomment this section to install additional OS packages.
RUN sudo apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && sudo apt-get -y install gnupg2 gcc build-essential --no-install-recommends \
    && sudo ln -s /bin/gcc /bin/gcc-5 \
    && sudo apt-get clean -y && sudo rm -rf /var/lib/apt/lists/*
