#!/usr/bin/env bash
# Renders every enabled app the way the ArgoCD CMP does (cluster/apps/core/argocd/resources/
# sops-replacer-plugin.yaml), without the secret replacement: one <app>.yaml per app in <outdir>.
#
#   render-apps.sh <outdir> [app ...]
#
# App names are the Application names: the folder name, or <folder>-<appSubfolder>. With no names,
# every entry with enabled: "true" in cluster/apps/*/*/app-config.yaml is rendered.
# Helm apps render in place: `file://../../../../charts/...` dependencies only resolve from there.
# The Chart.lock and charts/*.tgz this leaves behind are gitignored.
set -uo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <outdir> [app ...]" >&2
  exit 2
fi
out=$1
shift
want=("$@")

root=$(git rev-parse --show-toplevel)
apis_file="$root/.taskfiles/lint/resources/kube-api-versions.txt"
kube_version=$(sed -n 's/^# kube-version: //p' "$apis_file")
api_versions=$(grep -v '^#' "$apis_file" | paste -sd, -)
if [[ -z $kube_version || -z $api_versions ]]; then
  echo "cannot read kube-version or API versions from $apis_file" >&2
  exit 2
fi

mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$root" || exit 2

rendered=0
failed=()
for cfg in cluster/apps/*/*/app-config.yaml; do
  dir=$(dirname "$cfg")
  base=$(basename "$dir")
  count=$(yq 'length' "$cfg")
  for ((i = 0; i < count; i++)); do
    [[ $(yq ".[$i].enabled" "$cfg") == "true" ]] || continue
    ns=$(yq ".[$i].namespace" "$cfg")
    sub=$(yq ".[$i].appSubfolder // \"\"" "$cfg")
    if [[ -n $sub ]]; then
      src=$dir/$sub
      app=$base-$sub
    else
      src=$dir
      app=$base
    fi
    if [[ ${#want[@]} -gt 0 && ! " ${want[*]} " =~ \ $app\  ]]; then
      continue
    fi

    status=0
    if [[ -f $src/kustomization.yaml ]]; then
      kustomize build --enable-alpha-plugins "$src" >"$out/$app.yaml" 2>"$out/$app.err" || status=$?
    elif [[ -f $src/Chart.yaml ]]; then
      (
        cd "$src" &&
          helm dependency update >/dev/null &&
          helm template --include-crds --release-name "$app" --namespace "$ns" \
            --kube-version "$kube_version" --api-versions "$api_versions" .
      ) >"$out/$app.yaml" 2>"$out/$app.err" || status=$?
    else
      echo "no Chart.yaml or kustomization.yaml in $src" >"$out/$app.err"
      status=1
    fi

    if [[ $status -eq 0 ]]; then
      rendered=$((rendered + 1))
      rm -f "$out/$app.err"
    else
      failed+=("$app")
      echo "FAIL render $app ($src):" >&2
      sed 's/^/  /' "$out/$app.err" >&2
      rm -f "$out/$app.yaml" "$out/$app.err"
    fi
  done
done

echo "render: ${rendered} apps rendered, ${#failed[@]} failed${failed[*]:+: ${failed[*]}}"
[[ ${#failed[@]} -eq 0 ]]
