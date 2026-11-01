#!/usr/bin/env bash
# .claude/settings.json agrees with .agents/policy/permissions.md in both directions, and the
# consent-required commands are not auto-allowed.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# class heading -> settings lists it may appear in
allowed_lists() { # class -> space-separated lists
  case "$1" in
    READ|LOCAL_CHECK) echo allow ;;
    DELIVERY) echo "allow ask deny" ;;
    SECRET_ACCESS) echo deny ;;
    GITOPS_TRIGGER|RUNTIME_MUTATION) echo ask ;;
    DESTRUCTIVE) echo "ask deny" ;;
    *) echo "" ;;
  esac
}

doc_spans() { # root -> "CLASS<TAB>span" for every `Bash(...)` span under a "## CLASS" heading
  awk '/^## /{cls=$2} cls!="" {line=$0; while (match(line, /`Bash\([^`]*\)`/)) { s=substr(line, RSTART+1, RLENGTH-2); print cls "\t" s; line=substr(line, RSTART+RLENGTH) }}' \
    "$1/.agents/policy/permissions.md"
}
settings_entries() { # root -> "list<TAB>pattern"
  jq -r '.permissions | to_entries[] | .key as $l | .value[] | "\($l)\t\(.)"' "$1/.claude/settings.json"
}

check_parity() { # root
  local root="$1" bad=0 list pat cls docs settings
  docs="$(doc_spans "$root")"; settings="$(settings_entries "$root")"
  while IFS=$'\t' read -r list pat; do # settings -> doc
    found=0
    while IFS=$'\t' read -r cls span; do
      [ "$span" = "$pat" ] || continue
      case " $(allowed_lists "$cls") " in *" $list "*) found=1 ;; esac
    done <<< "$docs"
    [ "$found" -eq 1 ] || { echo "settings $list entry not documented under a fitting class: $pat"; bad=1; }
  done <<< "$settings"
  while IFS=$'\t' read -r cls span; do # doc -> settings
    found=0
    for list in $(allowed_lists "$cls"); do
      grep -qxF "$list"$'\t'"$span" <<< "$settings" && found=1
    done
    [ "$found" -eq 1 ] || { echo "documented under $cls but not enforced in settings: $span"; bad=1; }
  done <<< "$docs"
  return $bad
}

check_no_overlap() { # a pattern in allow and in ask/deny would be shadowed
  local dup
  dup="$(jq -r '.permissions | (.allow // []) as $a | ((.ask // []) + (.deny // []))[] | select(. as $x | $a | index($x))' "$1/.claude/settings.json")"
  [ -z "$dup" ] || { echo "allowed and restricted: $dup"; return 1; }
}

check_required() { # root: consent-required prefixes are asked about and never allowed
  local root="$1" bad=0 p
  local required='gh pr merge|gh pr create|gh workflow run|argocd app sync|argocd app set|argocd app delete|terraform apply|terraform import|talosctl apply-config|talosctl upgrade|kubectl apply|kubectl create|kubectl delete|kubectl patch|kubectl annotate|kubectl label|kubectl scale|kubectl exec|kubectl drain|kubectl cordon|kubectl uncordon|kubectl rollout restart|bws secret create|bws secret edit|bws secret delete'
  while IFS= read -r p; do
    jq -e --arg p "Bash($p" '.permissions.ask | map(select(startswith($p))) | length > 0' "$root/.claude/settings.json" >/dev/null \
      || { echo "no ask rule for: $p"; bad=1; }
    jq -e --arg p "Bash($p" '.permissions.allow | map(select(startswith($p))) | length == 0' "$root/.claude/settings.json" >/dev/null \
      || { echo "allow rule for consent-required command: $p"; bad=1; }
  done <<< "${required//|/$'\n'}"
  for p in 'git commit*--no-verify' 'git push*--no-verify' 'git push*origin main' 'bws secret get' 'terraform destroy'; do
    jq -e --arg p "Bash($p" '.permissions.deny | map(select(startswith($p))) | length > 0' "$root/.claude/settings.json" >/dev/null \
      || { echo "no deny rule for: $p"; bad=1; }
  done
  jq -e '.permissions.allow | index("Bash(gh api *)") | not' "$root/.claude/settings.json" >/dev/null \
    || { echo "blanket gh api is allowed"; bad=1; }
  return $bad
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "settings.json is valid JSON" jq empty "$REPO_ROOT/.claude/settings.json"
assert_ok "settings.json and permissions.md agree" check_parity "$REPO_ROOT"
assert_ok "no pattern is both allowed and restricted" check_no_overlap "$REPO_ROOT"
assert_ok "consent-required commands are asked, never allowed" check_required "$REPO_ROOT"

echo "-- negative fixtures"
fixture "$TMP/a"; jq '.permissions.allow += ["Bash(gh api *)"]' "$TMP/a/.claude/settings.json" > "$TMP/a.json" && mv "$TMP/a.json" "$TMP/a/.claude/settings.json"
assert_fails "undocumented allow entry is detected" check_parity "$TMP/a"
assert_fails "blanket gh api allow is detected" check_required "$TMP/a"
fixture "$TMP/b"; jq '.permissions.ask -= ["Bash(gh pr merge*)"]' "$TMP/b/.claude/settings.json" > "$TMP/b.json" && mv "$TMP/b.json" "$TMP/b/.claude/settings.json"
assert_fails "removed ask rule is detected by parity" check_parity "$TMP/b"
assert_fails "removed ask rule is detected by required list" check_required "$TMP/b"
fixture "$TMP/c"; jq '.permissions.deny -= ["Bash(bws secret get*)"]' "$TMP/c/.claude/settings.json" > "$TMP/c.json" && mv "$TMP/c.json" "$TMP/c/.claude/settings.json"
assert_fails "removed deny rule is detected" check_required "$TMP/c"
fixture "$TMP/d"; jq '.permissions.allow += ["Bash(kubectl apply -f *)"]' "$TMP/d/.claude/settings.json" > "$TMP/d.json" && mv "$TMP/d.json" "$TMP/d/.claude/settings.json"
assert_fails "allowed mutation is detected" check_required "$TMP/d"
fixture "$TMP/e"; jq '.permissions.allow += ["Bash(kubectl get *)"] | .permissions.ask += ["Bash(kubectl get *)"]' "$TMP/e/.claude/settings.json" > "$TMP/e.json" && mv "$TMP/e.json" "$TMP/e/.claude/settings.json"
assert_fails "shadowed allow entry is detected" check_no_overlap "$TMP/e"
fixture "$TMP/f"
# shellcheck disable=SC2016
sed -i 's/`Bash(helm lint \*)`/`helm lint`/' "$TMP/f/.agents/policy/permissions.md"
assert_fails "pattern missing from the policy is detected" check_parity "$TMP/f"
finish
