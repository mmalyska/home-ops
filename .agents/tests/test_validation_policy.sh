#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes keep Markdown backticks literal
# validation.md names scripts that exist, covers every change type, and keeps the reporting rules.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

# check_paths <root>: every repository path named in backticks in validation.md exists.
check_paths() {
  local root="$1" p bad=0
  while IFS= read -r p; do
    [ -e "$root/$p" ] || { echo "missing path: $p"; bad=1; }
  done < <(grep -o '`[^` ]*`' "$root/.agents/policy/validation.md" | tr -d '`' \
    | grep -E '^(provision|\.agents|\.github|\.taskfiles|\.agents/skills)/[A-Za-z0-9_./-]+$' | grep -vE '/$' | sort -u)
  return $bad
}
# check_rows <root>: one heading per change type.
check_rows() {
  local root="$1" f="$1/.agents/policy/validation.md" bad=0 h
  for h in "Documentation, plans" "Plain YAML" "Helm chart" "Kustomize" "ArgoCD Application" \
    "Talos patches" "Terraform" "ExternalSecret" "Storage, CNPG, Ceph" "Network" "Needs live testing"; do
    grep -q "^### .*$h" "$f" || { echo "no row for: $h"; bad=1; }
  done
  return $bad
}
# check_rules <root>: layers, NOT RUN wording and the advisory statement are present.
check_rules() {
  local f="$1/.agents/policy/validation.md" bad=0 s
  for s in "L0" "L1" "L2" "L3" "NOT RUN" "always exit 0" "file://"; do
    grep -q -- "$s" "$f" || { echo "missing: $s"; bad=1; }
  done
  return $bad
}
check_linked() { grep -q '\.agents/policy/validation\.md' "$1/AGENTS.md"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "named paths exist" check_paths "$REPO_ROOT"
assert_ok "every change type has a row" check_rows "$REPO_ROOT"
assert_ok "layers and reporting rules present" check_rules "$REPO_ROOT"
assert_ok "AGENTS.md links validation.md" check_linked "$REPO_ROOT"

echo "-- negative fixtures"
mkdir -p "$TMP/a/.agents/policy"; cp "$REPO_ROOT/.agents/policy/validation.md" "$TMP/a/.agents/policy/"
printf '\nRun `provision/talos/scripts/nope.sh`.\n' >> "$TMP/a/.agents/policy/validation.md"
assert_fails "missing script is detected" check_paths "$TMP/a"
mkdir -p "$TMP/b/.agents/policy"; sed '/^### Terraform/d' "$REPO_ROOT/.agents/policy/validation.md" > "$TMP/b/.agents/policy/validation.md"
assert_fails "missing change type is detected" check_rows "$TMP/b"
mkdir -p "$TMP/c/.agents/policy"; sed 's/NOT RUN/skipped/g' "$REPO_ROOT/.agents/policy/validation.md" > "$TMP/c/.agents/policy/validation.md"
assert_fails "missing NOT RUN rule is detected" check_rules "$TMP/c"
finish
