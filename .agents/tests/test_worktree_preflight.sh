#!/usr/bin/env bash
# worktree-preflight: classification, exit codes, break-glass, fail-closed behaviour.
# shellcheck disable=SC2015,SC2086  # A && B || C is the pass/fail idiom here; tool lists are split on purpose
# Runs the script under every POSIX shell found (sh, dash, bash). Uses throw-away repositories only.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib_git.sh
source "$(dirname "$0")/lib_git.sh"
sandbox_init

pf() { "$SH" "$PF" "$@"; }                   # stdout+stderr, status
rc_of() { "$SH" "$PF" "$@" >/dev/null 2>&1; echo $?; }
field() { pf "$@" 2>/dev/null | grep "^$FIELD=" | cut -d= -f2-; }
expect_rc() { # name want args...
  local name="$1" want="$2"; shift 2
  local got; got="$(rc_of "$@")"
  [ "$got" = "$want" ] && pass "$name" || fail "$name" "exit $got, wanted $want"
}
expect_kind() { # name want args...
  local name="$1" want="$2"; shift 2
  FIELD=kind; local got; got="$(field "$@")"
  [ "$got" = "$want" ] && pass "$name" || fail "$name" "kind=$got, wanted $want"
}

P="$(mk_repo a)"
W="$(mk_wt "$P" feat/one)"
mkdir -p "$W/sub dir/deeper"

for SH in $(command -v sh) $(command -v dash) $(command -v bash); do
  [ -n "$SH" ] || continue
  echo "-- under $SH"
  cd "$SB" || exit 2

  expect_kind "primary on main is primary" primary --path "$P"
  expect_rc   "primary on main: exit 3" 3 --path "$P"
  git -C "$P" switch -q -c feat/in-primary
  expect_rc   "primary on a feature branch: still exit 3" 3 --path "$P"
  expect_rc   "primary on a feature branch, --hook: exit 3" 3 --hook --path "$P"
  echo dirty > "$P/new.txt"
  FIELD=dirty; [ "$(field --path "$P")" = true ] && pass "primary reports dirty=true" || fail "dirty not reported"
  expect_rc   "primary dirty: exit 3" 3 --path "$P"
  rm "$P/new.txt"; git -C "$P" switch -q main; git -C "$P" branch -q -D feat/in-primary

  expect_kind "linked worktree (path with spaces in the parent)" worktree --path "$W"
  expect_rc   "linked worktree: exit 0" 0 --path "$W"
  expect_rc   "linked worktree, --hook, feature branch: exit 0" 0 --hook --path "$W"
  expect_kind "subdirectory with a space" worktree --path "$W/sub dir/deeper"
  expect_kind "file that does not exist yet, in a directory that does not exist yet" worktree --path "$W/new/dir/file.txt"
  expect_kind "path inside the primary, nested worktree dir not yet a worktree" primary --path "$P/.worktrees/feat/missing/file.txt"
  ln -sfn "$W" "$SB/link-to-wt"
  expect_kind "symlink to a worktree resolves to worktree" worktree --path "$SB/link-to-wt/a.txt"
  ln -sfn "$P" "$SB/link-to-primary"
  expect_rc   "symlink to the primary resolves to primary: exit 3" 3 --path "$SB/link-to-primary/a.txt"
  expect_rc   "write target in the primary, cwd in a worktree: exit 3" 3 --path "$P/a.txt"
  (cd "$W" && expect_rc "default path is the current directory (worktree)" 0)
  (cd "$P" && expect_rc "default path is the current directory (primary)" 3)

  expect_kind "path inside .git is git-internal" git-internal --path "$P/.git/hooks"
  expect_rc   "git-internal: exit 0" 0 --path "$P/.git/hooks/x"
  expect_kind "path inside .git/worktrees is git-internal" git-internal --path "$P/.git/worktrees"
  expect_kind "outside any repository is not-repo" not-repo --path "$SB/home"
  expect_rc   "not-repo: exit 0" 0 --path "$SB/home/none"

  # detached HEAD in a worktree
  D="$(mk_wt "$P" feat/detach)"
  git -C "$D" checkout -q --detach
  FIELD=detached; [ "$(field --path "$D")" = true ] && pass "detached HEAD reported" || fail "detached HEAD not reported"
  expect_rc   "detached HEAD in a worktree: exit 0" 0 --path "$D"
  expect_rc   "detached HEAD in a worktree, --hook: exit 0" 0 --hook --path "$D"
  git -C "$D" switch -q feat/detach; git -C "$P" worktree remove --force "$D"; git -C "$P" branch -q -D feat/detach

  # main checked out in a linked worktree: allowed to classify, refused to commit
  git -C "$P" switch -q -c feat/park
  M="$SB/a/main wt"
  git -C "$P" worktree add -q "$M" main 2>/dev/null
  expect_rc   "main in a linked worktree: classification exit 0" 0 --path "$M"
  expect_rc   "main in a linked worktree, --hook: exit 3" 3 --hook --path "$M"
  git -C "$P" worktree remove --force "$M"; git -C "$P" switch -q main; git -C "$P" branch -q -D feat/park

  # worktree is created from the current origin/main
  git -C "$P" fetch -q origin
  [ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$P" rev-parse origin/main)" ] \
    && pass "worktree HEAD equals origin/main at creation" || fail "worktree HEAD differs from origin/main"

  # submodule inside a worktree
  S="$(mk_repo "sm-$RANDOM")"
  SW="$(mk_wt "$P" "feat/sub-$RANDOM")"
  git -C "$SW" submodule add "${S%/my repo}/origin.git" vendor/sm >/dev/null 2>&1
  expect_kind "submodule is not primary" submodule --path "$SW/vendor/sm"
  git -C "$P" worktree remove --force "$SW" 2>/dev/null

  # bare repository
  expect_kind "bare repository" bare --path "$SB/a/origin.git"
  expect_rc   "bare repository: exit 3" 3 --path "$SB/a/origin.git"

  # inherited repository selection must not fool it
  FIELD=kind; got="$(GIT_DIR="$W/.git" GIT_WORK_TREE="$W" "$SH" "$PF" --path "$P" 2>/dev/null | grep ^kind= | cut -d= -f2)"
  [ "$got" = primary ] && pass "GIT_DIR/GIT_WORK_TREE in the environment do not change the verdict" || fail "GIT_DIR spoof" "kind=$got"

  # usage
  expect_rc "unknown option: exit 2" 2 --bogus
  expect_rc "--path without a value: exit 2" 2 --path

  # JSON output is valid and agrees
  if command -v jq >/dev/null; then
    "$SH" "$PF" --json --path "$W" | jq -e '.kind=="worktree" and .branch=="feat/one" and .detached==false' >/dev/null \
      && pass "--json output is valid JSON with the same fields" || fail "--json output"
  fi
