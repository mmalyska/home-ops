#!/usr/bin/env bash
# The git-level layer: the worktree-first hook from .pre-commit-config.yaml, installed by pre-commit
# into a throw-away repository, blocks commits in the primary checkout and on the default branch.
# shellcheck disable=SC2015
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib_git.sh
source "$(dirname "$0")/lib_git.sh"
sandbox_init

if ! command -v pre-commit >/dev/null || ! command -v yq >/dev/null; then
  not_run "pre-commit guard" "pre-commit or yq not installed"
  finish; exit $?
fi

# Take the real hook entry from the repository config, so the test follows the config.
hook_yaml="$(yq '.repos[] | select(.repo == "local") | .hooks[] | select(.id == "worktree-first")' "$REPO_ROOT/.pre-commit-config.yaml")"
[ -n "$hook_yaml" ] && pass "worktree-first hook is defined in .pre-commit-config.yaml" || { fail "hook missing from .pre-commit-config.yaml"; finish; exit $?; }
stage="$(yq '.repos[] | select(.repo == "local") | .hooks[] | select(.id == "worktree-first") | .stages[0]' "$REPO_ROOT/.pre-commit-config.yaml")"
[ "$stage" = pre-commit ] && pass "stage is pre-commit" || fail "stage is $stage"
[ "$(yq '.repos[] | select(.repo == "local") | .hooks[] | select(.id == "worktree-first") | .language' "$REPO_ROOT/.pre-commit-config.yaml")" = script ] && pass "language is script (no environment is installed, no network)" || fail "language is not script"

P="$(mk_repo p)"
(
  cd "$P" || exit 1
  { printf 'repos:\n  - repo: local\n    hooks:\n'; printf '%s\n' "$hook_yaml" | sed 's/^/      /; 1s/^      /      - /; 1!s/^      /        /'; } > .pre-commit-config.yaml
  git add -A && git -c core.hooksPath=/dev/null commit -q -m "add hook config"
  pre-commit install >/dev/null 2>&1
)
git -C "$P" push -q origin main 2>/dev/null
[ -x "$P/.git/hooks/pre-commit" ] && pass "pre-commit installed its hook in the common git directory" || fail "hook not installed"

try_commit() { # dir [env...] -> status; creates a change first
  local d="$1"; shift
  echo "$RANDOM" > "$d/change-$RANDOM.txt"
  git -C "$d" add -A
  ( cd "$d" && env "$@" git commit -q -m "test commit" ) >"$SB/commit.out" 2>&1
}

echo "-- primary checkout"
try_commit "$P" && fail "commit in the primary on main succeeded" || pass "commit in the primary on main is blocked"
grep -q 'primary checkout' "$SB/commit.out" && pass "the message names the primary checkout and the worktree command" || fail "message" "$(cat "$SB/commit.out")"
git -C "$P" reset -q --hard
git -C "$P" switch -q -c feat/in-primary
try_commit "$P" && fail "commit in the primary on a feature branch succeeded" || pass "commit in the primary on a feature branch is blocked"
git -C "$P" reset -q --hard; git -C "$P" switch -q main; git -C "$P" branch -q -D feat/in-primary

echo "-- linked worktree"
W="$(mk_wt "$P" feat/one)"
[ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$P" rev-parse origin/main)" ] && pass "worktree created from the current origin/main" || fail "worktree not at origin/main"
try_commit "$W" X=1 && pass "commit on a feature branch in a worktree passes" || fail "worktree commit blocked" "$(cat "$SB/commit.out")"
for b in docs/x fix/y chore/z renovate/pkg; do
  w2="$(mk_wt "$P" "$b")"
  try_commit "$w2" X=1 && pass "branch type $b passes" || fail "branch type $b blocked" "$(cat "$SB/commit.out")"
done

echo "-- default branch in a worktree"
git -C "$P" switch -q -c feat/park
M="$SB/p/main wt"
git -C "$P" worktree add -q "$M" main 2>/dev/null
try_commit "$M" X=1 && fail "commit on main inside a worktree succeeded" || pass "commit on main inside a linked worktree is blocked"
grep -q 'default branch' "$SB/commit.out" && pass "the message says it is the default branch" || fail "message" "$(cat "$SB/commit.out")"
git -C "$P" worktree remove --force "$M"; git -C "$P" switch -q main

echo "-- detached HEAD"
git -C "$W" checkout -q --detach
try_commit "$W" X=1 && pass "commit with a detached HEAD in a worktree passes" || fail "detached commit blocked" "$(cat "$SB/commit.out")"
git -C "$W" checkout -q feat/one 2>/dev/null

echo "-- break-glass and bypass attempts"
L="$P/.git/break-glass.log"; rm -f "$L"
if command -v setsid >/dev/null; then
  echo "$RANDOM" > "$P/agent.txt"; git -C "$P" add -A
  ( cd "$P" && HOME_OPS_BREAK_GLASS='agent says so' setsid -w git commit -q -m "agent attempt" ) >/dev/null 2>&1 </dev/null
  [ "$(git -C "$P" log -1 --format=%s)" != "agent attempt" ] && [ ! -e "$L" ] && pass "agent-style break-glass (no terminal) does not let the commit through, nothing logged" || fail "agent break-glass worked"
  git -C "$P" reset -q --hard
else not_run "agent-style break-glass on commit" "setsid not available"; fi
if script -qec true /dev/null >/dev/null 2>&1; then
  echo "$RANDOM" > "$P/human.txt"; git -C "$P" add -A
  HOME_OPS_BREAK_GLASS='owner fixing the origin by hand' script -qec "git -C '$P' commit -q -m 'human break-glass'" /dev/null >/dev/null 2>&1
  [ "$(git -C "$P" log -1 --format=%s)" = "human break-glass" ] && grep -q 'owner fixing' "$L" && pass "a human at a terminal can break the glass: commit passes, line logged" || fail "human break-glass" "$(cat "$L" 2>&1)"
  git -C "$P" reset -q --hard HEAD~1
else not_run "human break-glass on commit" "util-linux script not available"; fi
HOME_OPS_BREAK_GLASS='' try_commit "$P" && fail "empty break-glass let a commit through" || pass "empty break-glass does not let a commit through"
git -C "$P" reset -q --hard

# Honest limit: git cannot stop its own bypass flag. Other layers cover it (Claude hook and settings deny, Codex rule, review, CI).
echo "$RANDOM" > "$P/skip.txt"; git -C "$P" add -A
( cd "$P" && git commit -q --no-verify -m "bypass" ) >/dev/null 2>&1
[ "$(git -C "$P" log -1 --format=%s)" = "bypass" ] && pass "KNOWN LIMIT confirmed: the skip-hooks flag defeats the git layer (covered by the Claude hook, settings deny, Codex rule, review and CI)" || fail "expected the skip-hooks flag to bypass the git hook"

echo "-- the other hooks are unchanged"
if [ "$(yq '.repos | map(select(.repo != "local")) | length' "$REPO_ROOT/.pre-commit-config.yaml")" -ge 2 ]; then
  added="$(git -C "$REPO_ROOT" diff origin/main -- .pre-commit-config.yaml | grep -c '^-[^-]')"
  [ "$added" = 0 ] && pass "no existing line of .pre-commit-config.yaml was removed or changed" || fail "existing hook config changed ($added lines)"
fi

echo "-- nothing outside the temporary directory changed"
assert_real_repo_untouched
cd / || exit 2
finish
