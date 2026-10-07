#!/usr/bin/env bash
# render.sh <node> [out-file]
# Render one node's machine config: talosctl gen config base (pinned contract) + the patch layers
# all/, <role>/, node/<name>/ in order. Writes clusterconfig/home-<node>.yaml by default (mode 600).
#
# Needs in the environment: KUBERNETES_VERSION, TALOS_VERSION, TALHELPER_CLUSTERDOMAIN, and either the
# Bitwarden-derived TALHELPER_* secrets (rendered into secrets.yaml.tpl) or SECRETS_FILE pointing at a
# talosctl secrets bundle (tests and CI use a throwaway one).
set -euo pipefail
umask 077
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

node="${1:?usage: render.sh <node> [out-file]}"
type="$(node_field "$node" type)"
[ -n "$type" ] || die "unknown node: $node"
out="${2:-$TALOS_DIR/clusterconfig/home-$node.yaml}"
: "${KUBERNETES_VERSION:?KUBERNETES_VERSION is not set}"
: "${TALOS_VERSION:?TALOS_VERSION is not set}"
: "${TALHELPER_CLUSTERDOMAIN:?TALHELPER_CLUSTERDOMAIN is not set}"

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

if [ -n "${SECRETS_FILE:-}" ]; then
  cp "$SECRETS_FILE" "$work/secrets.yaml"
else
  envsubst < "$TALOS_DIR/secrets.yaml.tpl" > "$work/secrets.yaml"
fi

talosctl gen config "$CLUSTER_NAME" "https://${TALHELPER_CLUSTERDOMAIN}:6443" \
  --with-secrets "$work/secrets.yaml" \
  --talos-version "$TALOS_CONTRACT" \
  --kubernetes-version "$KUBERNETES_VERSION" \
  --output-types "$type" \
  --with-docs=false --with-examples=false \
  -o "$work/base.yaml" --force >"$work/gen.log" 2>&1 || { cat "$work/gen.log" >&2; die "talosctl gen config failed"; }

args=()
i=0
while IFS= read -r f; do
  case "$f" in
    *.tpl)
      while IFS= read -r v; do
        [ -n "${!v:-}" ] || die "${f#"$PATCHES_DIR"/} needs \$$v, which is not set"
      done < <(grep -o '\${[A-Za-z0-9_]*}' "$f" | tr -d '${}' | sort -u)
      p="$work/patch-$i.yaml"; envsubst "$TPL_VARS" < "$f" > "$p" ;;
    *) p="$f" ;;
  esac
  args+=(--patch "@$p")
  i=$((i + 1))
done < <(patch_files "$node")

# The PKI documents are generated from the same secrets bundle (see pki-documents.sh), after the file patches
"$(dirname "${BASH_SOURCE[0]}")/pki-documents.sh" "$type" "$work/secrets.yaml" > "$work/pki-documents.yaml" \
  || die "generating the PKI documents failed"
args+=(--patch "@$work/pki-documents.yaml")

mkdir -p "$(dirname "$out")"
talosctl machineconfig patch "$work/base.yaml" "${args[@]}" -o "$out"
chmod 600 "$out"