done

SH="$(command -v sh)"
echo "-- break-glass"
L="$P/.git/break-glass.log"
rm -f "$L"
expect_rc "empty reason does not bypass" 3 --path "$P"
[ "$(HOME_OPS_BREAK_GLASS='' rc_of --path "$P")" = 3 ] && pass "HOME_OPS_BREAK_GLASS set but empty: exit 3" || fail "empty break-glass bypassed"
[ "$(HOME_OPS_BREAK_GLASS='   ' rc_of --path "$P")" = 3 ] && pass "whitespace-only reason: exit 3" || fail "blank break-glass bypassed"
[ ! -e "$L" ] && pass "no log line without a reason" || fail "log written for an empty reason"
out="$(HOME_OPS_BREAK_GLASS='fix the origin remote by hand' "$SH" "$PF" --path "$P" 2>&1)"; rc=$?
[ "$rc" = 0 ] && pass "non-empty reason: exit 0" || fail "break-glass with a reason" "exit $rc"
grep -q 'BREAK-GLASS' <<<"$out" && pass "warning printed on stderr" || fail "no warning"
[ "$(wc -l < "$L")" = 1 ] && grep -q 'fix the origin remote by hand' "$L" && grep -q "$P" "$L" && pass "one log line: time, user, path, kind and reason" || fail "break-glass.log content" "$(cat "$L" 2>&1)"
HOME_OPS_BREAK_GLASS=$'two\nlines' "$SH" "$PF" --path "$P" >/dev/null 2>&1
[ "$(wc -l < "$L")" = 2 ] && pass "a reason with a newline stays on one log line" || fail "newline in reason split the log"
rm -f "$L"
expect_rc "a worktree on a feature branch needs no break-glass and logs nothing" 0 --hook --path "$W"
[ ! -e "$L" ] && pass "no log for an allowed path" || fail "log written for an allowed path"

echo "-- break-glass is for a person (--human-only)"
if command -v setsid >/dev/null; then
  HOME_OPS_BREAK_GLASS='agent tries' setsid -w "$SH" "$PF" --human-only --path "$P" >/dev/null 2>&1 </dev/null; rc=$?
  [ "$rc" = 3 ] && [ ! -e "$L" ] && pass "no controlling terminal: break-glass ignored, nothing logged" || fail "agent-style break-glass" "exit $rc"
else not_run "agent-style break-glass without a terminal" "setsid not available"; fi
if script -qec true /dev/null >/dev/null 2>&1; then
  HOME_OPS_BREAK_GLASS='human at a terminal' script -qec "$SH $PF --human-only --path '$P'" /dev/null >/dev/null 2>&1; rc=$?
  [ "$rc" = 0 ] && grep -q 'human at a terminal' "$L" && pass "with a controlling terminal the break-glass is honoured and logged" || fail "human break-glass" "exit $rc"
  rm -f "$L"
else not_run "human break-glass with a terminal" "util-linux script not available"; fi

echo "-- fail closed"
TP="$SB/tools-nojq"; tool_path "$TP" $CORE_TOOLS
[ "$(PATH="$TP" "$SH" "$PF" --path "$W" >/dev/null 2>&1; echo $?)" = 0 ] && pass "no jq on PATH: classification still works" || fail "needs jq"
[ "$(PATH="$TP" "$SH" "$PF" --path "$P" >/dev/null 2>&1; echo $?)" = 3 ] && pass "no jq on PATH: primary still refused" || fail "no jq, primary"
TG="$SB/tools-nogit"; tool_path "$TG" sh dash bash cat date id tr
[ "$(PATH="$TG" "$SH" "$PF" --path "$W" >/dev/null 2>&1; echo $?)" = 4 ] && pass "git missing: exit 4, not allowed" || fail "git missing fails open"
TD="$SB/tools-nodate"; tool_path "$TD" git sh dash bash cat id tr
[ "$(HOME_OPS_BREAK_GLASS=why PATH="$TD" "$SH" "$PF" --path "$P" >/dev/null 2>&1; echo $?)" = 4 ] && [ ! -e "$L" ] && pass "break-glass that cannot be logged is refused (exit 4)" || fail "unlogged break-glass"
BROKEN="$SB/broken"; mkdir -p "$BROKEN/sub"; echo 'gitdir: /nonexistent/place' > "$BROKEN/.git"
expect_rc "a .git that git cannot read: exit 4, never not-repo" 4 --path "$BROKEN/sub"

echo "-- Windows"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) not_run "Windows (Git Bash) behaviour" "no Windows host; the repository is worked on in a Linux devcontainer" ;; esac

echo "-- the test changed nothing outside its temporary directory"
assert_real_repo_untouched
cd / || exit 2
finish
