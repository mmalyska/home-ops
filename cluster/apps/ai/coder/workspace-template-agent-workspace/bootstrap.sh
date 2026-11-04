#!/usr/bin/env bash
# Workspace bootstrap, run by the Coder agent at every start (coder_script in main.tf).
#
# Once per home volume it applies the dotfiles non-interactively. REMOTE_WORKSPACE=1 is set by the template, so the
# dotfiles know they run in a remote workspace: they set the workspace SSH signing key and clone the repositories
# listed there to /workspaces/<name>. Nothing else happens here.
#
# This workspace does not run a repository's .devcontainer lifecycle scripts (plan D48). Per-repository setup
# (direnv allow, pre-commit hooks, terraform init) is done by hand for now; see the template README.
#
# A failure is logged and does not stop the workspace.
set -u

log() { echo "bootstrap: $*"; }

# GITHUB_TOKEN is in the environment (delivered by External Secrets from its own Bitwarden secret). It is handed only to the
# command that needs it (private repositories) and is never printed or written to disk.
tok="${GITHUB_TOKEN:-}"
with_token() { if [ -n "$tok" ]; then env GITHUB_TOKEN="$tok" "$@"; else "$@"; fi; }

if [ ! -d "$HOME/.local/share/chezmoi/.git" ]; then
    log "applying mmalyska/dotfiles (first start of this home volume)"
    with_token timeout 900 chezmoi init --apply --promptDefaults mmalyska/dotfiles </dev/null \
        || log "dotfiles failed (continuing); run: chezmoi init --apply --promptDefaults mmalyska/dotfiles"
else
    log "dotfiles already applied; run 'chezmoi update' to pull changes"
fi
log "done"
