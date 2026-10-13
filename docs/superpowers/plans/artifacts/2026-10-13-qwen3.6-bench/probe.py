#!/usr/bin/env python3
"""Quality probes and the multi-turn corruption test against llama-server.

stdlib only. Run from the devcontainer through a port-forward:
  BASE=http://127.0.0.1:8080/v1 python3 -I probe.py quality
  BASE=http://127.0.0.1:8080/v1 python3 -I probe.py corruption 100
"""
import json, os, random, re, sys, threading, urllib.request

BASE = os.environ.get("BASE", "http://127.0.0.1:8080/v1")
MODEL = os.environ.get("MODEL", "lfm2.5-8b-a1b")
THINK = os.environ.get("THINK")  # "1" -> chat_template_kwargs.enable_thinking=true


def chat(messages, **kw):
    body = {"model": MODEL, "messages": messages, "temperature": 0.7, **kw}
    if THINK == "1":
        body["chat_template_kwargs"] = {"enable_thinking": True}
    req = urllib.request.Request(
        BASE + "/chat/completions", json.dumps(body).encode(),
        {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=1800) as r:
        d = json.load(r)
    c = d["choices"][0]
    return c["message"].get("content") or "", c["finish_reason"], c["message"], d


def looks_corrupt(text, finish):
    """Same failure shape as llama.cpp#29002: reasoning leaks into content or
    the reply is cut off mid-sentence."""
    if re.search(r"</?think>|<\|im_start\|>|<\|channel\|>", text):
        return True
    if finish == "length":
        return True
    t = text.strip()
    return len(t) == 0 or t[-1] not in ".!?)`\"'*]}>0123456789"


KNOWN = [
    ("What is 17 * 23? Reply with only the number.", "391"),
    ("What is the capital of Poland? One word.", "warsaw"),
    ("Spell 'kubernetes' backwards. Only the result.", "setenrebuk"),
    ("How many days are in a leap year? Only the number.", "366"),
    ("Chemical symbol for gold? Only the symbol.", "au"),
]


def quality():
    ok = fail = 0
    for q, a in KNOWN:
        text, fin, _, _ = chat([{"role": "user", "content": q}], max_tokens=512)
        hit = a in text.lower()
        ok, fail = ok + hit, fail + (not hit)
        print(("PASS" if hit else "FAIL"), "known", repr(q[:40]), "->", repr(text[:60]))
    for i in range(5):
        text, fin, _, _ = chat([{"role": "user", "content":
            f"Extract as JSON with keys name and age, no prose: 'Anna is {20+i} years old.'"}],
            max_tokens=256)
        m = re.search(r"\{.*\}", text, re.S)
        try:
            j = json.loads(m.group(0))
            hit = j.get("age") == 20 + i
        except Exception:
            hit = False
        ok, fail = ok + hit, fail + (not hit)
        print(("PASS" if hit else "FAIL"), "json", i, repr(text[:60]))
    tools = [{"type": "function", "function": {
        "name": "get_weather", "description": "Weather for a city",
        "parameters": {"type": "object",
                       "properties": {"city": {"type": "string"}},
                       "required": ["city"]}}}]
    for city in ["Gdansk", "Berlin", "Oslo", "Rome", "Paris"]:
        _, _, msg, _ = chat(
            [{"role": "user", "content": f"What's the weather in {city}? Use the tool."}],
            tools=tools, max_tokens=512)
        calls = msg.get("tool_calls") or []
        try:
            hit = (json.loads(calls[0]["function"]["arguments"])["city"] == city)
        except Exception:
            hit = False
        ok, fail = ok + hit, fail + (not hit)
        print(("PASS" if hit else "FAIL"), "tool", city, calls[:1])
    for i in range(5):  # small-budget aux call must return content
        text, fin, _, _ = chat([{"role": "user", "content":
            "Write a 4-word title for a chat about repairing a bicycle tyre."}],
            max_tokens=32)
        hit = len(text.strip()) > 0 and fin != "length"
        ok, fail = ok + hit, fail + (not hit)
        print(("PASS" if hit else "FAIL"), "title", i, repr(text[:60]), fin)
    print(f"QUALITY {ok}/{ok + fail}")


def corruption(n):
    words = ["alpha", "bravo", "cluster", "delta", "ingress", "volume", "node",
             "pod", "gateway", "secret", "backup", "metric"]
    results, lock = [], threading.Lock()

    def convo(seed):
        rnd = random.Random(seed)
        system = " ".join(rnd.choice(words) for _ in range(5000))  # ~6-8K tokens
        msgs = [{"role": "system",
                 "content": "You are a terse ops assistant. Notes: " + system}]
        bad = 0
        for turn in range(6):
            msgs.append({"role": "user", "content":
                         f"Turn {turn}: give two sentences on topic {rnd.choice(words)}."})
            text, fin, _, _ = chat(msgs, max_tokens=400)
            if looks_corrupt(text, fin):
                bad += 1
                print("CORRUPT", seed, turn, repr(text[-80:]), fin)
            msgs.append({"role": "assistant", "content": text})
        with lock:
            results.append((6, bad))

    done = 0
    while done < n:
        batch = [threading.Thread(target=convo, args=(random.random(),))
                 for _ in range(4)]  # 4 concurrent conversations over 2 slots
        [t.start() for t in batch]
        [t.join() for t in batch]
        done += 4 * 6
    turns = sum(t for t, _ in results)
    bad = sum(b for _, b in results)
    print(f"CORRUPTION {bad}/{turns} = {100*bad/turns:.1f}%")


if __name__ == "__main__":
    if sys.argv[1] == "quality":
        quality()
    else:
        corruption(int(sys.argv[2]))
