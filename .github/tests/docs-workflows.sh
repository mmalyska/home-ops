#!/usr/bin/env bash
set -e
# Verify uv setup
uv --version
# Test lockfile integrity (just run it without --verify)
uv pip compile .github/mkdocs/requirements.in --generate-hashes --output-file /dev/null
