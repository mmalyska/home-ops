#!/bin/bash
# Archives done cards on the renovate board that finished more than 14 days ago, so the board stays readable.
# Run by the script-only cron job renovate-cleanup. It prints nothing on success; an error is printed, and so posted.
# Archiving frees a card's idempotency key. That is safe: the coordinator creates a check card only for a PR without a
# verdict matching its current diff, and every other key carries a date or a commit.
set -u
CUTOFF=$(( $(date +%s) - 14 * 86400 ))
IDS="$(hermes kanban --board renovate list --status "done" --json 2>/dev/null | /opt/hermes/.venv/bin/python -c '
import json
import sys

cutoff = int(sys.argv[1])
for task in json.load(sys.stdin):
    if (task.get("completed_at") or cutoff) < cutoff:
        print(task["id"])
' "$CUTOFF")" || { echo "renovate-cleanup: could not list done cards on the renovate board"; exit 0; }
[ -n "$IDS" ] || exit 0
# shellcheck disable=SC2086 # one argument per card ID
hermes kanban --board renovate archive $IDS >/dev/null 2>&1 || echo "renovate-cleanup: archiving failed for: ${IDS//$'\n'/ }"
