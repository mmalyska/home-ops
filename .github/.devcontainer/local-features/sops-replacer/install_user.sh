#!/bin/bash -i

# renovate: datasource=github-releases depName=mmalyska/argocd-secret-replacer
VERSION=0.3.0
ARCH=$(dpkg --print-architecture)

case "${ARCH}" in \
'amd64') curl -sL https://github.com/mmalyska/argocd-secret-replacer/releases/download/v${VERSION}/secret-replacer-v${VERSION}-linux-x64.tar.gz | tar -xvz --no-same-owner; ;; \
'arm64') curl -sL https://github.com/mmalyska/argocd-secret-replacer/releases/download/v${VERSION}/secret-replacer-v${VERSION}-linux-arm64.tar.gz | tar -xvz --no-same-owner; ;; \
esac && \
mv argocd-secret-replacer /usr/bin/argocd-secret-replacer && \
chmod +x /usr/bin/argocd-secret-replacer
