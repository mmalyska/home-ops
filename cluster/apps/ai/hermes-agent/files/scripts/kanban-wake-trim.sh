#!/bin/bash
# Makes kanban notices wake `default` only for cards that need it. Run by the script-only cron job kanban-wake-trim
# every minute, with no model. It prints nothing on success; an error is printed, and so posted.
#
# A card created from a Discord chat subscribes that chat with delivery mode notify+wake, and a card created with
# parents copies their subscriptions, mode included (Hermes v0.23.1; the wake kinds cannot be configured). Each wake
# is a full `default` turn. The wanted mode of a subscription is:
#   - notify+wake on a worker card whose skills include implement-task: its completion has a next step (spec-author
#     opens the PR) and its block, give-up, crash or timeout needs an answer. Such a card whose parent is a human card
#     inherits notify, so it is promoted here.
#   - notify (the short notice only, no turn) on every other card.
# Mode `wake` and TUI subscriptions are left alone. Each subscription is checked once: its key is kept in a state file,
# so the board is read with `kanban show` (read-only) only for new subscriptions. `kanban list` is not used: it writes
# to the board (recompute_ready). A card that finishes within a minute of its creation can still wake once.
set -u
PY=${KANBAN_WAKE_TRIM_PYTHON:-/opt/hermes/.venv/bin/python}
STATE=${KANBAN_WAKE_TRIM_STATE:-/opt/data/cron/kanban-wake-trim.txt}
touch "$STATE" || { echo "kanban-wake-trim: cannot write $STATE"; exit 0; }
BOARDS="$(hermes kanban boards list --json 2>/dev/null | "$PY" -c '
import json
import sys

for board in json.load(sys.stdin):
    print(board["slug"])
')" || { echo "kanban-wake-trim: could not list the kanban boards"; exit 0; }
NEW_STATE="$(mktemp)"
trap 'rm -f "$NEW_STATE"' EXIT
for BOARD in $BOARDS; do
  SUBS="$(hermes kanban --board "$BOARD" notify-list --json 2>/dev/null)" ||
    { echo "kanban-wake-trim: could not list subscriptions on board $BOARD"; grep "^$BOARD"$'\t' "$STATE" >>"$NEW_STATE"; continue; }
  # One line per subscription, tab-separated: board, task, platform, chat, mode ("seen" when its key is in the state
  # file), thread. The thread comes last because `read` merges empty tab-separated fields, and it is empty for none.
  LINES="$("$PY" -c '
import json
import sys

board, state_path, subs = sys.argv[1], sys.argv[2], json.loads(sys.argv[3] or "[]")
seen = set(open(state_path).read().splitlines())
for sub in subs:
    key = "\t".join((board, sub["task_id"], sub["platform"], sub["chat_id"], sub.get("thread_id") or ""))
    mode = sub.get("delivery_mode") or "notify"
    print("\t".join((board, sub["task_id"], sub["platform"], sub["chat_id"], "seen" if key in seen else mode,
                     sub.get("thread_id") or "")))
' "$BOARD" "$STATE" "$SUBS")" || { echo "kanban-wake-trim: could not read subscriptions on board $BOARD"; continue; }
  while IFS=$'\t' read -r _ TASK PLATFORM CHAT MODE THREAD; do
    [ -n "$TASK" ] || continue
    printf -v KEY '%s\t%s\t%s\t%s\t%s' "$BOARD" "$TASK" "$PLATFORM" "$CHAT" "$THREAD"
    if [ "$MODE" = seen ] || [ "$MODE" = wake ] || [ "$PLATFORM" = tui ]; then
      echo "$KEY" >>"$NEW_STATE"
      continue
    fi
    WANT="$(hermes kanban --board "$BOARD" show "$TASK" --json 2>/dev/null | "$PY" -c '
import json
import sys

task = json.load(sys.stdin)["task"]
print("notify+wake" if task.get("assignee") == "worker" and "implement-task" in (task.get("skills") or []) else "notify")
')" || { echo "kanban-wake-trim: could not read card $BOARD/$TASK"; continue; }
    if [ "$WANT" != "$MODE" ]; then
      ARGS=(--board "$BOARD" notify-subscribe "$TASK" --platform "$PLATFORM" --chat-id "$CHAT" --delivery-mode "$WANT")
      [ -z "$THREAD" ] || ARGS+=(--thread-id "$THREAD")
      hermes kanban "${ARGS[@]}" >/dev/null 2>&1 ||
        { echo "kanban-wake-trim: could not set $BOARD/$TASK to $WANT"; continue; }
    fi
    echo "$KEY" >>"$NEW_STATE"
  done <<<"$LINES"
done
# Keys of subscriptions that no longer exist (archived cards) drop out here.
cat "$NEW_STATE" >"$STATE"
