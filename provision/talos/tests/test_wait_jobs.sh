#!/usr/bin/env bash
# Tests for scripts/wait-jobs.sh, with a stub kubectl that serves Job lists from files.
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/lists"

# The stub prints lists/<n>.json for the n-th call (the last one repeats), or fails when lists/fail exists
cat > "$TMP/bin/kubectl" <<STUB
#!/usr/bin/env bash
[ ! -e "$TMP/lists/fail" ] || { echo "the connection to the server was refused" >&2; exit 1; }
n=\$(( \$(cat "$TMP/calls" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$TMP/calls"
f="$TMP/lists/\$n.json"; [ -f "\$f" ] || f="\$(ls "$TMP/lists"/*.json | sort -V | tail -1)"
cat "\$f"
STUB
chmod +x "$TMP/bin/kubectl"
reset() { rm -f "$TMP/calls" "$TMP/lists"/*; }
run() { PATH="$TMP/bin:$PATH" WAIT_JOBS_TIMEOUT="${TIMEOUT:-3}" WAIT_JOBS_INTERVAL=1 "$SCRIPTS/wait-jobs.sh" "$@"; }

job() { # namespace name status-json
  printf '{"metadata":{"namespace":"%s","name":"%s"},"status":%s}' "$1" "$2" "$3"
}
list() { printf '{"items":[%s]}\n' "$(IFS=,; echo "$*")"; }

echo "-- idle cluster"
reset
list "$(job backup done '{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}')" > "$TMP/lists/1.json"
assert_ok "completed Jobs pass" run
reset; list > "$TMP/lists/1.json"
assert_ok "no Jobs at all passes" run

echo "-- a failed Job does not hold the gate (the bug)"
reset
list "$(job backup talos-backup-1 '{"failed":1,"conditions":[{"type":"Failed","status":"True","reason":"BackoffLimitExceeded"}]}')" \
     "$(job backup ok '{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}')" > "$TMP/lists/1.json"
assert_ok "a failed Job passes" run
out="$(run 2>&1)"
assert_contains "$out" "failed Jobs are ignored by the gate: backup/talos-backup-1" "the failed Job is named in a warning"
reset
list "$(job x suspended '{}')" > "$TMP/lists/1.json"
assert_ok "a Job with no active pods (suspended or not started) passes" run

echo "-- a running Job holds the gate"
reset
list "$(job backup mysql-backup '{"active":1}')" > "$TMP/lists/1.json"
assert_fails "a running Job that never ends fails after the timeout" env TIMEOUT=2 PATH="$TMP/bin:$PATH" WAIT_JOBS_TIMEOUT=2 WAIT_JOBS_INTERVAL=1 "$SCRIPTS/wait-jobs.sh"
out="$(TIMEOUT=2 run 2>&1 || true)"
assert_contains "$out" "Jobs still running after 2s: backup/mysql-backup" "the running Job is named when the gate gives up"
reset
list "$(job backup mysql-backup '{"active":1}')" > "$TMP/lists/1.json"
list "$(job backup mysql-backup '{"succeeded":1,"conditions":[{"type":"Complete","status":"True"}]}')" > "$TMP/lists/2.json"
assert_ok "a running Job that finishes lets the gate pass" run
assert_eq "2" "$(cat "$TMP/calls")" "it polled again instead of passing at once"
reset
list "$(job backup running '{"active":1}')" "$(job backup old '{"failed":1,"conditions":[{"type":"Failed","status":"True"}]}')" > "$TMP/lists/1.json"
list "$(job backup old '{"failed":1,"conditions":[{"type":"Failed","status":"True"}]}')" > "$TMP/lists/2.json"
assert_ok "a failed Job next to a running one: the gate waits for the running one only" run

echo "-- an unreadable cluster is not idle"
reset; : > "$TMP/lists/fail"
assert_fails "kubectl failing fails the gate instead of passing" run
finish
