#!/usr/bin/env bash
# Test of the secret loading in .envrc, without direnv, bws or the network: `bws` is a stub that prints JSON, `log_status`
# and `expand_path` are the direnv helpers. Run: bash .github/tests/envrc.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fail=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

# run_envrc <json>: sources .envrc in a clean subshell with a stub bws that prints <json>; prints "NAME=value" lines of
# the variables the file added, then the file's own stdout/stderr after a marker.
run_envrc() {
    local json=$1
    ( cd "$ROOT" || exit 1
      STUB_JSON=$json; HOME=$(mktemp -d); export STUB_JSON HOME
      bws() { if [ -n "${STUB_JSON}" ]; then printf '%s' "${STUB_JSON}"; else return 1; fi; }
      log_status() { echo "LOG: $*"; }
      expand_path() { echo "$1"; }
      outfile=$(mktemp)
      before=$(env | sort)
      # sourced in this shell (not in $(...), whose exports would be lost); its output goes to a file
      # shellcheck disable=SC1091
      source .envrc > "$outfile" 2>&1
      after=$(env | sort)
      comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after")
      echo "----OUT"
      cat "$outfile" )
}

KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----'
JSON=$(jq -n --arg k "$KEY" '[
  {key:"PLAIN", value:"abc123"},
  {key:"WITH_SPACES", value:"two words"},
  {key:"WITH_QUOTES", value:"say \"hi\" and '"'"'bye'"'"'"},
  {key:"SPECIALS", value:"a$b`c`$(d)\\e"},
  {key:"SSH_SIGNING_KEY", value:$k},
  {key:"OTHER_MULTILINE", value:"line1\nline2"},
  {key:"bad-name", value:"x"},
  {key:"AFTER_THE_BAD_ONES", value:"still-loaded"}
]')
res=$(run_envrc "$JSON")
vars=${res%%----OUT*}
out=${res#*----OUT}

has() { printf '%s\n' "$vars" | grep -qxF -- "$1"; }
has 'PLAIN=abc123'                           && ok "plain value exported"                    || bad "plain value exported"
has 'WITH_SPACES=two words'                  && ok "value with spaces exported intact"       || bad "value with spaces exported intact"
has 'WITH_QUOTES=say "hi" and '"'"'bye'"'"'' && ok "value with quotes exported intact"       || bad "value with quotes exported intact"
has 'SPECIALS=a$b`c`$(d)\e'                  && ok "value with \$ backticks backslash intact" || bad "value with \$ backticks backslash intact"
has 'AFTER_THE_BAD_ONES=still-loaded'        && ok "secrets after the skipped ones still load" || bad "secrets after the skipped ones still load"
printf '%s\n' "$vars" | grep -q '^SSH_SIGNING_KEY=' && bad "SSH_SIGNING_KEY must not be exported" || ok "SSH_SIGNING_KEY not exported"
printf '%s\n' "$vars" | grep -q '^OTHER_MULTILINE=' && bad "multi-line value must not be exported" || ok "multi-line value skipped"
printf '%s\n' "$vars" | grep -q '^bad-name=' && bad "invalid variable name must not be exported" || ok "invalid variable name skipped"
case "$out" in *"BEGIN OPENSSH"*|*abc123*|*declare\ -x*|*xargs*) bad "the file printed a secret, an environment dump or an xargs error";; *) ok "no secret, dump or xargs error printed";; esac

# a single-line SSH_SIGNING_KEY is skipped too (the explicit rule, not only the multi-line one)
res=$(run_envrc '[{"key":"SSH_SIGNING_KEY","value":"single-line-key-material"},{"key":"KEEP","value":"1"}]')
vars=${res%%----OUT*}
printf '%s\n' "$vars" | grep -q '^SSH_SIGNING_KEY=' && bad "single-line SSH_SIGNING_KEY must not be exported" || ok "single-line SSH_SIGNING_KEY not exported"
printf '%s\n' "$vars" | grep -qx 'KEEP=1' && ok "other secrets still exported next to it" || bad "other secrets still exported next to it"

# failure and empty result: nothing exported, one status line, no dump
for j in "" "[]" "not json"; do
    res=$(run_envrc "$j"); vars=${res%%----OUT*}; out=${res#*----OUT}
    names=$(printf '%s\n' "$vars" | grep -cE '^(PLAIN|WITH_|SPECIALS|AFTER_)' || true)
    case "$out" in *"LOG: bws returned no secrets"*) l=1;; *) l=0;; esac
    case "$out" in *declare\ -x*) d=1;; *) d=0;; esac
    if [ "$names" = 0 ] && [ "$l" = 1 ] && [ "$d" = 0 ]; then ok "bws result [${j:-<fails>}]: nothing exported, one status line, no dump"; else bad "bws result [${j:-<fails>}]"; fi
done
exit $fail
