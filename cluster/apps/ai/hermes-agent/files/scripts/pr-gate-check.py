#!/usr/bin/env python3
"""Refuses a PR until its gate cards are done and carry the worker's evidence comment.

Hermes' terminal runs in the profile's Coder workspace, which has no kanban board, so this script runs in the Hermes
pod, where `hermes kanban show <id> --json` reads the board. Two modes:

  pr-gate-check.py <card-id>...   Checks the cards, prints one line per card, exits 0 when all pass, 1 otherwise.
  pr-gate-check.py --hook         A pre_tool_call shell hook on the terminal tool (the default profile's overlay in
                                  values.yaml). Reads the hook payload on stdin and prints {} or a block.

In hook mode the command is split into simple commands and each is tokenized like a shell would (quotes removed).
A `gh` invocation whose non-flag words hold `pr` directly followed by `create` opens a PR, whatever global flags come first
(`gh -R owner/repo pr create`) and however the words are quoted (`gh "pr" create`). A PR may be opened only by exactly
one such command, at the top level, whose command word is literally `gh` and whose leading assignment is GATE_CARDS:
`GATE_CARDS=none gh pr create ...` (spec, plan and skill-sync PRs) or `GATE_CARDS="t_1 t_2" gh pr create ...`
(implementation PRs). Refused:
  - GATE_CARDS anywhere else, or more than once;
  - a second PR command;
  - `pr ... create` behind any other command word: a variable (`$g pr create`), an alias, `env`, `xargs`;
  - a PR command inside ( ), $( ), backticks, a quoted string (`bash -c "..."`) or a here-document;
  - other ways to create a PR (gh api ... /pulls with fields or POST, GraphQL createPullRequest, curl ... /pulls);
  - a payload that cannot be read, a call with no command, and a command that cannot be parsed.

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

WORKER = "worker"  # the profile that writes evidence; kanban_comment records the author from the runtime profile
CARD_ID = re.compile(r"^t_[0-9a-f]{4,32}$")
RESULT = re.compile(r"^\s*-\s+(?P<check>.+?):\s+(?P<result>PASS|FAIL|NOT RUN|N/A)\b", re.MULTILINE)
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
HEREDOC = re.compile(r"(?<!<)<<(?!<)(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
OPERATORS = set(";&|()<>")
MAX_DEPTH = 4  # nested quoted strings searched for PR commands
# Commands that read a here-document as data, never as commands: their bodies are not searched (a PR body or a
# patch may quote gh pr create). A body fed to anything else (bash, python, an unknown command) is searched.
DATA_CONSUMERS = {"cat", "tee", "gh", "git", "patch", "base64", "jq", "yq", "sort", "head", "tail", "wc", "grep",
                  "diff", "sha256sum", "true", "echo", "printf"}

# gh flags placed before the subcommand that take a separate value.
GH_VALUE_FLAGS = {"-R", "--repo", "--hostname"}
# Write flags of gh api and curl; a write to .../pulls creates a PR.
WRITE_FLAGS = {"-f", "-F", "--field", "--raw-field", "--input", "-d", "--data", "--data-raw", "--data-binary",
               "--data-urlencode", "--json"}
WRITE_PREFIXES = ("--field=", "--raw-field=", "--input=", "--data=", "--data-raw=", "--data-binary=",
                  "--data-urlencode=", "--json=")
METHOD_FLAGS = {"-X", "--method", "--request"}
PULLS_PATH = re.compile(r"/pulls/?(\?|$)")
# Raw-text check for code the shell tokens cannot show: a string or here-document run by bash, python and the like
# (`['gh', 'pr', 'create']`), or one that cannot be tokenized.
RAW_PR_CREATE = re.compile(r"\bpr\b\W{1,8}create\b")
RAW_OTHER = [
    re.compile(r"createPullRequest"),
    re.compile(r"\bgh\b[^;&|\n]*\bapi\b[^;&|\n]*/pulls\b(?!/)[^;&|\n]*"
               r"(\s-[fF]|\s--(raw-)?field\b|\s--input\b|\s(-X|--method)[\s=]*POST\b)", re.IGNORECASE),
    re.compile(r"\bgh\b[^;&|\n]*\bapi\b[^;&|\n]*(\s-[fF]|\s--(raw-)?field\b|\s--input\b|\s(-X|--method)[\s=]*POST\b)"
               r"[^;&|\n]*/pulls\b(?!/)", re.IGNORECASE),
    re.compile(r"\bcurl\b[^;&|\n]*/pulls\b(?!/)", re.IGNORECASE),
]

HOW_TO = ("Open a PR with exactly one command of this form: `GATE_CARDS=none gh pr create ...` for a spec, plan or "
          "skill-sync PR, or `GATE_CARDS=\"<worker card id> <worker card id>\" gh pr create ...` for an "
          "implementation PR, naming every worker card whose work is in it. Write `gh` literally, at the top level "
          "(not in a variable, alias, subshell, quoted string or here-document). GATE_CARDS must be the leading "
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


# --- command parsing ------------------------------------------------------------------------------

def heredoc_consumer(line, start):
    """The command word that reads the here-document starting at line[start:] (rough: the first non-assignment word
    after the last ; & | ( before it)."""
    prefix = re.split(r"[;&|(]", line[:start])[-1].split()
    _, words = split_assignments(prefix)
    return os.path.basename(words[0].strip("'\"")) if words else ""


def split_heredocs(command):
    """Returns (command without here-document bodies, bodies that a command may run). A body read by a command in
    DATA_CONSUMERS is data and left out."""
    out, bodies, pending, body = [], [], [], []
    for line in command.split("\n"):
        if pending:
            strip_tabs, delimiter, consumer = pending[0]
            if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                pending.pop(0)
                if consumer not in DATA_CONSUMERS:
                    bodies.append("\n".join(body))
                body = []
            else:
                body.append(line)
            continue
        out.append(line)
        pending += [(m.group(1) == "-", m.group(3), heredoc_consumer(line, m.start())) for m in HEREDOC.finditer(line)]
    if body and pending and pending[0][2] not in DATA_CONSUMERS:
        bodies.append("\n".join(body))  # an unterminated here-document still runs to the end
    return "\n".join(out), bodies


def segments(command):
    """Splits a command line into simple commands at ; & | ( ) < > and newlines, as (words, in_subshell) pairs; a
    command inside ( ) or $( ) is in a subshell. Raises ValueError on bad quoting."""
    lexer = shlex.shlex(command.replace("\n", " ; "), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""  # a '#' stays in the words, so `gh pr create # GATE_CARDS=none` is still seen
    result, current, level, start_level = [], [], 0, 0
    for token in lexer:
        if token and set(token) <= OPERATORS:
            result.append((current, start_level > 0))
            level += token.count("(") - token.count(")")
            current, start_level = [], level
        else:
            current.append(token)
    result.append((current, start_level > 0))
    return [(words, sub) for words, sub in result if words]


def split_assignments(words):
    i = 0
    while i < len(words) and ASSIGNMENT.match(words[i]):
        i += 1
    return words[:i], words[i:]


def pr_then_create(words):
    return any(a == "pr" and b == "create" for a, b in zip(words, words[1:]))


def is_gh(word):
    return word == "gh" or word.endswith("/gh")


def gh_creates_pr(words):
    """words start at a command word (gh). True when its non-flag words hold pr directly followed by create."""
    non_flags, skip = [], False
    for word in words[1:]:
        if skip:
            skip = False
        elif word in GH_VALUE_FLAGS:
            skip = True
        elif not word.startswith("-"):
            non_flags.append(word)
    return pr_then_create(non_flags)


def writes_to_pulls(words):
    if not any(PULLS_PATH.search(w) for w in words):
        return False
    for i, word in enumerate(words):
        if word in WRITE_FLAGS or word.startswith(WRITE_PREFIXES):
            return True
        if word in METHOD_FLAGS and i + 1 < len(words) and words[i + 1].upper() == "POST":
            return True
        if word.upper() in ("-XPOST", "--METHOD=POST", "--REQUEST=POST"):
            return True
    return False


def classify(segment):
    """Returns None, 'gated' (a plain gh ... pr create), 'indirect' or 'other-pr'."""
    _, words = split_assignments(segment)
    if not words:
        return None
    if writes_to_pulls(words):
        return "other-pr"
    if is_gh(words[0]):
        return "gated" if gh_creates_pr(words) else None
    gh_at = next((i for i, w in enumerate(words) if is_gh(w)), None)
    if gh_at is not None and gh_creates_pr(words[gh_at:]):
        return "indirect"  # env gh ..., xargs gh ..., sudo gh ...
    if gh_creates_pr(words) and ("$" in words[0] or "`" in words[0] or gh_at is None):
        return "indirect"  # $g pr create, an alias, $(...) pr create
    return None


def find_pr_commands(command, depth=0):
    """Returns a list of (kind, segment, top_level). Raises ValueError when the top level cannot be parsed."""
    text, bodies = split_heredocs(command)
    found = []
    for segment, in_subshell in segments(text):
        kind = classify(segment)
        if kind:
            found.append((kind, segment, depth == 0 and not in_subshell))
        # A quoted argument of gh or a data reader is text (a title, a search); anything else may run it as code.
        _, words = split_assignments(segment)
        as_code = bool(words) and not (is_gh(words[0]) or os.path.basename(words[0]) in DATA_CONSUMERS)
        for word in segment:
            # Text is searched only for a command substitution, which bash runs even inside double quotes.
            if (as_code and any(c in word for c in " \t\n;&|`$(),'\"")) or "$(" in word or "`" in word:
                found += nested_pr_commands(word, depth + 1, as_code)
    for body in bodies:
        found += nested_pr_commands(body, depth + 1, True)
    return found


def nested_pr_commands(text, depth, as_code):
    """PR commands inside a quoted string or here-document body, all marked as not top level. Text that may run as
    code, or cannot be tokenized, is also searched as raw text."""
    raw = [("indirect", [text], False)] if RAW_PR_CREATE.search(text) else []
    if depth > MAX_DEPTH:
        return raw
    try:
        nested = [(k, s, False) for k, s, _ in find_pr_commands(text, depth)]
    except ValueError:
        return raw
    return nested + (raw if as_code else [])


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

    if any(p.search(command) for p in RAW_OTHER):
        return block("this command creates a PR without gh pr create (gh api, GraphQL createPullRequest or curl).")
    try:
        found = find_pr_commands(command)
    except ValueError as exc:
        return block(f"the command could not be parsed ({exc}).")
    if any(kind == "other-pr" for kind, _, _ in found):
        return block("this command creates a PR without gh pr create (a write to .../pulls).")
    if any(kind == "indirect" or not top for kind, _, top in found):
        return block("gh pr create must be a plain command whose first word is gh: not behind a variable, alias, "
                     "env, xargs or $( ), and not inside a quoted string or here-document.")
    if len(found) > 1:
        return block("the command holds more than one PR command.")
    if not found:
        print("{}")
        return 0
    if command.count("GATE_CARDS") != 1:
        return block(f"GATE_CARDS appears {command.count('GATE_CARDS')} times; it must appear exactly once, "
                     "as the leading assignment of gh pr create.")
    gate = [a for a in split_assignments(found[0][1])[0] if a.startswith("GATE_CARDS=")]
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
