#!/usr/bin/env bash
# claude-pretool-guard: positive and negative JSON fixtures, no jq on its PATH, fail-closed paths,
# and the settings.json wiring.
# shellcheck disable=SC2015,SC2086
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source-path=SCRIPTDIR source=lib_git.sh
source "$(dirname "$0")/lib_git.sh"
sandbox_init

P="$(mk_repo c)"
W="$(mk_wt "$P" feat/one)"
TP="$SB/tools-nojq"; tool_path "$TP" $CORE_TOOLS

# run_guard <json> [env...] -> GOUT, GRC. Always without jq on PATH.
run_guard() {
  local json="$1"; shift
  GOUT="$(printf '%s' "$json" | env PATH="$TP" "$@" sh "$GUARD" 2>"$SB/guard.err")"; GRC=$?
}
is_deny() { case "$GOUT" in *'"permissionDecision":"deny"'*) return 0 ;; *) return 1 ;; esac; }
is_silent_allow() { [ "$GRC" = 0 ] && [ -z "$GOUT" ]; }
mk() { # tool key path [extra-input-json]
  printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{%s"%s":"%s"%s}}' \
    "${CWD_FIX:-$W}" "$1" "${PRE:-}" "$2" "$3" "${POST:-}"
}

echo "-- file tools"
run_guard "$(mk Write file_path "$P/new.md")" X=1
is_deny && [ "$GRC" = 0 ] && pass "Write into the primary: deny" || fail "Write into the primary" "$GOUT"
case "$GOUT" in *'git worktree add .worktrees/'*) pass "deny reason carries the worktree command" ;; *) fail "reason lacks the worktree command" "$GOUT" ;; esac
run_guard "$(mk Edit file_path "$P/a.txt")" X=1;            is_deny && pass "Edit in the primary: deny" || fail "Edit in the primary"
run_guard "$(mk NotebookEdit notebook_path "$P/n.ipynb")" X=1; is_deny && pass "NotebookEdit in the primary: deny" || fail "NotebookEdit in the primary"
run_guard "$(mk Write file_path "$W/new.md")" X=1;           is_silent_allow && pass "Write in a linked worktree: allow, no output" || fail "Write in a worktree" "$GOUT"
run_guard "$(mk Edit file_path "$W/dir with space/x.md")" X=1; is_silent_allow && pass "path with spaces in a worktree: allow" || fail "spaces" "$GOUT"
run_guard "$(mk Write file_path "$P/dir with space/x.md")" X=1; is_deny && pass "path with spaces in the primary: deny" || fail "spaces, primary"
run_guard "$(mk Write file_path "/tmp/outside-any-repo-$$.md")" X=1; is_silent_allow && pass "outside any repository: allow" || fail "outside repo" "$GOUT"
for g in "$P/.git/hooks/pre-commit" "$P/.git/config" "$P/.git/worktrees/one/HEAD" "$W/.git" "$P/.git/refs/heads/x"; do
  for t in "Write file_path" "Edit file_path" "NotebookEdit notebook_path"; do
    run_guard "$(mk $t "$g")" X=1; is_deny && pass "${t%% *} into a git directory ($g): deny" || fail "${t%% *} into $g" "$GOUT"
  done
done
run_guard "$(CWD_FIX="$P" mk Write file_path ".git/hooks/pre-commit")" X=1; is_deny && pass "relative path into .git: deny" || fail "relative .git"
run_guard "$(mk Write file_path "$P/.github/workflows/x.yml")" X=1; is_deny && pass ".github in the primary: deny (primary, not .git)" || fail ".github primary"
run_guard "$(mk Write file_path "$W/.github/x.yml")" X=1; is_silent_allow && pass ".github in a worktree is not .git: allow" || fail ".github worktree" "$GOUT"
run_guard '{"tool_name":"Read","tool_input":{"file_path":"'"$P"'/.git/config"}}' X=1; is_silent_allow && pass "Read of .git stays allowed" || fail "read .git"
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"'"$P"'/.git"}}' X=1; is_silent_allow && pass "Grep of .git stays allowed" || fail "grep .git"
SM="$(mk_repo "hsm-$RANDOM")"; SMO="${SM%/my repo}/origin.git"
git -C "$P" submodule add "$SMO" vendor/sm >/dev/null 2>&1 && SMP=1 || SMP=0
SW="$(mk_wt "$P" "feat/hsub-$RANDOM")"
git -C "$SW" submodule add "$SMO" vendor/sm2 >/dev/null 2>&1
if [ "$SMP" = 1 ] && [ -d "$P/vendor/sm" ]; then
  run_guard "$(mk Write file_path "$P/vendor/sm/x.md")" X=1; is_deny && pass "Write into a submodule of the primary: deny" || fail "submodule under primary" "$GOUT"
