#!/usr/bin/env bash
# Runs the script of the coder-template-push Job against a fake Coder API and CLI.
# Covers: first push, no-op sync, new content, revert to older content (A -> B -> A), a failed existing version,
# and the upload directory (regular files only, no ConfigMap symlinks or hidden entries).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fake="$work/fake"; bin="$work/bin"; mkdir -p "$fake" "$bin" "$work/templates" "$work/stage"

helm template coder "$root/cluster/apps/ai/coder" --set templatePush.enabled=true --set templatePush.tokenBwsId=test \
  -s templates/template-push.yaml >"$work/render.yaml"
# The script without its final per-template `push` calls; the test makes its own.
yq 'select(.kind=="Job")|.spec.template.spec.containers[0].args[0]' "$work/render.yaml" | grep -v '^push "' >"$work/script.sh"

# Fake curl: serves $FAKE/api/<path>.json (404 when missing); honours -o and -w '%{http_code}' and -f.
cat >"$bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; wcode=0; fail=0; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;; -w) wcode=1; shift ;; -H) shift ;; -*f*) fail=1 ;; -*) ;; *) url="$1" ;;
  esac
  shift
done
path="${url#*://*/}"; [ "$url" = "${url%/healthz}" ] || { exit 0; }
file="$FAKE/api/${path#api/v2/}.json"
if [ -f "$file" ]; then code=200; else code=404; fi
[ -z "$out" ] || { [ "$code" = 200 ] && cp "$file" "$out" || : >"$out"; }
[ -n "$out" ] || { [ "$code" = 200 ] && cat "$file"; }
[ "$wcode" = 0 ] || printf '%s' "$code"
[ "$fail" = 0 ] || [ "$code" = 200 ] || exit 22
exit 0
STUB
# Fake coder: records calls and keeps the template state in $FAKE.
cat >"$bin/coder" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/calls.log"
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
t="$FAKE/api"
activate() { # template version
  mkdir -p "$t/organizations/default/templates"
  echo "{\"active_version_id\":\"id-$2\"}" >"$t/organizations/default/templates/$1.json"
}
case "$1 $2 $3" in
  "templates push "*)
    name="$3"; dir="$(arg --directory "$@")"; version="$(arg --name "$@")"
    # Coder only uploads regular files: a symlink or a hidden entry in the directory is a failure.
    [ -z "$(find "$dir" -type l -o -name '.*' -not -path "$dir")" ] || { echo "bad upload dir" >&2; exit 1; }
    [ -f "$dir/main.tf" ] && [ -f "$dir/bootstrap.sh" ] || { echo "files missing in upload dir" >&2; exit 1; }
    mkdir -p "$t/organizations/default/templates/$name/versions" "$t/templateversions"
    echo "{\"job\":{\"status\":\"succeeded\"}}" >"$t/organizations/default/templates/$name/versions/$version.json"
    echo "{\"name\":\"$version\"}" >"$t/templateversions/id-$version.json"
    activate "$name" "$version" ;;
  "templates versions promote")
    activate "$(arg --template "$@")" "$(arg --template-version "$@")" ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/curl" "$bin/coder"

# A templates tree shaped like a ConfigMap volume: symlinks into a hidden ..data directory.
mkdir -p "$work/templates/dev/..data"
for f in main.tf bootstrap.sh; do echo "$f" >"$work/templates/dev/..data/$f"; ln -s "..data/$f" "$work/templates/dev/$f"; done

run() { # hash...
  { cat "$work/script.sh"; for h in "$@"; do echo "push dev $h"; done; } >"$work/run.sh"
  : >"$fake/calls.log"
  FAKE="$fake" PATH="$bin:$PATH" CODER_URL=http://coder.test CODER_SESSION_TOKEN=x \
    TEMPLATES_DIR="$work/templates" STAGE_DIR="$work/stage" bash -eu "$work/run.sh" >"$work/last.out" 2>&1 \
    || { cat "$work/last.out"; return 1; }
}
expect() { # description, pattern for the recorded coder calls ("" = no calls)
  local calls; calls="$(cat "$fake/calls.log")"
  if [ -z "$2" ] && [ -z "$calls" ] || { [ -n "$2" ] && grep -q -- "$2" <<<"$calls"; }; then echo "PASS $1"
  else echo "FAIL $1"; echo "calls: $calls"; cat "$work/last.out"; exit 1; fi
}

run aaa;  expect "first push of A" 'templates push dev .*--name gitops-aaa'
run aaa;  expect "same content: no call" ''
run bbb;  expect "new content B: push" 'templates push dev .*--name gitops-bbb'
run aaa;  expect "revert to A: promote, no 409" 'templates versions promote --template dev --template-version gitops-aaa'
run aaa;  expect "after revert: no call" ''
run aaa bbb aaa; expect "several syncs in one run end on A" 'promote'

# A failed version with the wanted name: push under a suffixed name, and then stay quiet.
echo '{"job":{"status":"failed"}}' >"$fake/api/organizations/default/templates/dev/versions/gitops-ccc.json"
run ccc;  expect "failed existing version: suffixed push" 'templates push dev .*--name gitops-ccc-[0-9]'
run ccc;  expect "after suffixed push: no call" ''
echo "all coder-template-push checks passed"
