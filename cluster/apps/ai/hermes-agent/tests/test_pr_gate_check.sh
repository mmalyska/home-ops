#!/bin/bash
# Tests files/scripts/pr-gate-check.py against fixture card output (`hermes kanban show <id> --json`).
# Run from anywhere: bash cluster/apps/ai/hermes-agent/tests/test_pr_gate_check.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../files/scripts/pr-gate-check.py"
export HERMES_BIN="$here/fixtures/pr-gate-check/fake-hermes"
failures=0

report() { # name, ok (0/1), output
  if [ "$2" = 0 ]; then
    echo "ok   $1"
  else
    echo "FAIL $1, output:"
    printf '     %s\n' "${3//$'\n'/$'\n'     }"
    failures=$((failures + 1))
  fi
}

# Card mode: name, expected exit code, expected output substring, args...
card() {
  local name=$1 want=$2 text=$3 out code
  shift 3
  out=$(python3 "$script" "$@" 2>&1)
  code=$?
  [ "$code" = "$want" ] && grep -qF -- "$text" <<<"$out"
  report "$name (exit $code, want $want)" $? "$out"
}

payload() {
  python3 - "$1" <<'PY'
import json, sys
print(json.dumps({"hook_event_name": "pre_tool_call", "tool_name": "terminal", "tool_input": {"command": sys.argv[1]}}))
PY
}
run_hook() { out=$(printf '%s' "$1" | python3 "$script" --hook 2>&1); code=$?; }

# Hook mode, the command lets the call through: exactly {} and exit 0.
allows() {
  run_hook "$(payload "$2")"
  [ "$code" = 0 ] && [ "$out" = "{}" ]
  report "allows: $1" $? "$out"
}
# Hook mode, the call is blocked with a message holding the reason and the full instruction.
blocks_raw() { # name, raw payload, reason substring
  run_hook "$2"
  [ "$code" = 0 ] && grep -qF '"action": "block"' <<<"$out" && grep -qF -- "$3" <<<"$out" &&
    grep -qF 'GATE_CARDS=none gh pr create ...' <<<"$out"
  report "blocks: $1" $? "$out"
}
blocks() { blocks_raw "$1" "$(payload "$2")" "$3"; }

# --- card mode ----------------------------------------------------------------------------------
card "pass: done card, latest evidence comment by the worker has PASS and no FAIL" 0 \
  "PASS t_0000aaaa (T3 verify and hand off): done, evidence by worker" t_0000aaaa
card "fail: done card without an evidence comment" 1 "FAIL t_0000bbbb (T2 implement): no evidence comment" t_0000bbbb
card "fail: blocked card, even with evidence" 1 \
  "FAIL t_0000cccc (H2 owner approves the plan revision): status is blocked, not done" t_0000cccc
card "fail: evidence reports FAIL" 1 "evidence reports FAIL for renovate lock update" t_0000dddd
card "fail: latest evidence comment written by default, not the worker" 1 \
  "the latest evidence comment is by default, not the worker profile" t_0000eeee
card "fail: the hermes CLI crashes" 1 "could not read the card (exit 1: sqlite3.OperationalError: database is locked)" t_00001111
card "fail: the hermes CLI prints no JSON" 1 "kanban show printed no JSON" t_00002222
card "fail: one failing card fails the set" 1 "FAIL t_0000bbbb" t_0000aaaa t_0000bbbb
card "fail: unknown card" 1 "could not read the card (exit 1: no such task: t_0000ffff)" t_0000ffff
card "fail: malformed id" 1 "not a kanban card id" 'bad;id'
card "usage without ids" 2 "usage:"

# --- hook mode: what passes ---------------------------------------------------------------------
allows "other commands" 'git status'
allows "reading a PR" 'gh pr view 6311 --json state'
allows "reading PR files through gh api" 'gh api repos/mmalyska/home-ops/pulls/6311/files'
allows "GATE_CARDS=none on a spec PR" 'GATE_CARDS=none gh pr create --title x --body-file /tmp/b.md --label triage/owner'
allows "a passing gate card, after cd &&" \
  'cd /workspaces/repos/home-ops && GATE_CARDS="t_0000aaaa" gh pr create --title x --body-file /tmp/b.md'
