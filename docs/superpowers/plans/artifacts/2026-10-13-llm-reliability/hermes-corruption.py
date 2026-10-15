#!/usr/bin/env python3
"""Multi-turn, tool-calling corruption test driven through real Hermes.

Replaces hermes-corruption.sh (single-turn, text-scraping, no tool calls: it
could not exercise the llama.cpp#29002 failure, which needs multi-turn context
and checkpoint restore). Each profile runs conversations of five turns: the
first starts a session, the rest `--resume` it, and three of the five require a
`todo` tool call. Output is parsed from `--format stream-json`.

  hermes-corruption.py <rounds-per-profile> <profile> [<profile> ...]
  hermes-corruption.py --selftest

Total turns = profiles x rounds x 5 (4 profiles x 5 rounds = 100).

Env: OUT (/tmp/hermes-corruption), NS (hermes-agent),
     TURN_TIMEOUT (600 s per turn, enforced with `timeout -s KILL` in the pod),
     TOOLSETS (todo; local-only. NOT file/terminal: those route over SSH to a
     remote host in this cluster's Hermes config).
A turn is CORRUPT when the final reply leaks reasoning markers, is empty, is
cut off mid-sentence, or hermes exits non-zero / emits no result. Tool errors
(is_error on a tool_result) are counted separately and are not corruption.
"""
import json, os, re, statistics, subprocess, sys, threading, time

NS = os.environ.get("NS", "hermes-agent")
OUT = os.environ.get("OUT", "/tmp/hermes-corruption")
TOOLSETS = os.environ.get("TOOLSETS", "todo")
# One turn queues behind up to len(profiles)-1 others on a single slot (worst
# case seen ~300 s). A hit is reported, not fatal, and the process is killed
# INSIDE the pod: killing only the local kubectl exec leaves the remote hermes
# alive, still holding its connection to llama-server (2026-10-15 incident).
TURN_TIMEOUT = int(os.environ.get("TURN_TIMEOUT", "600"))

# (prompt, must_call_tool)
SCRIPTS = [
    [("Create a todo list with three items for upgrading a Kubernetes node: drain, upgrade, uncordon. Use the todo tool.", True),
     ("Mark the first item done using the todo tool, then tell me in one sentence what remains.", True),
     ("Explain in two sentences why draining must happen before the upgrade.", False),
     ("Add a fourth item 'verify Ceph health' with the todo tool and read the whole list back to me.", True),
     ("Summarise the whole plan so far in two sentences.", False)],
    [("Create a todo list with three items for restoring a CloudNativePG cluster from backup: stop writers, restore, verify. Use the todo tool.", True),
     ("Mark the first item done using the todo tool, then tell me in one sentence what remains.", True),
     ("Explain in two sentences why you verify before reopening writes.", False),
     ("Add a fourth item 'rotate credentials' with the todo tool and read the whole list back to me.", True),
     ("Summarise the whole plan so far in two sentences.", False)],
    [("Create a todo list with three items for renewing a TLS certificate: check expiry, renew, reload. Use the todo tool.", True),
     ("Mark the first item done using the todo tool, then tell me in one sentence what remains.", True),
     ("Explain in two sentences why you check expiry first.", False),
     ("Add a fourth item 'update monitoring' with the todo tool and read the whole list back to me.", True),
     ("Summarise the whole plan so far in two sentences.", False)],
    [("Create a todo list with three items for debugging a CrashLoopBackOff pod: read logs, check events, fix config. Use the todo tool.", True),
     ("Mark the first item done using the todo tool, then tell me in one sentence what remains.", True),
     ("Explain in two sentences why events help beyond logs.", False),
     ("Add a fourth item 'add a readiness probe' with the todo tool and read the whole list back to me.", True),
     ("Summarise the whole plan so far in two sentences.", False)],
]

MARKERS = re.compile(r"</?think>|<\|channel\|>|<\|im_start\|>|<\|im_end\|>|<\|tool_call")
SENTENCE_END = re.compile(r"[.!?]")
WORD = re.compile(r"[A-Za-z]{3,}")
LIST_ITEM = re.compile(r"^\s*(?:[-*\u2022]|\d+[.)])\s+\S")


