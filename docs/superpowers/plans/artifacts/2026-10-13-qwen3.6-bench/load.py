#!/usr/bin/env python3
"""Concurrent near-slot-ceiling load: ROUNDS rounds of 2 simultaneous requests,
each ~TARGET_WORDS random words (default tuned to ~45K tokens). Prints the real
prompt_tokens so the size is measured, not assumed. stdlib only.
  BASE=http://127.0.0.1:8080/v1 python3 -I load.py
"""
import json, os, random, string, threading, time, urllib.request

BASE = os.environ.get("BASE", "http://127.0.0.1:8080/v1")
MODEL = os.environ.get("MODEL", "lfm2.5-8b-a1b")
ROUNDS = int(os.environ.get("ROUNDS", "5"))
TARGET_WORDS = int(os.environ.get("TARGET_WORDS", "15000"))


def one(idx, out):
    rnd = random.Random(time.time_ns() + idx)
    text = " ".join("".join(rnd.choices(string.ascii_lowercase, k=rnd.randint(3, 8)))
                    for _ in range(TARGET_WORDS))
    body = {"model": MODEL, "max_tokens": 128, "temperature": 0.7,
            "messages": [{"role": "user",
                          "content": text + "\n\nSummarise the above in one sentence."}]}
    req = urllib.request.Request(BASE + "/chat/completions",
                                 json.dumps(body).encode(),
                                 {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=3600) as r:
        d = json.load(r)
    out[idx] = (d["usage"]["prompt_tokens"], d["usage"]["completion_tokens"],
                time.time() - t0)


for r in range(ROUNDS):
    out = {}
    ts = [threading.Thread(target=one, args=(i, out)) for i in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    print(f"round {r + 1}/{ROUNDS}:", out, flush=True)
