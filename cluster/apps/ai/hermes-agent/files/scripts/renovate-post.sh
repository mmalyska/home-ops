#!/bin/bash
# Posts the result of each finished renovate-summary and renovate-merge-report card on the renovate board, once.
# Run by the script-only cron job renovate-post: its stdout is delivered to #hermes-renovate word for word, and an
# empty stdout posts nothing. Posted card IDs are kept in a state file on the data volume.
set -u
STATE=/opt/data/cron/renovate-posted.txt
touch "$STATE"
hermes kanban --board renovate list --status "done" --json 2>/dev/null | /opt/hermes/.venv/bin/python -c '
import json
import subprocess
import sys

state_path = sys.argv[1]
posted = set(open(state_path).read().split())
data = json.load(sys.stdin)
tasks = data if isinstance(data, list) else data.get("tasks", [])
new = []
for task in sorted(tasks, key=lambda t: t.get("completed_at") or t.get("updated_at") or 0):
    title = task.get("title") or ""
    if task.get("id") in posted or not title.startswith(("renovate-summary ", "renovate-merge-report ")):
        continue
    text = (task.get("result") or "").strip()
    if not text:
        shown = subprocess.run(["hermes", "kanban", "--board", "renovate", "show", task["id"], "--json"],
                               capture_output=True, text=True, timeout=60)
        try:
            text = (json.loads(shown.stdout).get("latest_summary") or "").strip()
        except ValueError:
            text = ""
    if text:
        print(text)
        print()
    new.append(task["id"])
with open(state_path, "a") as state:
    for task_id in new:
        state.write(task_id + "\n")
' "$STATE"
