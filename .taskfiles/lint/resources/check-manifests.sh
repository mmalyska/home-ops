#!/usr/bin/env bash
# Renders the enabled apps the way ArgoCD does (render-apps.sh) and checks the output:
#
#   1. render       every enabled app renders
#   2. kubeconform  every rendered resource matches its schema, in strict mode
#   3. promtool     `check rules` on the spec of every PrometheusRule
#   4. rule tests   `promtool test rules` for each app with tests/*.promtool.yaml
#
#   check-manifests.sh [app ...]      (no names: every enabled app)
#
# Every enabled app is always rendered, since an app's custom resources may take their schema from another app's
# CRDs (litellm from litellm-operator). Names only narrow the checks to those apps.
#
# Needs helm, kustomize, yq, python3, kubeconform and promtool (all in the dev-workstation image). Rendered output
# goes to a temp directory; set KEEP_TMP=1 to keep it. Exits non-zero if any step fails.
#
# Rule tests: put them in the app folder as tests/<name>.promtool.yaml with `rule_files: [rules.yaml]`. The script
# writes that app's PrometheusRule groups to rules.yaml next to a copy of the tests.
set -uo pipefail

# The newest Kubernetes schemas kubeconform's default source publishes; the cluster runs a newer version.
schema_kube_version=1.34.12
catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(git -C "$here" rev-parse --show-toplevel)
for tool in helm kustomize yq python3 kubeconform promtool; do
  command -v "$tool" >/dev/null || {
    echo "check-manifests: $tool not found" >&2
    exit 2
  }
done

tmp=$(mktemp -d)
if [[ ${KEEP_TMP:-} == 1 ]]; then
  echo "check-manifests: output kept in $tmp"
else
  trap 'rm -rf "$tmp"' EXIT
fi
raw=$tmp/raw
manifests=$tmp/manifests
mkdir -p "$manifests" "$tmp/schemas" "$tmp/rules" "$tmp/tests"

results=()
failed=0
result() { # step, PASS|FAIL, detail
  results+=("$(printf '%-12s %s  %s' "$1" "$2" "$3")")
  [[ $2 == PASS ]] || failed=1
}

# 1. Render.
if "$here/render-apps.sh" "$raw"; then
  result render PASS "$(find "$raw" -name '*.yaml' | wc -l) apps"
else
  result render FAIL "see FAIL render lines above"
fi
shopt -s nullglob
files=("$raw"/*.yaml)
if [[ $# -gt 0 ]]; then
  files=()
  for app in "$@"; do
    if [[ -f $raw/$app.yaml ]]; then
      files+=("$raw/$app.yaml")
    else
      result select FAIL "$app is not an enabled app, or did not render"
    fi
  done
fi
if [[ ${#files[@]} -eq 0 ]]; then
  echo "check-manifests: nothing rendered" >&2
  exit 1
fi

# Tokens become placeholders before anything is validated or printed, so a value pattern (a hostname, a URL)
# sees a plausible value instead of `<secret:...>`.
for f in "${files[@]}"; do
  sed -E 's/<secret:private-domain>/example.com/g; s/<secret:[^>]*>/placeholder/g' "$f" >"$manifests/$(basename "$f")"
done
cd "$manifests" || exit 2

# 2. kubeconform, with schemas from the CRDs of every rendered app ahead of the public catalog.
yq ea -o json '[select(.kind == "CustomResourceDefinition")]' "$raw"/*.yaml |
  python3 -I "$here/crd2schema.py" "$tmp/schemas" || result schemas FAIL "crd2schema.py failed"
skip=CustomResourceDefinition
while read -r kind; do
  skip+=",$kind"
done < <(grep -vE '^[[:space:]]*(#|$)' "$here/kubeconform-skip.txt")
kc_out=$tmp/kubeconform.txt
if kubeconform -strict -summary \
  -kubernetes-version "$schema_kube_version" \
  -skip "$skip" \
  -schema-location default \
  -schema-location "$tmp/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -schema-location "$catalog" \
  ./*.yaml >"$kc_out" 2>&1; then
  result kubeconform PASS "$(grep '^Summary:' "$kc_out" | sed 's/^Summary: //')"
else
  grep -v '^Summary:' "$kc_out" | sed 's/^/  /'
  result kubeconform FAIL "$(grep '^Summary:' "$kc_out" | sed 's/^Summary: //')"
fi

# 3. promtool check rules, one file per PrometheusRule. Without --lint-fatal: upstream kube-prometheus-stack has a
# duplicate recording rule that is only a lint warning.
for f in ./*.yaml; do
  app=$(basename "$f" .yaml)
  yq -s "\"$tmp/rules/$app-\" + \$index" 'select(.kind == "PrometheusRule") | .spec' "$f"
done
rule_files=("$tmp"/rules/*.yml)
if [[ ${#rule_files[@]} -eq 0 ]]; then
  result promtool PASS "no PrometheusRule rendered"
elif promtool check rules "${rule_files[@]}" >"$tmp/promtool.txt" 2>&1; then
  result promtool PASS "${#rule_files[@]} PrometheusRules"
else
  grep -vE '^(Checking |  SUCCESS: |$)' "$tmp/promtool.txt" | sed 's/^/  /'
  result promtool FAIL "${#rule_files[@]} PrometheusRules"
fi

# 4. Rule tests, for apps whose folder (cluster/apps/<category>/<app>) has tests/*.promtool.yaml.
tested=0
test_failed=()
for tdir in "$root"/cluster/apps/*/*/tests; do
  tests=("$tdir"/*.promtool.yaml)
  [[ ${#tests[@]} -gt 0 ]] || continue
  app=$(basename "$(dirname "$tdir")")
  [[ -f $manifests/$app.yaml ]] || continue # not rendered: disabled, or not in the names given
  dir=$tmp/tests/$app
  mkdir -p "$dir"
  yq ea '[select(.kind == "PrometheusRule") | .spec.groups[]] | {"groups": .}' "$manifests/$app.yaml" >"$dir/rules.yaml"
  cp "${tests[@]}" "$dir/"
  tested=$((tested + 1))
  if ! (cd "$dir" && promtool test rules ./*.promtool.yaml) >"$dir/out.txt" 2>&1; then
    test_failed+=("$app")
    echo "FAIL rule tests $app:"
    sed 's/^/  /' "$dir/out.txt"
  fi
done
if [[ ${#test_failed[@]} -eq 0 ]]; then
  result rule-tests PASS "$tested apps"
else
  result rule-tests FAIL "$tested apps, failed: ${test_failed[*]}"
fi

echo
printf '%s\n' "${results[@]}"
exit "$failed"