allows "a here-document body with quotes and the word GATE" "$(printf '%s\n' \
  "GATE_CARDS=none gh pr create --title x --body-file - <<'EOF'" \
  "Hermes' plan: the gate's cards are listed in the plan." \
  "EOF")"

# --- hook mode: the bypasses the review found -----------------------------------------------------
blocks "GATE_CARDS=none in an earlier command" 'GATE_CARDS=none; echo; gh pr create --title x' \
  "GATE_CARDS is not the leading assignment of gh pr create"
blocks "GATE_CARDS=none in a comment" 'gh pr create --title x # GATE_CARDS=none' \
  "GATE_CARDS is not the leading assignment of gh pr create"
blocks "a second gh pr create after a passing one" 'GATE_CARDS=t_0000aaaa gh pr create --title a; gh pr create --title b' \
  "contains gh pr create more than once"
blocks "a gate card whose evidence was written by default" 'GATE_CARDS=t_0000eeee gh pr create --title x' \
  "the latest evidence comment is by default, not the worker profile"
blocks "a gate card the CLI crashes on" 'GATE_CARDS=t_00001111 gh pr create --title x' "could not read the card (exit 1"
blocks "a gate card the CLI prints no JSON for" 'GATE_CARDS=t_00002222 gh pr create --title x' "kanban show printed no JSON"
blocks_raw "an unreadable hook payload" 'not json' "the hook payload could not be read"
blocks_raw "a terminal call with no command" '{"tool_name": "terminal", "tool_input": {}}' "the terminal call has no command"
blocks_raw "a terminal call with an empty command" '{"tool_name": "terminal", "tool_input": {"command": "  "}}' \
  "the terminal call has no command"

# --- hook mode: other refusals ----------------------------------------------------------------------
blocks "a PR without GATE_CARDS" 'gh pr create --title x --body y' "GATE_CARDS appears 0 times"
blocks "GATE_CARDS twice" 'GATE_CARDS=none gh pr create --title "GATE_CARDS"' "GATE_CARDS appears 2 times"
blocks "GATE_CARDS exported before the command" 'export GATE_CARDS=none && gh pr create --title x' \
  "GATE_CARDS is not the leading assignment of gh pr create"
blocks "missing evidence" 'GATE_CARDS="t_0000aaaa t_0000bbbb" gh pr create --title x' "t_0000bbbb (T2 implement): no evidence comment"
blocks "a blocked gate card" "GATE_CARDS='t_0000cccc' gh pr create --title x" "status is blocked, not done"
blocks "none mixed with card ids" 'GATE_CARDS="none t_0000aaaa" gh pr create --title x' "mixes none with card ids"
blocks "gh pr create in a subshell" 'GATE_CARDS=none bash -c "gh pr create --title x"' "must be a plain command"
# The command text is literal on purpose: backticks and $( ) must reach the hook unexpanded.
# shellcheck disable=SC2016
blocks "gh pr create in backticks" 'GATE_CARDS=none echo `gh pr create --title x`' "must be a plain command"
# shellcheck disable=SC2016
blocks "gh pr create in \$( )" 'GATE_CARDS=none x=$(gh pr create --title x)' "GATE_CARDS is not the leading assignment"
blocks "creating a PR through gh api" 'gh api repos/mmalyska/home-ops/pulls -f title=x -f head=b -f base=main' \
  "creates a PR without gh pr create"
blocks "creating a PR through gh api, method first" 'gh api -X POST repos/mmalyska/home-ops/pulls --input b.json' \
  "creates a PR without gh pr create"
blocks "creating a PR through GraphQL" \
  "gh api graphql -f query='mutation { createPullRequest(input: {repositoryId: \"x\", baseRefName: \"main\", headRefName: \"b\", title: \"t\"}) { pullRequest { url } } }'" \
  "creates a PR without gh pr create"
blocks "creating a PR through curl" 'curl -X POST -d @b.json https://api.github.com/repos/mmalyska/home-ops/pulls' \
  "creates a PR without gh pr create"
blocks "unbalanced quotes" 'GATE_CARDS=none gh pr create --title "x' "could not be parsed"

if [ "$failures" -gt 0 ]; then
  echo "$failures test(s) failed"
  exit 1
fi
echo "all tests passed"
