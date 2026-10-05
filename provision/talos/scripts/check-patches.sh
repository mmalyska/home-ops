#!/usr/bin/env bash
# check-patches.sh: validate the conventions of provision/talos/patches (see README.md).
# Exits 1 and lists every problem it finds. Needs yq.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

errors=0
err() { echo "  $1: $2" >&2; errors=$((errors + 1)); }

allowed_vars="$(printf '%s' "$TPL_VARS" | tr ' ' '\n' | tr -d '${}')"
nodes="$(node_names)"

while IFS=' ' read -r name type; do
  [[ "$type" == controlplane || "$type" == worker ]] || err "nodes.yaml" "node '$name' has type '$type'; must be controlplane or worker"
done < <(yq -r '.nodes[] | .name + " " + .type' "$NODES_FILE")

# directory -> expected "Nodes:" value
expected_nodes() { # path relative to PATCHES_DIR
  case "$1" in
    all/*) echo "all nodes" ;;
    controlplane/*) echo "control plane" ;;
    worker/*) echo "workers" ;;
    node/*/*) local n="${1#node/}"; echo "${n%%/*}" ;;
  esac
}

while IFS= read -r f; do
  rel="${f#"$PATCHES_DIR"/}"
  base="$(basename "$f")"

  [[ "$base" =~ ^[0-9]{2}-[a-z0-9-]+\.yaml(\.tpl)?$ ]] || err "$rel" "name must look like NN-some-name.yaml or NN-some-name.yaml.tpl"

  [[ "$rel" =~ ^(all|controlplane|worker)/[^/]+$ || "$rel" =~ ^node/[^/]+/[^/]+$ ]] \
    || err "$rel" "must sit directly in all/, controlplane/, worker/ or node/<name>/ (deeper files are never rendered)"

  case "$rel" in
    node/*/*) n="${rel#node/}"; n="${n%%/*}"; grep -qxF "$n" <<<"$nodes" || err "$rel" "node directory '$n' is not in nodes.yaml" ;;
  esac

  for key in What Why Nodes Apply; do
    [ -n "$(header_value "$f" "$key")" ] || err "$rel" "missing or empty '# $key:' header line"
  done
  apply="$(header_value "$f" Apply)"
  [[ -z "$apply" || "$apply" =~ ^(live|install-only|reboot)([[:space:]]\(.+\))?$ ]] \
    || err "$rel" "'# Apply:' must be live, install-only or reboot, optionally followed by (reason); got '$apply'"
  want="$(expected_nodes "$rel")"
  [ -z "$(header_value "$f" Nodes)" ] || [ "$(header_value "$f" Nodes)" = "$want" ] \
    || err "$rel" "'# Nodes:' must be '$want' for this directory; got '$(header_value "$f" Nodes)'"

  docs="$(yq ea '[.] | length' "$f" 2>/dev/null || echo 0)"
  [ "$docs" = "1" ] || err "$rel" "must contain exactly one YAML document (found $docs)"

  if [[ "$base" == *.tpl ]] && grep -v '^[[:space:]]*#' "$f" | grep -qE '\$([A-Za-z_]|$)' ; then
    err "$rel" "uses \$VAR without braces; envsubst would replace it silently, write \${VAR}"
  fi

  if grep -q '\${' "$f"; then
    if [[ "$base" != *.tpl ]]; then
      err "$rel" "contains \${...} but is not a .yaml.tpl file"
    else
      while IFS= read -r v; do
        grep -qx "$v" <<<"$allowed_vars" || err "$rel" "variable \${$v} is not in TPL_VARS (scripts/lib.sh)"
      done < <(grep -o '\${[A-Za-z0-9_]*}' "$f" | tr -d '${}' | sort -u)
    fi
  fi
done < <(find "$PATCHES_DIR" -type f | LC_ALL=C sort)

if [ "$errors" -gt 0 ]; then
  echo "check-patches: $errors problem(s)" >&2
  exit 1
fi
echo "check-patches: ok"
