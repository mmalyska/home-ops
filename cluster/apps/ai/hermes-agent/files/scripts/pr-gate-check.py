#!/usr/bin/env python3
"""Refuses a PR until its gate cards are done and carry the worker's evidence comment.

Hermes' terminal runs in the profile's Coder workspace, which has no kanban board, so this script runs in the Hermes
pod, where `hermes kanban show <id> --json` reads the board. Two modes:

  pr-gate-check.py <card-id>...   Checks the cards, prints one line per card, exits 0 when all pass, 1 otherwise.
  pr-gate-check.py --hook         A pre_tool_call shell hook on the terminal tool (the default profile's overlay in
                                  values.yaml). Reads the hook payload on stdin and prints {} or a block.

In hook mode a PR may be opened only by exactly one plain `gh pr create` command whose leading assignment is
GATE_CARDS: `GATE_CARDS=none gh pr create ...` (spec, plan and skill-sync PRs) or `GATE_CARDS="t_1 t_2" gh pr create
...` (implementation PRs). GATE_CARDS anywhere else, a second PR command, `gh pr create` inside a subshell, quote or
comment, and any other way to create a PR (gh api, GraphQL createPullRequest, curl) are blocked. So is a payload that
cannot be read or has no command: the hook fails closed.

A card passes when its status is `done` and its latest evidence comment (first line exactly `EVIDENCE`) was written by
the worker profile and holds at least one `- <check>: PASS` line and no `- <check>: FAIL` line. The format is in the
implement-task skill. HERMES_BIN overrides the hermes command (the tests point it at fixtures).
"""
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

WORKER = "worker"  # the profile that writes evidence; kanban records the author from the runtime profile
CARD_ID = re.compile(r"^t_[0-9a-f]{4,32}$")
RESULT = re.compile(r"^\s*-\s+(?P<check>.+?):\s+(?P<result>PASS|FAIL|NOT RUN|N/A)\b", re.MULTILINE)
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
OPERATORS = set(";&|()<>")

PR_CREATE = re.compile(r"\bgh\s+pr\s+create\b")
# Other ways to create a PR. They are always refused: a PR is opened only with gh pr create.
OTHER_PR_CREATE = [
    re.compile(r"createPullRequest"),
    re.compile(r"\bgh\s+api\b[^;&|\n]*/pulls\b(?!/)[^;&|\n]*"
               r"(\s-[fF]|\s--(raw-)?field\b|\s--input\b|\s(-X|--method)[\s=]*POST\b)", re.IGNORECASE),
    re.compile(r"\bgh\s+api\b[^;&|\n]*(\s-[fF]|\s--(raw-)?field\b|\s--input\b|\s(-X|--method)[\s=]*POST\b)"
               r"[^;&|\n]*/pulls\b(?!/)", re.IGNORECASE),
    re.compile(r"\bcurl\b[^;&|\n]*/pulls\b(?!/)", re.IGNORECASE),
]

HOW_TO = ("Open a PR with exactly one command of this form: `GATE_CARDS=none gh pr create ...` for a spec, plan or "
          "skill-sync PR, or `GATE_CARDS=\"<worker card id> <worker card id>\" gh pr create ...` for an "
          "implementation PR, naming every worker card whose work is in it. GATE_CARDS must be the leading "
          "assignment of that gh pr create and appear nowhere else (no comment, no other command, not in the PR "
          "text). Write the PR body to a file in an earlier command and pass --body-file. Each card must be done, "
          "with its latest EVIDENCE comment written by the worker. If a card fails, do not retry with other cards "
          "or with GATE_CARDS=none: get the evidence from the worker or ask the owner.")


def hermes_bin():
    if os.environ.get("HERMES_BIN"):
        return os.environ["HERMES_BIN"]
    if os.access("/opt/hermes/bin/hermes", os.X_OK):
        return "/opt/hermes/bin/hermes"
    return shutil.which("hermes") or "hermes"


def latest_evidence(comments):
    for comment in reversed(comments):
        if not isinstance(comment, dict):
            continue
        lines = str(comment.get("body") or "").strip().splitlines()
        if lines and lines[0].strip() == "EVIDENCE":
            return comment
    return None


