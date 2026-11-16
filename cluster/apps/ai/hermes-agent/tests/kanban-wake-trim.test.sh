#!/bin/bash
# Tests files/scripts/kanban-wake-trim.sh against a fake `hermes` CLI and a fake clock. Run:
#   bash cluster/apps/ai/hermes-agent/tests/kanban-wake-trim.test.sh
# Needs bash and python3; exits non-zero on the first failed check.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../files/scripts/kanban-wake-trim.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export LOG="$WORK/calls.log" FAILS="$WORK/fails.txt" KANBAN_WAKE_TRIM_STATE="$WORK/state.txt" KANBAN_WAKE_TRIM_PYTHON
KANBAN_WAKE_TRIM_PYTHON="$(command -v python3)"
export PATH="$WORK/bin:$PATH"

# Cards on board `default`:
#   t1 worker implement-task, notify+wake (keep)       t2 human card, notify+wake (trim)
#   t3 worker renovate-fix, notify+wake (trim)         t4 human card, notify (keep)
#   t5 worker implement-task, inherited notify from a trimmed human parent, no thread (promote)
#   t6 TUI subscription, notify (left alone, never read)
# A call whose arguments equal a line of $FAILS exits 1.
cat >"$WORK/bin/hermes" <<'EOF'
#!/bin/bash
echo "$*" >>"$LOG"
if [ -s "$FAILS" ] && grep -qxF -- "$*" "$FAILS"; then exit 1; fi
case "$*" in
  "kanban boards list --json") echo '[{"slug":"default"},{"slug":"renovate"}]' ;;
  "kanban --board default notify-list --json")
    echo '[{"task_id":"t1","platform":"discord","chat_id":"c","thread_id":"th","delivery_mode":"notify+wake"},
           {"task_id":"t2","platform":"discord","chat_id":"c","thread_id":"th","delivery_mode":"notify+wake"},
           {"task_id":"t3","platform":"discord","chat_id":"c","thread_id":"th","delivery_mode":"notify+wake"},
           {"task_id":"t4","platform":"discord","chat_id":"c","thread_id":"th","delivery_mode":"notify"},
           {"task_id":"t5","platform":"discord","chat_id":"c","thread_id":null,"delivery_mode":"notify"},
           {"task_id":"t6","platform":"tui","chat_id":"k","thread_id":null,"delivery_mode":"notify"}]' ;;
  "kanban --board renovate notify-list --json") echo '[]' ;;
  "kanban --board default show t1 --json"|"kanban --board default show t5 --json")
    echo '{"task":{"id":"x","assignee":"worker","skills":["implement-task"]}}' ;;
  "kanban --board default show t2 --json"|"kanban --board default show t4 --json")
    echo '{"task":{"id":"x","assignee":"default","skills":[]}}' ;;
  "kanban --board default show t3 --json") echo '{"task":{"id":"x","assignee":"worker","skills":["renovate-fix"]}}' ;;
  *notify-subscribe*) ;;
  *) echo "unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/hermes"

fail() { echo "FAIL: $*"; echo "--- calls"; cat "$LOG"; echo "--- state"; cat "$KANBAN_WAKE_TRIM_STATE"; exit 1; }
reset() { : >"$KANBAN_WAKE_TRIM_STATE"; : >"$FAILS"; }
run() { # $1: fake time in seconds. Sets OUT to the script's stdout, LINES to its line count.
  : >"$LOG"
  OUT="$(KANBAN_WAKE_TRIM_NOW="$1" bash "$SCRIPT")" || fail "script exited non-zero"
  LINES=$(printf '%s' "$OUT" | grep -c . || true)
}
expect_lines() { [ "$LINES" -eq "$1" ] || fail "$2: expected $1 line(s), got: $OUT"; }
expect_calls() { # $1: description, then the exact notify-subscribe calls expected, in order
  local what="$1"; shift
  local got want
  got="$(grep notify-subscribe "$LOG" || true)"
  want="$(printf '%s\n' "$@")"
  [ "$got" = "${want%$'\n'}" ] || fail "$what: notify-subscribe calls were:"$'\n'"$got"
}
T0=1800000000