else fail "fixture: submodule under the primary not created"; fi
if [ -d "$SW/vendor/sm2" ]; then
  run_guard "$(mk Write file_path "$SW/vendor/sm2/x.md")" X=1; is_silent_allow && pass "Write into a submodule of a linked worktree: allow" || fail "submodule under worktree" "$GOUT"
else fail "fixture: submodule under a worktree not created"; fi
j="$(CWD_FIX="$P" mk Write file_path "$W/x.md")"; run_guard "$j" X=1; is_silent_allow && pass "cwd in the primary, target in a worktree: allow (the target decides)" || fail "target vs cwd"
j="$(CWD_FIX="$W" mk Write file_path "$P/x.md")"; run_guard "$j" X=1; is_deny && pass "cwd in a worktree, absolute target in the primary: deny" || fail "worktree cwd, primary target"
j="$(CWD_FIX="$P" mk Write file_path "rel/x.md")"; run_guard "$j" X=1; is_deny && pass "relative path resolved against a primary cwd: deny" || fail "relative path"
j="$(PRE='"content":"line \"file_path\":\"/tmp/x\" end","' mk Write file_path "$P/x.md")"; run_guard "$j" X=1
is_deny && pass "a file_path inside the content string does not fool the parser" || fail "content spoof" "$GOUT"
j="$(POST=',"content":"a\\\\b \"quoted\" \u00e9"' mk Write file_path "$P/x.md")"; run_guard "$j" X=1
is_deny && pass "escapes in other fields do not break the parser" || fail "escapes" "$GOUT"
run_guard "$(mk Write file_path "$W/bad\\u0041.md")" X=1
is_deny && pass "unsupported escape in the path: deny (fail closed)" || fail "unsupported escape" "$GOUT"

echo "-- malformed input fails closed"
run_guard '{"tool_name":"Write","cwd":"/x","tool_input":{}}' X=1;      is_deny && pass "Write without file_path: deny" || fail "missing file_path"
run_guard '{"tool_name":"Edit","tool_input":{"file_path":null}}' X=1;  is_deny && pass "null file_path: deny" || fail "null file_path"
run_guard 'not json at all' X=1;                                       is_deny && pass "garbage input: deny (fail closed)" || fail "garbage" "$GOUT"
run_guard '' X=1;                                                      is_deny && pass "empty input: deny" || fail "empty input" "$GOUT"
run_guard '{"cwd":"/x","tool_input":{}}' X=1;                          is_deny && pass "JSON without tool_name: deny" || fail "no tool_name" "$GOUT"
run_guard '{"tool_name":null}' X=1;                                    is_deny && pass "null tool_name: deny" || fail "null tool_name" "$GOUT"
run_guard '{"tool_name":""}' X=1;                                      is_deny && pass "empty tool_name: deny" || fail "empty tool_name" "$GOUT"
run_guard '{"tool_name":"Write","tool_input":{"file_path":"/x"}' X=1;  is_deny && pass "truncated JSON: deny" || fail "truncated" "$GOUT"
run_guard '["tool_name","Read"]' X=1;                                  is_deny && pass "JSON array: deny" || fail "array" "$GOUT"
big="$(head -c 60000 /dev/zero | tr '\0' a)"
run_guard "$(POST=",\"content\":\"$big\"" mk Write file_path "$W/big.md")" X=1; is_silent_allow && pass "60 KB Write in a worktree: allow, input larger than the balance check" || fail "large input" "$GOUT"
run_guard "$(POST=",\"content\":\"$big\"" mk Write file_path "$P/big.md")" X=1; is_deny && pass "60 KB Write in the primary: deny" || fail "large input, primary"
run_guard '{"tool_name":"SomeNewTool","tool_input":{}}' X=1;           is_silent_allow && pass "readable but unhandled tool: allow" || fail "unhandled tool" "$GOUT"
run_guard '{"tool_name":"Bash","tool_input":{}}' X=1;                  is_deny && pass "Bash without a readable command: deny" || fail "Bash no command"