def check_card(card_id):
    """Returns (ok, one-line reason)."""
    if not CARD_ID.match(card_id):
        return False, f"{card_id}: not a kanban card id (expected t_<hex>)"
    try:
        shown = subprocess.run([hermes_bin(), "kanban", "show", card_id, "--json"],
                               capture_output=True, text=True, timeout=45)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"{card_id}: could not read the card ({exc})"
    if shown.returncode != 0:
        detail = (shown.stderr or shown.stdout).strip().splitlines()
        return False, f"{card_id}: could not read the card (exit {shown.returncode}: {detail[-1][:200] if detail else 'no output'})"
    try:
        data = json.loads(shown.stdout)
    except ValueError:
        return False, f"{card_id}: kanban show printed no JSON"
    if not isinstance(data, dict) or not isinstance(data.get("task"), dict):
        return False, f"{card_id}: kanban show printed no task"
    task = data["task"]
    title = task.get("title") or "?"
    status = task.get("status") or "?"
    if status != "done":
        return False, f"{card_id} ({title}): status is {status}, not done"
    comments = data.get("comments") if isinstance(data.get("comments"), list) else []
    evidence = latest_evidence(comments)
    if evidence is None:
        return False, f"{card_id} ({title}): no evidence comment (a comment whose first line is EVIDENCE)"
    if evidence.get("author") != WORKER:
        return False, (f"{card_id} ({title}): the latest evidence comment is by {evidence.get('author') or '?'}, "
                       f"not the {WORKER} profile")
    results = RESULT.findall(str(evidence.get("body")))
    failed = [check for check, result in results if result == "FAIL"]
    if failed:
        return False, f"{card_id} ({title}): evidence reports FAIL for {', '.join(failed)}"
    if not any(result == "PASS" for _, result in results):
        return False, f"{card_id} ({title}): evidence comment has no '- <check>: PASS' line"
    return True, f"{card_id} ({title}): done, evidence by {WORKER}"


def check_cards(card_ids):
    lines, ok = [], True
    for card_id in card_ids:
        passed, reason = check_card(card_id)
        ok = ok and passed
        lines.append(("PASS " if passed else "FAIL ") + reason)
    return ok, lines


def strip_heredocs(command):
    """Drops here-document bodies (PR text), which are data and may hold unbalanced quotes."""
    out, pending = [], []
    for line in command.split("\n"):
        if pending:
            strip_tabs, delimiter = pending[0]
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                pending.pop(0)
            continue
        out.append(line)
        pending += [(m.group(1) == "-", m.group(3)) for m in HEREDOC.finditer(line)]
    return "\n".join(out)


def segments(command):
    """Splits a command line into simple commands at ; & | ( ) < > and newlines. Raises ValueError on bad quoting."""
    lexer = shlex.shlex(strip_heredocs(command).replace("\n", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""  # a '#' stays in the words, so `gh pr create # GATE_CARDS=none` is still seen
    result, current = [], []
    for token in lexer:
        if token and set(token) <= OPERATORS:
            result.append(current)
            current = []
        else:
            current.append(token)
    result.append(current)
    return [s for s in result if s]


def split_assignments(words):
    i = 0
    while i < len(words) and ASSIGNMENT.match(words[i]):
        i += 1
    return words[:i], words[i:]


def block(reason):
    print(json.dumps({"action": "block", "message": f"PR refused by pr-gate-check: {reason}\n{HOW_TO}"}))
    return 0


def hook(raw_payload):
    try:
        payload = json.loads(raw_payload)
    except ValueError:
        return block("the hook payload could not be read, so the command is refused.")
    tool_input = payload.get("tool_input") if isinstance(payload, dict) else None
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return block("the terminal call has no command, so it is refused.")

    if any(p.search(command) for p in OTHER_PR_CREATE):
        return block("this command creates a PR without gh pr create (gh api, GraphQL createPullRequest or curl).")
    count = len(PR_CREATE.findall(command))
    if count == 0:
        print("{}")
        return 0
    if count > 1:
        return block("the command contains gh pr create more than once (a second PR, or the words in the PR text).")
    try:
        parsed = segments(command)
    except ValueError as exc:
        return block(f"the command could not be parsed ({exc}).")
    pr_segments = [s for s in parsed if split_assignments(s)[1][:3] == ["gh", "pr", "create"]]
    if len(pr_segments) != 1:
        return block("gh pr create must be a plain command, not inside a subshell, quote, backticks or comment.")
    if command.count("GATE_CARDS") != 1:
        return block(f"GATE_CARDS appears {command.count('GATE_CARDS')} times; it must appear exactly once, "
                     "as the leading assignment of gh pr create.")
    gate = [a for a in split_assignments(pr_segments[0])[0] if a.startswith("GATE_CARDS=")]
    if not gate:
        return block("GATE_CARDS is not the leading assignment of gh pr create.")
    card_ids = [c for c in re.split(r"[\s,]+", gate[0][len("GATE_CARDS="):].strip()) if c]
    if card_ids == ["none"]:
        print("{}")
        return 0
    if not card_ids:
        return block("GATE_CARDS is empty.")
    if "none" in card_ids:
        return block("GATE_CARDS mixes none with card ids.")
    ok, lines = check_cards(card_ids)
    if ok:
        print("{}")
        return 0
    return block("a gate card does not pass:\n" + "\n".join(lines))


def main(argv):
    if argv[1:] == ["--hook"]:
        try:
            return hook(sys.stdin.read())
        except Exception as exc:  # fail closed with a readable reason instead of a stack trace
            return block(f"the gate check failed ({type(exc).__name__}: {exc}).")
    if len(argv) < 2 or argv[1].startswith("-"):
        print("usage: pr-gate-check.py <card-id>... | --hook", file=sys.stderr)
        return 2
    ok, lines = check_cards(argv[1:])
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
