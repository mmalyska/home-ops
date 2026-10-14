#!/usr/bin/env bash
# Real-Hermes-traffic corruption test. Drives `hermes -p <profile> chat -q`
# concurrently (one background loop per profile) through the llama-server
# Service, then classifies every reply.
#
#   hermes-corruption.sh <rounds-per-profile> <profile> [<profile>...]
#
# Env: OUT (default /tmp/hermes-corruption), NS (hermes-agent).
# A reply is CORRUPT when it leaks reasoning markers, is empty, or is cut off
# (last text line does not end in sentence punctuation) -- the llama.cpp#29002
# failure shape. Prints CORRUPTION bad/total, plus p50/p95 seconds per turn.
set -euo pipefail
ROUNDS=${1:?rounds per profile}; shift
[ "$#" -ge 1 ] || { echo "need at least one profile" >&2; exit 2; }
OUT=${OUT:-/tmp/hermes-corruption}; NS=${NS:-hermes-agent}
rm -rf "$OUT"; mkdir -p "$OUT"

PROMPTS=(
  "List the three most important checks before upgrading a Kubernetes node, in two sentences."
  "Explain what a PodDisruptionBudget does and when it blocks a drain, in two sentences."
  "Summarise the difference between a Deployment and a StatefulSet in two sentences."
  "Give two reasons a Ceph cluster can report HEALTH_WARN after a node reboot, in two sentences."
  "Write a one-paragraph runbook for a pod stuck in CrashLoopBackOff."
  "What does a Kubernetes readiness probe do versus a liveness probe? Two sentences."
)

run_profile() {
  local p=$1 i prompt t0
  for i in $(seq 1 "$ROUNDS"); do
    prompt=${PROMPTS[$(( (i - 1) % ${#PROMPTS[@]} ))]}
    t0=$(date +%s)
    kubectl -n "$NS" exec deploy/hermes-agent -c hermes-agent -- \
      hermes -p "$p" chat -q "$prompt" >"$OUT/$p-$i.txt" 2>&1 || echo "EXIT_NONZERO" >>"$OUT/$p-$i.txt"
    echo $(( $(date +%s) - t0 )) >"$OUT/$p-$i.sec"
  done
}

for p in "$@"; do run_profile "$p" & done
wait

python3 -I - "$OUT" <<'PY'
import glob, os, re, statistics, sys
out = sys.argv[1]
META = re.compile(r"^(Session|Title|Duration|Messages|Model|Provider|Profile|Tokens?|Cost)\b.*:", re.I)
bad = total = 0
secs = []
for f in sorted(glob.glob(os.path.join(out, "*.txt"))):
    total += 1
    text = open(f, errors="replace").read()
    body = [l for l in text.splitlines() if l.strip() and not META.match(l.strip())]
    why = None
    if "EXIT_NONZERO" in text:
        why = "hermes exited non-zero"
    elif re.search(r"</?think>|<\|channel\|>|<\|im_start\|>", text):
        why = "reasoning marker leaked"
    elif not body:
        why = "empty reply"
    elif body[-1].strip()[-1] not in ".!?)`\"'*]}>0123456789:":
        why = "truncated: " + repr(body[-1].strip()[-60:])
    if why:
        bad += 1
        print("CORRUPT", os.path.basename(f), "-", why)
    s = f[:-4] + ".sec"
    if os.path.exists(s):
        secs.append(int(open(s).read().strip() or 0))
print(f"CORRUPTION {bad}/{total} = {100 * bad / max(total, 1):.1f}%")
if secs:
    secs.sort()
    p95 = secs[min(len(secs) - 1, int(len(secs) * 0.95))]
    print(f"LATENCY p50={statistics.median(secs):.0f}s p95={p95}s max={secs[-1]}s n={len(secs)}")
PY
