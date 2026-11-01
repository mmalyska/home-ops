#!/bin/bash

# renovate: datasource=github-releases depName=openai/codex
VERSION=rust-v0.166.0
ARCH=$(dpkg --print-architecture)

case "${ARCH}" in \
'amd64') TARGET=x86_64-unknown-linux-musl; ;; \
'arm64') TARGET=aarch64-unknown-linux-musl; ;; \
esac && \
curl -fsSL "https://github.com/openai/codex/releases/download/${VERSION}/codex-${TARGET}.tar.gz" | tar -xzO "codex-${TARGET}" > /usr/bin/codex && \
chmod +x /usr/bin/codex
