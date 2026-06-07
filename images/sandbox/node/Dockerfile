ARG REGISTRY
FROM ${REGISTRY}/sandbox/base:latest

USER root

ARG NODE_VERSION=22
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# pnpm + Expo CLI
USER coder
ENV PNPM_HOME="/home/coder/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable pnpm \
    && pnpm add -g expo-cli @expo/cli eas-cli