# 1. Every new subscription is read once and set to its wanted mode; a clean run prints nothing.
reset
run $T0
expect_lines 0 "clean run 1"
expect_calls "clean run 1" \
  "kanban --board default notify-subscribe t2 --platform discord --chat-id c --delivery-mode notify --thread-id th" \
  "kanban --board default notify-subscribe t3 --platform discord --chat-id c --delivery-mode notify --thread-id th" \
  "kanban --board default notify-subscribe t5 --platform discord --chat-id c --delivery-mode notify+wake"
! grep -v "boards list\|notify-list" "$LOG" | grep -q " list" || fail "clean run 1 called kanban list"
! grep -q "show t6" "$LOG" || fail "clean run 1 read the TUI card"
[ "$(grep -c . "$KANBAN_WAKE_TRIM_STATE")" -eq 6 ] || fail "state file should hold 6 keys"

# 2. Nothing new: no card is read, nothing changes, nothing is printed.
run $((T0 + 60))
expect_lines 0 "clean run 2"
expect_calls "clean run 2"
! grep -q " show " "$LOG" || fail "clean run 2 read a card"

# 3. One failing key: one line on run 1, silence on runs 2 to 5 (card retried each time), one "still failing" line
#    after 60 minutes, silence again, then one "recovered" line and silence.
reset
echo "kanban --board default show t2 --json" >"$FAILS"
run $T0
expect_lines 1 "failure run 1"
[[ "$OUT" == *"could not read card default/t2"* ]] || fail "failure run 1 printed: $OUT"
for i in 2 3 4 5; do
  run $((T0 + (i - 1) * 60))
  expect_lines 0 "failure run $i"
  grep -q "show t2" "$LOG" || fail "failure run $i did not retry card t2"
done
run $((T0 + 3600))
expect_lines 1 "failure after 60 minutes"
[[ "$OUT" == *"still failing since 2027-01-15 08:00 UTC, 6 runs"* ]] || fail "still-failing line: $OUT"
run $((T0 + 3660))
expect_lines 0 "failure after the still-failing line"
: >"$FAILS"
run $((T0 + 3720))
expect_lines 1 "recovery"
[[ "$OUT" == *"default:t2:show recovered after 7 failed runs"* ]] || fail "recovery line: $OUT"
grep -q "notify-subscribe t2" "$LOG" || fail "recovery run did not trim t2"
run $((T0 + 3780))
expect_lines 0 "after recovery"
! grep -q "^fail" "$KANBAN_WAKE_TRIM_STATE" || fail "recovered key left in the state file"

# 4. Two different failing keys each print once.
reset
printf '%s\n' "kanban --board default show t2 --json" "kanban --board renovate notify-list --json" >"$FAILS"
run $T0
expect_lines 2 "two keys"
[[ "$OUT" == *"default/t2"* && "$OUT" == *"board renovate"* ]] || fail "two keys printed: $OUT"
run $((T0 + 60))
expect_lines 0 "two keys, run 2"

# 5. A corrupt state file prints one line, does not crash, and the run still does its work.
reset
printf 'garbage line\nfail\tx\tnot-a-number\n' >"$KANBAN_WAKE_TRIM_STATE"
run $T0
expect_lines 1 "corrupt state"
[[ "$OUT" == *"could not be read; starting with an empty state"* ]] || fail "corrupt state printed: $OUT"
grep -q "notify-subscribe t5" "$LOG" || fail "corrupt state run did not do its work"
run $((T0 + 60))
expect_lines 0 "after corrupt state"

# 6. A missing state file prints one line.
rm -f "$KANBAN_WAKE_TRIM_STATE"; : >"$FAILS"
run $T0
expect_lines 1 "missing state"
[[ "$OUT" == *"was missing"* ]] || fail "missing state printed: $OUT"

echo "PASS: kanban-wake-trim"
