#!/bin/bash

# renovate: datasource=github-releases depName=bitwarden/sdk-sm
VERSION=bws-v2.0.0
ARCH=$(dpkg --print-architecture)

case "${ARCH}" in \
'amd64') curl -sL https://github.com/bitwarden/sdk-sm/releases/download/${VERSION}/bws-x86_64-unknown-linux-gnu-${VERSION#bws-v}.zip | funzip > /usr/bin/bws; ;; \
'arm64') curl -sL https://github.com/bitwarden/sdk-sm/releases/download/${VERSION}/bws-aarch64-unknown-linux-gnu-${VERSION#bws-v}.zip | funzip > /usr/bin/bws; ;; \
esac && \
chmod +x /usr/bin/bws
