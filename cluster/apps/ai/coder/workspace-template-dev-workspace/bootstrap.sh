#!/usr/bin/env bash
# Workspace bootstrap, run by the Coder agent at every start (coder_script in main.tf). Plan: T6 option A.
#
#   1. Once per home volume: apply the dotfiles non-interactively. This also clones the repositories listed there
#      (REMOTE_WORKSPACE=1 is set by the template, so the dotfiles know they are in a remote workspace).
#   2. For every repository under /workspaces that has .devcontainer/devcontainer.json: run its onCreateCommand and
#      updateContentCommand once per home volume (a marker is written only after success, so a failure is retried at
#      the next start), and its postStartCommand at every start.
#
# A failing step is logged and does not stop the next one. Nothing secret is printed or written to disk: the GitHub token
# is read from the workspace's BWS project into a shell variable and handed to the one command that needs it.
set -u

state="$HOME/.config/dev-workspace"
mkdir -p "$state"
log() { echo "bootstrap: $*"; }

# bws_value NAME: value of the secret NAME in the workspace's BWS project, empty when unavailable. Never printed.
bws_value() {
    [ -n "${BWS_ACCESS_TOKEN:-}" ] && [ -n "${BWS_PROJECT_ID:-}" ] || return 0
    bws secret list "$BWS_PROJECT_ID" -o json 2>/dev/null \
        | jq -r --arg k "$1" '.[] | select(.key == $k) | .value' 2>/dev/null | head -n1
}

tok="$(bws_value GITHUB_TOKEN)"
with_token() { if [ -n "$tok" ]; then env GITHUB_TOKEN="$tok" "$@"; else "$@"; fi; }

# 1. dotfiles
if [ ! -d "$HOME/.local/share/chezmoi/.git" ]; then
    log "applying mmalyska/dotfiles (first start of this home volume)"
    with_token timeout 900 chezmoi init --apply --promptDefaults mmalyska/dotfiles </dev/null \
        || log "dotfiles failed (continuing); run: chezmoi init --apply --promptDefaults mmalyska/dotfiles"
else
    log "dotfiles already applied; run 'chezmoi update' to pull changes"
fi

# 2. repository lifecycle commands. devcontainer.json is JSONC (comments, trailing commas), so jq cannot read it:
# node strips them while respecting strings (the file has URLs with //), then prints "<event><TAB><command>" lines.
# A command may be a string, an array (exec form) or an object of named commands; all are run in order.
read -r -d '' JS <<'EOF'
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
let out = "", i = 0, inStr = false;
const n = src.length;
while (i < n) {
  const c = src[i];
  if (inStr) { out += c; if (c === "\\") { out += src[i + 1] || ""; i += 2; continue; } if (c === '"') inStr = false; i++; continue; }
  if (c === '"') { inStr = true; out += c; i++; continue; }
  if (c === "/" && src[i + 1] === "/") { while (i < n && src[i] !== "\n") i++; continue; }
  if (c === "/" && src[i + 1] === "*") { i += 2; while (i < n && !(src[i] === "*" && src[i + 1] === "/")) i++; i += 2; continue; }
  out += c; i++;
}
const cfg = JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
const q = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";
const flat = (v) => typeof v === "string" ? [v] : Array.isArray(v) ? [v.map(q).join(" ")] : v && typeof v === "object" ? Object.values(v).flatMap(flat) : [];
for (const ev of ["onCreateCommand", "updateContentCommand", "postStartCommand"])
  for (const cmd of flat(cfg[ev])) console.log(ev + "\t" + cmd.replace(/\n/g, " "));
EOF

for dir in "${WORKSPACES_ROOT:-/workspaces}"/*/; do
    dir="${dir%/}"; repo="${dir##*/}"; cfg="$dir/.devcontainer/devcontainer.json"
    [ -f "$cfg" ] || continue
    if ! cmds="$(node -e "$JS" "$cfg" 2>/dev/null)"; then
        log "$repo: cannot read devcontainer.json, skipped"
        continue
    fi
    while IFS=$'\t' read -r ev cmd; do
        [ -n "$ev" ] || continue
        marker=""
        case "$ev" in
            onCreateCommand|updateContentCommand)
                marker="$state/$repo.$ev.done"
                [ -e "$marker" ] && continue ;;
        esac
        cmd="${cmd//\$\{containerWorkspaceFolder\}/$dir}"
        cmd="${cmd//\$\{localWorkspaceFolder\}/$dir}"
        log "$repo: $ev"
        if (cd "$dir" && with_token timeout 1200 bash -c "$cmd" </dev/null); then
            [ -z "$marker" ] || : > "$marker"
        else
            log "$repo: $ev failed (continuing; a once-per-volume command is retried at the next start)"
        fi
    done <<< "$cmds"
done
log "done"