echo "-- other tools are not touched"
run_guard '{"tool_name":"Read","tool_input":{"file_path":"'"$P"'/a.txt"}}' X=1;  is_silent_allow && pass "Read in the primary: allow (read-only analysis stays possible)" || fail "Read"
run_guard '{"tool_name":"Grep","tool_input":{"pattern":"x","path":"'"$P"'"}}' X=1; is_silent_allow && pass "Grep in the primary: allow" || fail "Grep"
run_guard '{"tool_name":"Bash","cwd":"'"$P"'","tool_input":{"command":"git status --short && git log --oneline | head"}}' X=1
is_silent_allow && pass "read-only Bash in the primary: allow" || fail "read-only Bash" "$GOUT"

echo "-- bypass attempts in Bash"
for cmd in 'HOME_OPS_BREAK_GLASS=because git commit -m x' 'export HOME_OPS_BREAK_GLASS="x"; git commit -m y' 'CLAUDE_ALLOW_MAIN_EDITS=1 touch a' 'git commit --no-verify -m x' 'git -c core.hooksPath=/dev/null commit -m x' 'SKIP=worktree-first git commit -m x'; do
  run_guard '{"tool_name":"Bash","cwd":"'"$W"'","tool_input":{"command":"'"$cmd"'"}}' X=1
  is_deny && pass "denied: $cmd" || fail "bypass allowed: $cmd" "$GOUT"
done

echo "-- break-glass is set by a human before the session"
L="$P/.git/break-glass.log"; rm -f "$L"
run_guard "$(mk Write file_path "$P/x.md")" HOME_OPS_BREAK_GLASS="owner edits the primary on purpose"
is_silent_allow && grep -q 'owner edits the primary' "$L" && pass "env set at launch: allowed and logged" || fail "break-glass at launch" "$GOUT"
rm -f "$L"
run_guard "$(mk Write file_path "$P/x.md")" HOME_OPS_BREAK_GLASS=""
is_deny && [ ! -e "$L" ] && pass "empty reason: deny, nothing logged" || fail "empty reason"

echo "-- fail closed when a tool is missing"
TG="$SB/tools-nogit"; tool_path "$TG" sh dash bash cat date id tr
GOUT="$(printf '%s' "$(mk Write file_path "$W/x.md")" | env PATH="$TG" sh "$GUARD" 2>/dev/null)"; GRC=$?
is_deny && pass "git missing: deny, not allow" || fail "git missing" "$GOUT"
cp "$GUARD" "$SB/lonely-guard"; chmod +x "$SB/lonely-guard"
GOUT="$(printf '%s' "$(mk Write file_path "$W/x.md")" | env PATH="$TP" sh "$SB/lonely-guard" 2>/dev/null)"
is_deny && pass "worktree-preflight missing next to the guard: deny" || fail "preflight missing" "$GOUT"

echo "-- settings.json wiring"
S="$REPO_ROOT/.claude/settings.json"
jq -e '.hooks.PreToolUse | length == 1 and (.[0].matcher == "Edit|Write|NotebookEdit|Bash")' "$S" >/dev/null && pass "one PreToolUse entry with the expected matcher" || fail "matcher"
cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")"
case "$cmd" in *'.agents/bin/claude-pretool-guard'*'exit 2'*) pass "command calls the guard and turns any failure into exit 2 (block)" ;; *) fail "command wrapper" "$cmd" ;; esac
# Run the real command string the way Claude Code would: from the project directory, with a missing guard.
out="$(cd "$SB" && CLAUDE_PROJECT_DIR="$SB/no-such-project" sh -c "$cmd" </dev/null 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "guard file missing: the wrapper exits 2, so Claude Code blocks" || fail "missing guard did not block" "rc=$rc $out"
out="$(printf '%s' "$(mk Write file_path "$P/x.md")" | CLAUDE_PROJECT_DIR="$REPO_ROOT" PATH="$TP" sh -c "$cmd" 2>&1)"; rc=$?
case "$out" in *'"permissionDecision":"deny"'*) [ "$rc" = 0 ] && pass "the real command string denies a primary write end to end" || fail "exit code" "$rc" ;; *) fail "end to end" "$out" ;; esac
printf '%s' "$out" | jq -e '.hookSpecificOutput.hookEventName=="PreToolUse" and .hookSpecificOutput.permissionDecision=="deny" and (.hookSpecificOutput.permissionDecisionReason|length>0)' >/dev/null && pass "deny output is valid JSON in the PreToolUse shape" || fail "deny JSON shape" "$out"

echo "-- Windows"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) not_run "Claude hook under Git Bash on Windows" "no Windows host; Claude Code runs hooks through a POSIX shell, path forms like C:\\ are untested" ;; esac

echo "-- the test changed nothing outside its temporary directory"
assert_real_repo_untouched
cd / || exit 2
finish
