#!/bin/bash
# Tests files/scripts/kanban-wake-trim.sh against a fake `hermes` CLI. Run: bash tests/kanban-wake-trim.test.sh
# (from the chart folder or anywhere). Needs bash and python3; exits non-zero on the first failed check.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../files/scripts/kanban-wake-trim.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export LOG="$WORK/calls.log" KANBAN_WAKE_TRIM_STATE="$WORK/state.txt" KANBAN_WAKE_TRIM_PYTHON
KANBAN_WAKE_TRIM_PYTHON="$(command -v python3)"
export PATH="$WORK/bin:$PATH"

# Cards on board `default`:
#   t1 worker implement-task, notify+wake (keep)       t2 human card, notify+wake (trim)
#   t3 worker renovate-fix, notify+wake (trim)         t4 human card, notify (keep)
#   t5 worker implement-task, inherited notify from a trimmed human parent, no thread (promote)
#   t6 TUI subscription, notify (left alone, never read)
cat >"$WORK/bin/hermes" <<'EOF'
#!/bin/bash
echo "$*" >>"$LOG"
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

fail() { echo "FAIL: $*"; echo "--- calls"; cat "$LOG"; exit 1; }
expect_calls() { # $1: description, then the exact notify-subscribe calls expected, in order
  local what="$1"; shift
  local got want
  got="$(grep notify-subscribe "$LOG" || true)"
  want="$(printf '%s\n' "$@")"
  [ "$got" = "${want%$'\n'}" ] || fail "$what: notify-subscribe calls were:"$'\n'"$got"
}

# Run 1: every new subscription is read once and set to its wanted mode.
: >"$LOG"
OUT="$(bash "$SCRIPT")"
[ -z "$OUT" ] || fail "run 1 printed: $OUT"
expect_calls "run 1" \
  "kanban --board default notify-subscribe t2 --platform discord --chat-id c --delivery-mode notify --thread-id th" \
  "kanban --board default notify-subscribe t3 --platform discord --chat-id c --delivery-mode notify --thread-id th" \
  "kanban --board default notify-subscribe t5 --platform discord --chat-id c --delivery-mode notify+wake"
! grep -q " list --json" <(grep -v "boards list\|notify-list" "$LOG") || fail "run 1 called kanban list"
! grep -q "show t6" "$LOG" || fail "run 1 read the TUI card"
[ "$(wc -l <"$KANBAN_WAKE_TRIM_STATE")" -eq 6 ] || fail "state file should hold 6 keys"

# Run 2: nothing new, so no card is read and nothing changes.
: >"$LOG"
OUT="$(bash "$SCRIPT")"
[ -z "$OUT" ] || fail "run 2 printed: $OUT"
expect_calls "run 2"
! grep -q " show " "$LOG" || fail "run 2 read a card"

echo "PASS: kanban-wake-trim"
