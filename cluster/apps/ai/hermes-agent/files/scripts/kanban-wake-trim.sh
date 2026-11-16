#!/bin/bash
# Stops kanban notices from waking `default` for cards that need nothing from it. Run by the script-only cron job
# kanban-wake-trim every minute, with no model. It prints nothing on success; an error is printed, and so posted.
#
# A card created from a Discord chat subscribes that chat with delivery mode notify+wake, and cards created from it copy
# the subscription (Hermes v0.23.1; the wake kinds cannot be configured). Each wake is a full `default` turn. This
# script sets every notify+wake subscription to notify (the short notice is still posted, no turn starts), except on a
# worker card whose skills include implement-task: its completion has a next step (spec-author opens the PR) and its
# block, give-up, crash or timeout needs an answer. A card that finishes within a minute of its creation can still
# wake once.
set -u
PY=/opt/hermes/.venv/bin/python
BOARDS="$(hermes kanban boards list --json 2>/dev/null | "$PY" -c '
import json
import sys

for board in json.load(sys.stdin):
    print(board["slug"])
')" || { echo "kanban-wake-trim: could not list the kanban boards"; exit 0; }
for BOARD in $BOARDS; do
  SUBS="$(hermes kanban --board "$BOARD" notify-list --json 2>/dev/null)" ||
    { echo "kanban-wake-trim: could not list subscriptions on board $BOARD"; continue; }
  TASKS="$(hermes kanban --board "$BOARD" list --json 2>/dev/null)" ||
    { echo "kanban-wake-trim: could not list cards on board $BOARD"; continue; }
  # One line per subscription to trim: task, platform, chat, thread (empty for none), tab-separated.
  TRIM="$("$PY" -c '
import json
import sys

subs, tasks = json.loads(sys.argv[1] or "[]"), json.loads(sys.argv[2] or "[]")
cards = {task["id"]: task for task in tasks}
for sub in subs:
    card = cards.get(sub["task_id"])
    if (sub.get("delivery_mode") or "notify") != "notify+wake" or card is None:
        continue
    if card.get("assignee") == "worker" and "implement-task" in (card.get("skills") or []):
        continue
    print("\t".join((sub["task_id"], sub["platform"], sub["chat_id"], sub.get("thread_id") or "")))
' "$SUBS" "$TASKS")" || { echo "kanban-wake-trim: could not read subscriptions on board $BOARD"; continue; }
  while IFS=$'\t' read -r TASK PLATFORM CHAT THREAD; do
    [ -n "$TASK" ] || continue
    ARGS=(--board "$BOARD" notify-subscribe "$TASK" --platform "$PLATFORM" --chat-id "$CHAT" --delivery-mode notify)
    [ -z "$THREAD" ] || ARGS+=(--thread-id "$THREAD")
    hermes kanban "${ARGS[@]}" >/dev/null 2>&1 || echo "kanban-wake-trim: could not set $BOARD/$TASK to notify"
  done <<<"$TRIM"
done