def looks_truncated(body):
    """A reply is cut off when real words trail the last sentence end.

    The Hermes persona ends replies with emoticons and symbols (for example
    '! \u266a ~ \u30fd(>\u2200<\u2606)\u30ce'), so 'does not end in punctuation' is wrong.
    Instead take what follows the last . ! ? and flag it only if it still holds
    a word (3+ ASCII letters). A reply whose last line is a list item or a code
    fence is a complete shape and is not flagged (known blind spot: a reply cut
    inside a list item).
    """
    last = body.rstrip().splitlines()[-1] if body.strip() else ""
    if LIST_ITEM.match(last) or last.strip().startswith("```"):
        return False
    ends = list(SENTENCE_END.finditer(body))
    tail = body[ends[-1].end():] if ends else body
    return bool(WORD.search(tail))


def parse(stdout):
    events = []
    for line in stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                events.append(json.loads(line))
            except ValueError:
                pass
    return events


def classify(rc, stdout, must_tool):
    """Return (why_or_None, info). Pure function; used by --selftest."""
    ev = parse(stdout)
    result = next((e for e in reversed(ev) if e.get("type") == "result"), None)
    tool_uses = [e for e in ev if e.get("type") == "tool_use"]
    tool_errors = [e for e in ev if e.get("type") == "tool_result" and e.get("is_error")]
    streamed = "".join(e.get("text", "") for e in ev if e.get("type") == "text")
    info = {"tool_uses": len(tool_uses), "tool_errors": len(tool_errors),
            "session_id": (result or {}).get("session_id")
            or next((e.get("session_id") for e in ev if e.get("session_id")), None),
            "must_tool": must_tool}
    if rc in (124, 137):
        return "turn timeout (killed in pod after %ss)" % TURN_TIMEOUT, info
    if rc != 0:
        return "process exit %s" % rc, info
    if result is None:
        return "no result event", info
    if result.get("exit_code", 0) != 0:
        return "hermes exit_code %s" % result.get("exit_code"), info
    text = (result.get("text") or "")
    if MARKERS.search(text) or MARKERS.search(streamed):
        return "reasoning/control marker leaked", info
    body = text.strip()
    if not re.sub(r"[\W_]+", "", body):
        return "empty reply", info
    if looks_truncated(body):
        return "truncated: " + repr(body[-70:]), info
    return None, info


def hermes(profile, prompt, session):
    cmd = ["kubectl", "-n", NS, "exec", "deploy/hermes-agent", "-c", "hermes-agent", "--",
           "timeout", "-s", "KILL", str(TURN_TIMEOUT),
           "hermes", "-p", profile, "chat", "-Q", "--format", "stream-json", "--max-turns", "6"]
    if TOOLSETS:
        cmd += ["-t", TOOLSETS]
    if session:
        cmd += ["--resume", session]
    cmd += ["-q", prompt]
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TURN_TIMEOUT + 60)
    except subprocess.TimeoutExpired:
        # Counted as a failed turn (rc 124), never an unhandled thread crash.
        return 124, "", time.time() - t0
    return p.returncode, p.stdout, time.time() - t0


def run_profile(profile, rounds, rows, lock):
    for r in range(rounds):
        script = SCRIPTS[(len(profile) + r) % len(SCRIPTS)]
        session = None
        for t, (prompt, must_tool) in enumerate(script, 1):
            rc, out, secs = hermes(profile, prompt, session)
            why, info = classify(rc, out, must_tool)
            session = info["session_id"] or session
            tag = "%s-r%d-t%d" % (profile, r + 1, t)
            with open(os.path.join(OUT, tag + ".jsonl"), "w") as fh:
                fh.write(out)
            row = {"tag": tag, "why": why, "secs": secs, **info}
            with lock:
                rows.append(row)
            print(("CORRUPT " + tag + " - " + why) if why else "ok      " + tag
                  + " tools=%d %.0fs" % (info["tool_uses"], secs), flush=True)
            if not session:
                print("WARN no session id for %s; remaining turns restart the session" % tag, flush=True)


