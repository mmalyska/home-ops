#!/bin/bash -i

VERSION=v0.3.0
ARCH=$(dpkg --print-architecture)

case "${ARCH}" in \
'amd64') curl -sL https://github.com/mmalyska/argocd-secret-replacer/releases/download/v${VERSION}/secret-replacer-v${VERSION}-linux-musl-x64.tar.gz | tar -xvz; ;; \
'arm64') curl -sL https://github.com/mmalyska/argocd-secret-replacer/releases/download/v${VERSION}/secret-replacer-v${VERSION}-linux-musl-arm64.tar.gz | tar -xvz; ;; \
esac && \
mv argocd-secret-replacer /usr/bin/argocd-secret-replacer && \
chmod +x /usr/bin/argocd-secret-replacer