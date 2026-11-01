#!/usr/bin/env bash
# Helpers for the worktree-first tests: throw-away repositories, restricted PATHs, NOT RUN reporting.
# shellcheck disable=SC2034,SC2012  # variables are used by the sourcing tests
# Source after lib.sh. Everything is created under one temporary directory and removed on exit; the
# real repository is only read (see assert_real_repo_untouched).
# shellcheck source-path=SCRIPTDIR source=lib.sh

PF="$REPO_ROOT/.agents/bin/worktree-preflight"
GUARD="$REPO_ROOT/.agents/bin/claude-pretool-guard"
NOT_RUN=0

not_run() { # name reason
  NOT_RUN=$((NOT_RUN + 1))
  printf '  NOT RUN %s: %s\n' "$1" "$2"
}

sandbox_init() {
  SB="$(mktemp -d "${TMPDIR:-/tmp}/home-ops-wf.XXXXXX")"
  trap 'rm -rf "$SB"' EXIT
  export HOME="$SB/home"; mkdir -p "$HOME"
  export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
  printf '[user]\n\tname = Test\n\temail = test@example.invalid\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE HOME_OPS_BREAK_GLASS CLAUDE_ALLOW_MAIN_EDITS
  REAL_STATE_BEFORE="$(real_state)"
}

real_state() { # read-only fingerprint of the real repository
  git -C "$REPO_ROOT" status --porcelain=v1 2>/dev/null | cksum
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null
  git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | cksum
  ls "$(git -C "$REPO_ROOT" rev-parse --git-common-dir)/break-glass.log" 2>&1 | cksum
}

assert_real_repo_untouched() {
  if [ "$(real_state)" = "$REAL_STATE_BEFORE" ]; then pass "the real repository was not changed (status, HEAD, worktrees, no break-glass.log)"
  else fail "the real repository changed during the test"; fi
}

# mk_repo <name>: bare origin + clone "$SB/<name>/my repo" (a space on purpose) with one commit on main.
mk_repo() {
  local d="$SB/$1"
  mkdir -p "$d"
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/my repo" 2>/dev/null
  (
    cd "$d/my repo" || exit 1
    mkdir -p .agents/bin
    cp "$REPO_ROOT"/.agents/bin/* .agents/bin/
    echo hi > a.txt
    git add -A
    git commit -q -m init
    git push -q origin main 2>/dev/null
    git remote set-head origin main >/dev/null 2>&1
    echo ".worktrees/" >> .git/info/exclude
  )
  echo "$d/my repo"
}

# mk_wt <primary> <type/slug> [dir]: linked worktree from origin/main at .worktrees/<type>/<slug>.
mk_wt() {
  local p="$1" b="$2" d="${3:-.worktrees/$2}"
  git -C "$p" fetch -q origin
  git -C "$p" worktree add -q "$d" -b "$b" origin/main 2>/dev/null
  echo "$p/$d"
}

# tool_path <dir> <tool>...: a PATH directory holding only the named tools (resolved from the real PATH).
tool_path() {
  local d="$1"; shift
  mkdir -p "$d"
  local t src
  for t in "$@"; do
    src="$(command -v "$t")" || continue
    ln -sf "$src" "$d/$t"
  done
}

# Core tools the scripts may use. Deliberately without jq.
CORE_TOOLS="git sh dash bash cat date id tr dirname uname env mkdir ls rm printf cksum"
