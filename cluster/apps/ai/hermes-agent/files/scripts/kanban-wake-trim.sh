#!/bin/bash
# Makes kanban notices wake `default` only for cards that need it. Run by the script-only cron job kanban-wake-trim
# every minute, with no model. Its stdout is posted to #hermes, so a run with nothing new to report prints nothing.
#
# A card created from a Discord chat subscribes that chat with delivery mode notify+wake, and a card created with
# parents copies their subscriptions, mode included (Hermes v0.23.1; the wake kinds cannot be configured). Each wake
# is a full `default` turn. The wanted mode of a subscription is:
#   - notify+wake on a worker card whose skills include implement-task: its completion has a next step (spec-author
#     opens the PR) and its block, give-up, crash or timeout needs an answer. Such a card whose parent is a human card
#     inherits notify, so it is promoted here.
#   - notify (the short notice only, no turn) on every other card.
# Mode `wake` and TUI subscriptions are left alone. Each subscription is checked once: its key is kept in the state
# file, so a card is read with `kanban show` (read-only) only for a new subscription. `kanban list` is not used: it
# writes to the board (recompute_ready). A card that finishes within a minute of its creation can still wake once.
#
# Failures: a failed step is retried on the next run and recorded in the state file under a `fail` key with its
# first-seen time and run count. It is printed (and so posted) on its first failure, once an hour while it keeps
# failing, and once when it recovers. A missing or unreadable state file is treated as empty, with one line saying so.
# The script always exits 0.
#
# Test: bash cluster/apps/ai/hermes-agent/tests/kanban-wake-trim.test.sh (fake `hermes` CLI, fake clock).
set -u
PY=${KANBAN_WAKE_TRIM_PYTHON:-/opt/hermes/.venv/bin/python}
export KANBAN_WAKE_TRIM_STATE=${KANBAN_WAKE_TRIM_STATE:-/opt/data/cron/kanban-wake-trim.txt}
"$PY" - <<'EOF' || echo "kanban-wake-trim: the script itself failed (exit $?)"
import json
import os
import subprocess
import time

STATE = os.environ["KANBAN_WAKE_TRIM_STATE"]
NOW = int(os.environ.get("KANBAN_WAKE_TRIM_NOW") or time.time())
REPEAT = 3600  # seconds between two "still failing" lines for one key
out = []


def say(text):
    out.append("kanban-wake-trim: " + text)


def stamp(epoch):
    return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(epoch))


# State file, one tab-separated line per entry:
#   <board> <task> <platform> <chat> <thread>       a checked subscription (thread empty for none)
#   fail <key> <first seen> <runs> <last reported>   a failing step; key is <board>:<step> or <board>:<task>:<step>
seen, fails = set(), {}
try:
    with open(STATE) as handle:
        for line in handle.read().splitlines():
            if not line.strip():
                continue
            parts = line.split("\t")
            if parts[0] == "fail" and len(parts) == 5:
                fails[parts[1]] = [int(parts[2]), int(parts[3]), int(parts[4])]
            elif parts[0] != "fail" and len(parts) == 5 and all(parts[:4]):
                seen.add(tuple(parts))
            else:
                raise ValueError(line)
except FileNotFoundError:
    seen, fails = set(), {}
    say(f"state file {STATE} was missing; starting with an empty state")
except (OSError, ValueError, UnicodeDecodeError):
    seen, fails = set(), {}
    say(f"state file {STATE} could not be read; starting with an empty state")

failing, attempted = {}, set()


def step(key, message, *args):
    """Run `hermes kanban <args>`; return (ok, parsed JSON stdout or None). A failure is recorded under key."""
    attempted.add(key)
    try:
        done = subprocess.run(["hermes", "kanban", *args], capture_output=True, text=True, timeout=60)
        if done.returncode != 0:
            raise RuntimeError(done.returncode)
        return True, (json.loads(done.stdout) if "--json" in args else None)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        failing[key] = message
        return False, None


new_seen = set()
listed = set()  # boards whose subscriptions were read in this run
ok, boards = step("boards:list", "could not list the kanban boards", "boards", "list", "--json")
if not ok:
    new_seen = set(seen)
for slug in [board["slug"] for board in boards] if ok else []:
    ok, subs = step(f"{slug}:notify-list", f"could not list subscriptions on board {slug}",
                    "--board", slug, "notify-list", "--json")
    if not ok:
        new_seen |= {key for key in seen if key[0] == slug}
        continue
    listed.add(slug)
    for sub in subs:
        task, platform, chat = sub["task_id"], sub["platform"], sub["chat_id"]
        key = (slug, task, platform, chat, sub.get("thread_id") or "")
        mode = sub.get("delivery_mode") or "notify"
        if key in seen or mode == "wake" or platform == "tui":
            new_seen.add(key)
            continue
        ok, shown = step(f"{slug}:{task}:show", f"could not read card {slug}/{task}",
                         "--board", slug, "show", task, "--json")
        if not ok:
            continue
        card = shown["task"]
        want = ("notify+wake" if card.get("assignee") == "worker"
                and "implement-task" in (card.get("skills") or []) else "notify")
        if want != mode:
            args = ["--board", slug, "notify-subscribe", task, "--platform", platform, "--chat-id", chat,
                    "--delivery-mode", want]
            if key[4]:
                args += ["--thread-id", key[4]]
            ok, _ = step(f"{slug}:{task}:notify-subscribe", f"could not set {slug}/{task} to {want}", *args)
            if not ok:
                continue
        new_seen.add(key)

new_fails = {}
for key, message in failing.items():
    if key not in fails:
        new_fails[key] = [NOW, 1, NOW]
        say(message)
        continue
    first, runs, reported = fails[key]
    runs += 1
    if NOW - reported >= REPEAT:
        say(f"{message}: still failing since {stamp(first)}, {runs} runs")
        reported = NOW
    new_fails[key] = [first, runs, reported]
checked_cards = {(key[0], key[1]) for key in new_seen}
for key, (first, runs, reported) in fails.items():
    if key in failing:
        continue
    parts = key.split(":")
    if key in attempted or (len(parts) == 3 and tuple(parts[:2]) in checked_cards):
        say(f"{key} recovered after {runs} failed runs")
    elif parts[0] not in listed:
        new_fails[key] = [first, runs, reported]  # not retried: its board could not be read in this run
    # Otherwise the card's subscription is gone: the key is dropped without a line.

lines = ["\t".join(key) for key in sorted(new_seen)]
lines += ["\t".join(["fail", key, *map(str, value)]) for key, value in sorted(new_fails.items())]
try:
    with open(STATE + ".tmp", "w") as handle:
        handle.write("".join(line + "\n" for line in lines))
    os.replace(STATE + ".tmp", STATE)
except OSError as error:
    say(f"could not write the state file {STATE}: {error}")
if out:
    print("\n".join(out))
EOF
exit 0