def summarize(rows):
    total = len(rows)
    bad = sum(1 for r in rows if r["why"])
    print("CORRUPTION %d/%d = %.1f%%" % (bad, total, 100.0 * bad / max(total, 1)))
    asked = [r for r in rows if r["must_tool"]]
    used = [r for r in asked if r["tool_uses"] > 0]
    print("TOOLCALLS asked=%d used=%d tool_events=%d tool_errors=%d"
          % (len(asked), len(used), sum(r["tool_uses"] for r in rows),
             sum(r["tool_errors"] for r in rows)))
    secs = sorted(r["secs"] for r in rows)
    if secs:
        print("LATENCY p50=%.0fs p95=%.0fs max=%.0fs n=%d"
              % (statistics.median(secs), secs[min(len(secs) - 1, int(len(secs) * 0.95))], secs[-1], len(secs)))


def selftest():
    def ev(*es):
        return "\n".join(json.dumps(e) for e in es)
    init = {"type": "system", "subtype": "init", "session_id": "S1"}
    ok = ev(init, {"type": "tool_use", "name": "todo", "input": {}},
            {"type": "tool_result", "name": "todo", "output": "{}", "is_error": False},
            {"type": "result", "session_id": "S1", "exit_code": 0,
             "text": "Done, the list has three items. ★"})
    cases = [
        ("clean with tool", 0, ok, True, None),
        ("tool error is not corruption", 0, ev(init, {"type": "tool_use", "name": "x"},
            {"type": "tool_result", "is_error": True},
            {"type": "result", "session_id": "S1", "exit_code": 0, "text": "Could not read it. ★"}), True, None),
        ("persona emoticon tail", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0,
            "text": "Everything is ready for you! \u266a ~ \u30fd(>\u2200<\u2606)\u30ce"}), False, None),
        ("emoticon after sentence", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0,
            "text": "You still need to renew the TLS certificate and reload the service! (\u25d5\u203f\u25d5) \u266a"}), False, None),
        ("ends in list item", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0,
            "text": "Plan:\n- [x] check expiry\n- [ ] update monitoring (tls-4)"}), False, None),
        ("cut after earlier sentence", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0,
            "text": "Drain first. Then upgrade the"}), False, "truncated"),
        ("leak", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0,
                              "text": "<think>hmm</think> Answer."}), False, "leaked"),
        ("truncated", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0,
                                   "text": "The plan is to drain the node and then"}), False, "truncated"),
        ("empty", 0, ev(init, {"type": "result", "session_id": "S1", "exit_code": 0, "text": " ★"}), False, "empty"),
        ("no result", 0, ev(init), False, "no result"),
        ("nonzero", 1, "", False, "process exit"),
        ("killed by in-pod timeout", 137, "", False, "turn timeout"),
        ("timeout exit 124", 124, "", False, "turn timeout"),
    ]
    failed = 0
    for name, rc, out, mt, expect in cases:
        why, info = classify(rc, out, mt)
        good = (why is None) if expect is None else (why is not None and expect in why)
        print("%-30s %s  (%s)" % (name, "PASS" if good else "FAIL", why))
        failed += 0 if good else 1
    sid_ok = classify(0, ok, True)[1]["session_id"] == "S1"
    print("%-30s %s" % ("session id parsed", "PASS" if sid_ok else "FAIL"))
    failed += 0 if sid_ok else 1
    sys.exit(1 if failed else 0)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--selftest":
        selftest()
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rounds = int(sys.argv[1])
    profiles = sys.argv[2:]
    os.makedirs(OUT, exist_ok=True)
    rows, lock = [], threading.Lock()
    ts = [threading.Thread(target=run_profile, args=(p, rounds, rows, lock)) for p in profiles]
    [t.start() for t in ts]
    [t.join() for t in ts]
    summarize(rows)


if __name__ == "__main__":
    main()
