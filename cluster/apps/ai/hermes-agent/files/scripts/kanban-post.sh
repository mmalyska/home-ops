#!/bin/bash
# Posts each blocked and each finished card of every kanban board except renovate, once, with the block reason or
# the start of the result. Run by the script-only cron job kanban-post: its stdout is delivered to #hermes word for
# word, and an empty stdout posts nothing.
# kanban.auto_subscribe_on_create is off for default, so no session hears about a card it created; without this job a
# blocked worker card of a spec-driven piece of work waits unseen. The renovate board has renovate-post instead.
# Posted events are kept in a state file on the data volume, keyed by card, status and event time, so a card that is
# blocked again later is posted again. On the first run (no state file) done cards are recorded without posting, so
# the history of the boards is not replayed; blocked cards are posted.
set -u
STATE=/opt/data/cron/kanban-posted.txt
FIRST_RUN=0
[ -e "$STATE" ] || FIRST_RUN=1
touch "$STATE"
BOARDS="$(hermes kanban boards list --json 2>/dev/null | /opt/hermes/.venv/bin/python -c '
import json
import sys

data = json.load(sys.stdin)
for board in data if isinstance(data, list) else data.get("boards", []):
    if board.get("slug") and board["slug"] != "renovate":
        print(board["slug"])
' 2>/dev/null)" || { echo "kanban-post: could not list the kanban boards"; exit 0; }
for BOARD in $BOARDS; do
  for STATUS in blocked "done"; do
    # shellcheck disable=SC2016 # the quoted text is Python source, not shell
    hermes kanban --board "$BOARD" list --status "$STATUS" --json 2>/dev/null | /opt/hermes/.venv/bin/python -c '
import json
import re
import subprocess
import sys


def no_previews(text):
    text = re.sub(r"\]\((https?://[^\s()<>]+)\)", r"](<\1>)", text)
    return re.sub(r"(?<!<)(https?://[^\s<>()]*[^\s<>().,;:!?\]\x27\x22])", r"<\1>", text)


def short(text, limit):
    text = text.strip()
    return text if len(text) <= limit else text[:limit].rstrip() + " …"


state_path, board, status, first_run = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
posted = set(open(state_path).read().split())
data = json.load(sys.stdin)
tasks = data if isinstance(data, list) else data.get("tasks", [])
new = []
for task in tasks:
    shown = {}
    if status == "blocked":
        out = subprocess.run(["hermes", "kanban", "--board", board, "show", task["id"], "--json"],
                             capture_output=True, text=True, timeout=60)
        try:
            shown = json.loads(out.stdout)
        except ValueError:
            shown = {}
        blocks = [e for e in shown.get("events", []) if e.get("kind") == "blocked"]
        stamp = blocks[-1].get("created_at") if blocks else task.get("created_at")
        reason = (blocks[-1].get("payload") or {}).get("reason") if blocks else ""
        text = reason or shown.get("latest_summary") or ""
    else:
        stamp = task.get("completed_at")
        text = task.get("result") or ""
    key = "{}:{}:{}".format(task["id"], status, stamp)
    if key in posted:
        continue
    new.append(key)
    if status == "done" and first_run:
        continue
    if status == "done" and not text:
        out = subprocess.run(["hermes", "kanban", "--board", board, "show", task["id"], "--json"],
                             capture_output=True, text=True, timeout=60)
        try:
            text = json.loads(out.stdout).get("latest_summary") or ""
        except ValueError:
            text = ""
    head = "**{}** · board `{}` · `{}` {} ({})".format(
        "Blocked, waiting for an answer" if status == "blocked" else "Done",
        board, task["id"], task.get("title") or "", task.get("assignee") or "unassigned")
    print(no_previews(head))
    if text:
        print(no_previews(short(text, 900 if status == "blocked" else 500)))
    print()
with open(state_path, "a") as state:
    for key in new:
        state.write(key + "\n")
' "$STATE" "$BOARD" "$STATUS" "$FIRST_RUN"
  done
done
