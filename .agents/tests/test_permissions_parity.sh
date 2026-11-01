#!/usr/bin/env bash
# .claude/settings.json agrees with .agents/policy/permissions.md in both directions, and the
# consent-required commands are not auto-allowed.
# shellcheck source-path=SCRIPTDIR source=lib.sh
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
  for p in 'git commit*--no-verify' 'git commit -n' 'git commit* -n)' 'git commit* -n *' 'git push*--no-verify' 'git push*origin main' 'bws secret get' 'terraform destroy'; do
    jq -e --arg p "Bash($p" '.permissions.deny | map(select(startswith($p))) | length > 0' "$root/.claude/settings.json" >/dev/null \
      || { echo "no deny rule for: $p"; bad=1; }
  done
  jq -e '.permissions.allow | index("Bash(gh api *)") | not' "$root/.claude/settings.json" >/dev/null \
    || { echo "blanket gh api is allowed"; bad=1; }
  return $bad
}

# matches <pattern> <command>: Claude permission globs use only *, which is the shell case dialect.
matches() {
  local pat="$1" cmd="$2"
  pat="${pat#Bash(}"; pat="${pat%)}"
  # shellcheck disable=SC2254
  case "$cmd" in $pat) return 0 ;; esac
  return 1
}
# decision <root> <command>: deny, ask, allow or prompt, in Claude's order (deny, then ask, then allow).
decision() {
  local root="$1" cmd="$2" list pat
  for list in deny ask allow; do
    while IFS= read -r pat; do
      matches "$pat" "$cmd" && { echo "$list"; return 0; }
    done < <(jq -r --arg l "$list" '.permissions[$l][]' "$root/.claude/settings.json")
  done
  echo prompt
}
denied() { [ "$(decision "$1" "$2")" = deny ]; }
expect() { # root want command...: the decision for each command must be exactly <want>
  local root="$1" want="$2" c got bad=0; shift 2
  for c in "$@"; do
    got="$(decision "$root" "$c")"
    [ "$got" = "$want" ] || { echo "[$c] is $got, expected $want"; bad=1; }
  done
  return $bad
}
not_allowed() { # root command...: never auto-allowed (ask, deny or prompt are all fine)
  local root="$1" c bad=0; shift
  for c in "$@"; do
    [ "$(decision "$root" "$c")" != allow ] || { echo "[$c] is auto-allowed"; bad=1; }
  done
  return $bad
}
check_read_only_allowed() { # root: routine read commands run without a prompt
  expect "$1" allow \
    'kubectl config current-context' 'kubectl config get-contexts' 'kubectl config get-contexts -o name' 'kubectl config view' 'kubectl config view --minify' \
    'argocd app get media-plex' 'argocd app diff media-plex' 'argocd app list' \
    'git branch' 'git branch --list' 'git branch --show-current' 'git branch -a' 'git branch -r' 'git branch -vv' 'git branch -avv' 'git branch --all' \
    'helm repo list' 'helm template x .' 'kubectl get pods -A'
}
check_kubectl_config_guarded() {
  expect "$1" ask 'kubectl config set-context x' 'kubectl config set-credentials x' 'kubectl config set-cluster x' 'kubectl config use-context x' 'kubectl config use x' \
    'kubectl config delete-context x' 'kubectl config delete-user x' 'kubectl config rename-context a b' 'kubectl config unset users.x' &&
  expect "$1" deny 'kubectl config view --raw' 'kubectl config view --flatten --raw'
}
check_forced_refresh_asked() {
  expect "$1" ask 'argocd app get media-plex --refresh' 'argocd app get media-plex --hard-refresh' 'argocd app get --refresh media-plex' 'argocd app get --hard-refresh media-plex' \
    'argocd app diff media-plex --refresh' 'argocd app diff media-plex --hard-refresh'
}
check_branch_options_not_allowed() {
  not_allowed "$1" 'git branch -a -D feat/x' 'git branch -r -d origin/x' 'git branch -v -m a b' 'git branch -vv --force x' 'git branch -a --delete x' 'git branch -D x' \
    'git branch -a -u origin/main' 'git branch --list -D x' 'git branch --all --set-upstream-to=origin/main'
}
check_no_broad_allow() { # root: these families are allowed only through exact or read-subcommand patterns
  local bad
  bad="$(jq -r '.permissions.allow[] | select(. == "Bash(kubectl config *)" or . == "Bash(helm repo *)" or (startswith("Bash(git branch") and endswith("*)")))' "$1/.claude/settings.json")"
  [ -z "$bad" ] || { echo "broad allow: $bad"; return 1; }
}
check_helm_repo_guarded() {
  expect "$1" ask 'helm repo add x https://example.invalid' 'helm repo remove x' 'helm repo update' 'helm repo index .'
}
check_hook_skip_denied() { # root: every spelling of "skip the hooks" is denied
  local root="$1" bad=0 c
  for c in 'git commit --no-verify -m x' 'git commit -m x --no-verify' 'git commit -n -m x' 'git commit -nm x' \
           'git commit -m x -n' 'git commit -m x -n --amend' 'git push --no-verify' 'git push origin feat/x --no-verify'; do
    denied "$root" "$c" || { echo "not denied: $c"; bad=1; }
  done
  return $bad
}
check_normal_commits_allowed() { # root: ordinary commits are not caught by the deny rules
  local root="$1" bad=0 c
  for c in 'git commit -m "fix thing"' 'git commit -am "update runner"' 'git commit --amend --no-edit' 'git push -u origin feat/x'; do
    ! denied "$root" "$c" || { echo "wrongly denied: $c"; bad=1; }
  done
  return $bad
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "settings.json is valid JSON" jq empty "$REPO_ROOT/.claude/settings.json"
assert_ok "settings.json and permissions.md agree" check_parity "$REPO_ROOT"
assert_ok "no pattern is both allowed and restricted" check_no_overlap "$REPO_ROOT"
assert_ok "consent-required commands are asked, never allowed" check_required "$REPO_ROOT"
assert_ok "--no-verify and -n are denied in every spelling" check_hook_skip_denied "$REPO_ROOT"
assert_ok "ordinary commits and pushes are not denied" check_normal_commits_allowed "$REPO_ROOT"
assert_ok "routine read commands run without a prompt" check_read_only_allowed "$REPO_ROOT"
assert_ok "kubectl config mutations ask, --raw is denied" check_kubectl_config_guarded "$REPO_ROOT"
assert_ok "forced ArgoCD refresh asks" check_forced_refresh_asked "$REPO_ROOT"
assert_ok "git branch with extra options is not auto-allowed" check_branch_options_not_allowed "$REPO_ROOT"
assert_ok "helm repo mutations ask" check_helm_repo_guarded "$REPO_ROOT"
assert_ok "no broad allow for kubectl config, helm repo or git branch" check_no_broad_allow "$REPO_ROOT"

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
fixture "$TMP/g"; jq '.permissions.deny -= ["Bash(git commit -n*)", "Bash(git commit* -n)", "Bash(git commit* -n *)"]' "$TMP/g/.claude/settings.json" > "$TMP/g.json" && mv "$TMP/g.json" "$TMP/g/.claude/settings.json"
assert_fails "removed -n rules are detected by the matcher" check_hook_skip_denied "$TMP/g"
assert_fails "removed -n rules are detected by the required list" check_required "$TMP/g"
assert_fails "removed -n rules are detected by parity" check_parity "$TMP/g"
fixture "$TMP/h"; jq '.permissions.deny -= ["Bash(git commit*--no-verify*)"]' "$TMP/h/.claude/settings.json" > "$TMP/h.json" && mv "$TMP/h.json" "$TMP/h/.claude/settings.json"
assert_fails "removed --no-verify rule is detected by the matcher" check_hook_skip_denied "$TMP/h"
fixture "$TMP/i"; jq '.permissions.deny += ["Bash(git commit *)"]' "$TMP/i/.claude/settings.json" > "$TMP/i.json" && mv "$TMP/i.json" "$TMP/i/.claude/settings.json"
assert_fails "over-broad deny of all commits is detected" check_normal_commits_allowed "$TMP/i"
# Negative fixtures for the tightened rules: put the old broad rule back, or drop the new one, and the check must fail.
mutate() { # dir jq-filter
  jq "$2" "$1/.claude/settings.json" > "$1.json" && mv "$1.json" "$1/.claude/settings.json"
}
fixture "$TMP/j"; mutate "$TMP/j" '.permissions.allow += ["Bash(kubectl config *)"]'
assert_fails "broad kubectl config allow is detected statically" check_no_broad_allow "$TMP/j"
fixture "$TMP/j2"; mutate "$TMP/j2" '.permissions.allow += ["Bash(kubectl config *)"] | .permissions.ask -= ["Bash(kubectl config set*)", "Bash(kubectl config use*)", "Bash(kubectl config delete-*)", "Bash(kubectl config rename-context*)", "Bash(kubectl config unset*)"]'
assert_fails "the old broad kubectl config allow lets mutations through" check_kubectl_config_guarded "$TMP/j2"
fixture "$TMP/k"; mutate "$TMP/k" '.permissions.ask -= ["Bash(argocd app get *--refresh*)"]'
assert_fails "missing --refresh ask rule is detected" check_forced_refresh_asked "$TMP/k"
fixture "$TMP/l"; mutate "$TMP/l" '.permissions.ask -= ["Bash(argocd app get *--hard-refresh*)"]'
assert_fails "missing --hard-refresh ask rule is detected" check_forced_refresh_asked "$TMP/l"
fixture "$TMP/m"; mutate "$TMP/m" '.permissions.allow += ["Bash(git branch -a*)"]'
assert_fails "git branch -a* wildcard is detected" check_branch_options_not_allowed "$TMP/m"
assert_fails "git branch -a* wildcard is detected statically" check_no_broad_allow "$TMP/m"
fixture "$TMP/n"; mutate "$TMP/n" '.permissions.allow += ["Bash(git branch -v*)", "Bash(git branch -vv*)", "Bash(git branch -r*)", "Bash(git branch --list*)"]'
assert_fails "git branch -v*, -vv*, -r*, --list* wildcards are detected" check_branch_options_not_allowed "$TMP/n"
fixture "$TMP/o"; mutate "$TMP/o" '.permissions.allow += ["Bash(helm repo *)"]'
assert_fails "broad helm repo allow is detected statically" check_no_broad_allow "$TMP/o"
fixture "$TMP/o2"; mutate "$TMP/o2" '.permissions.allow += ["Bash(helm repo *)"] | .permissions.ask -= ["Bash(helm repo add*)", "Bash(helm repo remove*)", "Bash(helm repo update*)", "Bash(helm repo index*)"]'
assert_fails "the old broad helm repo allow lets mutations through" check_helm_repo_guarded "$TMP/o2"
fixture "$TMP/p"; mutate "$TMP/p" '.permissions.allow -= ["Bash(git branch -a)", "Bash(kubectl config get-contexts*)"]'
assert_fails "over-tightening that breaks routine reads is detected" check_read_only_allowed "$TMP/p"
finish
