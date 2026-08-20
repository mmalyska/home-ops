#!/bin/bash

# renovate: datasource=github-releases depName=coder/coder
VERSION=v2.36.1
ARCH=$(dpkg --print-architecture)

curl -sL "https://github.com/coder/coder/releases/download/${VERSION}/coder_${VERSION#v}_linux_${ARCH}.tar.gz" | tar -xzO ./coder > /usr/bin/coder
chmod +x /usr/bin/coder
