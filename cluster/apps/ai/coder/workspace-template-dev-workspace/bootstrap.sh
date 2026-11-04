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
# A failure is logged and does not stop the workspace. The GitHub token is read from the workspace's BWS project into a
# shell variable and handed only to the command that needs it (private repositories); it is never printed or written to disk.
set -u

log() { echo "bootstrap: $*"; }

# bws_value NAME: value of the secret NAME in the workspace's BWS project, empty when unavailable. Never printed.
bws_value() {
    [ -n "${BWS_ACCESS_TOKEN:-}" ] && [ -n "${BWS_PROJECT_ID:-}" ] || return 0
    bws secret list "$BWS_PROJECT_ID" -o json 2>/dev/null \
        | jq -r --arg k "$1" '.[] | select(.key == $k) | .value' 2>/dev/null | head -n1
}

tok="$(bws_value GITHUB_TOKEN)"
with_token() { if [ -n "$tok" ]; then env GITHUB_TOKEN="$tok" "$@"; else "$@"; fi; }

if [ ! -d "$HOME/.local/share/chezmoi/.git" ]; then
    log "applying mmalyska/dotfiles (first start of this home volume)"
    with_token timeout 900 chezmoi init --apply --promptDefaults mmalyska/dotfiles </dev/null \
        || log "dotfiles failed (continuing); run: chezmoi init --apply --promptDefaults mmalyska/dotfiles"
else
    log "dotfiles already applied; run 'chezmoi update' to pull changes"
fi
log "done"
