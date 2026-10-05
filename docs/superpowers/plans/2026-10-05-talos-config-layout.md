# Talos Config Layout (Phase 1) Implementation Plan

<!-- markdownlint-disable MD013 -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the envsubst-and-append Talos config pipeline with a layered, self-describing multi-document patch layout and a tested render pipeline, proven to change nothing on the nodes, plus the tooling to read it (explain, config map, diff) and the first deprecated-field migration.

**Architecture:** `talosctl gen config` (pinned contract) produces the base per role. Small patch files under `provision/talos/patches/{all,controlplane,worker,node/<name>}` are merged on top in that order with `talosctl machineconfig patch`. Secrets stay in Bitwarden and reach the render only through environment variables, and only inside `*.yaml.tpl` files with an explicit variable allowlist. Everything is plain bash around `talosctl`, `yq` and `jq`, with shell tests and a parity gate that compares normalized, masked output.

**Tech Stack:** bash 4+, `talosctl` v1.14.2 client, `yq` (mikefarah v4), `jq`, `envsubst`, go-task, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-05-talos-config-layout-design.md` (PR #5474; this plan is stacked on that PR until it merges).

## Status of this plan

Before writing it, every script, test and layer file below was built and run in a scratch copy of the repo against the real cluster configuration (read-only):

- the new layers rendered with the real Bitwarden-derived secrets are **identical** (normalized) to what the old pipeline produces, for mc1, mc2, mc3 and nv1;
- the new render equals the **live** config on mc1, mc2 and mc3; nv1 differs only in the stored install-image tag (`v1.13.10` stored, `v1.14.0` in the repo), a known lag;
- the whole switch (Task 6) was rehearsed in a throwaway git worktree: `task talos:generate` through the new pipeline, then `task talos:parity` against the old output, all identical;
- the full test suite passes (94 shell tests) and the layer files pass `yamllint` and `prettier` with the repo configs.

Findings from that prototyping that the spec did not mention, and that the layer files handle:

- `talosctl gen config` adds a `HostnameConfig` (`auto: stable`) document; our static hostnames would conflict, so `patches/all/05-hostname-config-delete.yaml` removes it.
- `talosctl gen config` adds the label `node.kubernetes.io/exclude-from-external-load-balancers` to control planes; the nodes never had it, so `patches/controlplane/85-delete-lb-exclusion-label.yaml` removes it to keep parity (delete that file later to adopt the Talos default).
- The generated base already contains the `kube-system` PodSecurity exemption; lists append, so our patch must not repeat it.
- The Talos 1.14 contract generates a 29-document base that cannot be mixed with the legacy fields; the contract is therefore pinned to `v1.13`.

## Deviations from the spec (flagged for review)

1. `Apply:` has three values, `live`, `install-only` and `reboot`, not two. Talos documents that the `machine.install` fields only matter at install or upgrade, which is neither of the spec's two.
2. Commands take node names after `--` (`task talos:explain -- mc1`), because the Taskfile's `N` variable has a default and cannot mean "all nodes".
3. Of the deprecated-field migrations (Phase 1c) this plan includes only the first one, `machine.sysctls` to `SysctlConfig` (Task 11), as the worked example of the process. The other tiers stay in `.plans/TODO.md`.

## Global Constraints

- Bitwarden Secrets Manager stays the only secret source; nothing encrypted in git.
- Config apply stays manual (`task talos:apply`); no CI runner and no VPN for CI.
- `talosctl gen config` is pinned to a contract that reproduces what the nodes run today: `TALOS_CONTRACT=v1.13` in `scripts/lib.sh`.
- One YAML document per patch file; strategic merge patches only, no JSON patches.
- `envsubst` runs only on `*.yaml.tpl` files, only for the variables in `TPL_VARS`; a `${...}` in a plain `.yaml` file is an error.
- Merge order is `all/`, then `controlplane/` or `worker/`, then `node/<name>/`, and by file name inside a directory.
- Every patch file starts with the header `# What:`, `# Why:`, `# Nodes:`, `# Apply:`. `Apply:` is `live`, `install-only` or `reboot`, optionally followed by a reason in brackets; `Nodes:` must match the directory (`all nodes`, `control plane`, `workers`, or the node name).
- Any diff output shown to a person goes through `scripts/mask.sh`, which hides `crt`, `key`, `token`, `secret`, `secretboxEncryptionSecret`, `aescbcEncryptionSecret`, `password`, `id`, `bootstraptoken` values and the nut `MONITOR` line.
- The switch PR (Task 6) changes nothing on the nodes: its verification is an identical parity result, and it applies nothing.
- Tooling quirks that already bit during prototyping: `yq` (mikefarah v4) has no jq-style `if ... then ... else ... end`; the default `awk` is `mawk`, which has no `{n,m}` interval expressions; `talosctl gen config` with a single `--output-types` treats `-o` as a **file**, not a directory.
- Never run commands that change the cluster without the user's explicit confirmation. `talosctl reboot` is blocked for Claude by the permission settings; the user runs it. Tasks 1 to 10 use only read-only `talosctl`/`kubectl` commands.
- Never write the private cluster domain literally into any file; it only exists as the environment variable `TALHELPER_CLUSTERDOMAIN`.
- Branches use the `feat/`, `fix/`, `chore/`, `docs/` prefixes; never push to `main`; each PR is opened right after its last commit.

## Review Focus

The spec implies these failure modes, which no happy-path test exercises; each has a test or a verification step in the task that owns the code:

1. A `.yaml.tpl` patch whose variable is **unset** silently renders as an empty value (Task 4 test: the render fails instead).
2. A node added to `nodes.yaml` whose rendered file is **not git-ignored** and gets committed with secrets (Task 6: the ignore file becomes a `home-*.yaml` glob, verified with `git check-ignore`).
3. A node with an **unknown `type`** silently gets no role layer (Task 2 test: `check-patches.sh` rejects it).
4. A **stale or mismatched `talosctl` client** renders with the wrong machinery (Task 6: a precondition on `generate`, verified by a negative run with a wrong version).
5. A **temporary directory holding the secrets bundle** left behind after a successful or a failed render (Task 4 tests, using a private `TMPDIR`).

## Prerequisites (check once before Task 1)

- [ ] **Step 1: Tools**

```bash
bash --version | head -1            # 4.x or newer
yq --version                        # must say mikefarah/yq version v4...
jq --version
envsubst --version | head -1
talosctl version --client --short   # must print: Talos v1.14.2 (same as TALOS_VERSION in .taskfiles/talos/Taskfile.yaml)
```

If `talosctl` is older, run `task talos:install` (it needs sudo; ask the user first).

- [ ] **Step 2: Environment**

```bash
test -n "$TALHELPER_OSCERT" && echo "secrets loaded" || echo "load .envrc first (direnv allow)"
git status -sb | head -1            # clean working tree on a feature branch, never on main
```

- [ ] **Step 3: Branch for the first PR**

```bash
git fetch origin && git switch -c feat/talos-layers-pipeline origin/main
```

---

## File Structure

New, under `provision/talos/`:

| Path | Responsibility |
|---|---|
| `scripts/lib.sh` | Shared helpers and constants (node lookup, merge-order file list, header and touch parsing, contract pin, variable allowlist, expected version). Sourced, never executed. |
| `scripts/normalize.sh` | Canonical form of a multi-document config, for comparison. |
| `scripts/mask.sh` | Hides secret values in text shown to a person. |
| `scripts/expected-version.sh` | Talos version a node should run, from its install image tag. |
| `scripts/check-patches.sh` | Enforces the patch conventions. |
| `scripts/render.sh` | Renders one node: gen config base plus the layers. |
| `scripts/parity.sh` | Compares two directories of rendered configs (normalized, masked). |
| `scripts/explain.sh` | Lists what is configured per node, from the headers. |
| `scripts/config-map.sh` | Generates (and checks) `docs/src/talos/config-map.md`. |
| `scripts/diff-live.sh` | Repo vs live config and running version, masked. |
| `tests/lib.sh`, `tests/run.sh`, `tests/test_*.sh` | Minimal shell test harness and tests. |
| `patches/**` | The configuration itself (39 files, Task 3). |
| `secrets.yaml.tpl` | Bundle template (moved from `templates/talosctl-secrets.yaml`). |

Changed: `.taskfiles/talos/Taskfile.yaml`, `provision/talos/README.md`, `provision/talos/clusterconfig/.gitignore`, `.github/linters/.prettierignore`, three skills, a few path references. Removed in Task 6: `provision/talos/templates/`, `provision/talos/nodes/`. Added: `docs/src/talos/config-map.md`, `.github/workflows/talos-config.yaml`.

PR plan: Tasks 1 to 5 (PR A, the new pipeline beside the old one and the parity gate), Task 6 (PR B, the switch), Tasks 7 to 10 (PR C, tooling), Task 11 (PR D, first migration).

---

## Task 1: Test harness, shared library, normalize and mask

**Files:**

- Create: `provision/talos/tests/lib.sh`, `provision/talos/tests/run.sh`
- Create: `provision/talos/tests/test_normalize_mask.sh`, `provision/talos/tests/test_lib.sh`
- Create: `provision/talos/scripts/lib.sh`, `scripts/normalize.sh`, `scripts/mask.sh`, `scripts/expected-version.sh` (all under `provision/talos/`)

**Interfaces:**

- Produces (`scripts/lib.sh`, sourced): variables `TALOS_DIR`, `PATCHES_DIR`, `NODES_FILE`, `TALOS_CONTRACT`, `CLUSTER_NAME`, `TPL_VARS`; functions `die <msg>`, `node_field <node> <field>`, `node_names`, `patch_dirs <node>`, `patch_files <node>`, `header_value <file> <Key>`, `touches <file>`, `expected_version <rendered-config>`.
- Produces: `normalize.sh <config>` (canonical YAML on stdout), `mask.sh` (stdin to stdout), `expected-version.sh <config>`.
- Produces (`tests/lib.sh`): `pass`, `fail`, `assert_eq expected actual name`, `assert_contains haystack needle name`, `assert_not_contains`, `assert_ok name cmd...`, `assert_fails name cmd...`, `finish`.

- [ ] **Step 1: Create the test harness**

`provision/talos/tests/lib.sh`

```bash
#!/usr/bin/env bash
# Minimal test helpers. Source from a test file, call finish at the end.
FAILS=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); printf '  ok   %s\n' "$1"; }
fail() {
  TESTS=$((TESTS + 1)); FAILS=$((FAILS + 1))
  printf '  FAIL %s\n' "$1"
  [ -z "${2:-}" ] || printf '       %s\n' "$2"
}
assert_eq() { # expected actual name
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$1], got [$2]"; fi
}
assert_contains() { # haystack needle name
  case "$1" in *"$2"*) pass "$3" ;; *) fail "$3" "[$2] not found in [$1]" ;; esac
}
assert_not_contains() { # haystack needle name
  case "$1" in *"$2"*) fail "$3" "[$2] found in [$1]" ;; *) pass "$3" ;; esac
}
assert_ok() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}
assert_fails() { # name command...
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}
finish() {
  printf '%s tests, %s failed\n' "$TESTS" "$FAILS"
  [ "$FAILS" -eq 0 ]
}
```

`provision/talos/tests/run.sh`

```bash
#!/usr/bin/env bash
# Run every tests/test_*.sh. Needs yq (mikefarah v4), jq and talosctl on PATH.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
for tool in yq jq talosctl envsubst; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 2; }
done
status=0
for t in test_*.sh; do
  echo "== $t"
  bash "$t" || status=1
done
exit $status
```

- [ ] **Step 2: Write the failing tests**

`provision/talos/tests/test_normalize_mask.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/normalize.sh and scripts/mask.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- normalize.sh"
cat > "$TMP/a.yaml" <<'YAML'
# a comment
version: v1alpha1
machine:
  type: worker
  sysctls:
    b: "2"
    a: "1"
---
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 1
YAML
cat > "$TMP/b.yaml" <<'YAML'
apiVersion: v1alpha1
kind: EthernetConfig
rings:
  rx: 1
name: eth0
---
machine:
  sysctls:
    a: "1"
    b: "2"
  type: worker
version: v1alpha1
YAML
assert_eq "$("$SCRIPTS/normalize.sh" "$TMP/a.yaml")" "$("$SCRIPTS/normalize.sh" "$TMP/b.yaml")" \
  "same content in a different document/key order and with comments normalizes identically"

sed 's/"2"/"3"/' "$TMP/a.yaml" > "$TMP/c.yaml"
if [ "$("$SCRIPTS/normalize.sh" "$TMP/a.yaml")" != "$("$SCRIPTS/normalize.sh" "$TMP/c.yaml")" ]; then
  pass "a changed value is still visible after normalizing"
else
  fail "a changed value is still visible after normalizing"
fi

echo "-- mask.sh"
masked="$(printf '%s\n' \
  '+    crt: LS0tLS1CRUdJTg==' \
  '-      key: c2VjcmV0' \
  '     token: abc.def' \
  '+  secret: s3cr3t' \
  '+  secretboxEncryptionSecret: xyz' \
  '       MONITOR ups.example 1 user pass secondary' \
  '+    hostname: mc1' | "$SCRIPTS/mask.sh")"
assert_not_contains "$masked" "LS0tLS1CRUdJTg" "certificate value is masked"
assert_not_contains "$masked" "c2VjcmV0" "private key value is masked"
assert_not_contains "$masked" "abc.def" "token value is masked"
assert_not_contains "$masked" "s3cr3t" "secret value is masked"
assert_not_contains "$masked" "xyz" "secretboxEncryptionSecret value is masked"
assert_not_contains "$masked" "ups.example" "nut MONITOR line is masked"
assert_contains "$masked" "+    hostname: mc1" "ordinary lines are untouched"
assert_contains "$masked" "+    crt: <masked>" "the key name and diff marker stay visible"
finish
```

`provision/talos/tests/test_lib.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/lib.sh helpers and scripts/expected-version.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p/all" "$TMP/p/controlplane" "$TMP/p/worker" "$TMP/p/node/mc1"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
  - name: nv1
    ip: 192.168.48.5
    type: worker
YAML
export PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml"
source "$SCRIPTS/lib.sh"

echo "-- header_value"
cat > "$TMP/h.yaml" <<'YAML'
# What:   short
# Why:    first line
#         second line
#         third line
# Nodes:  all nodes
# Apply:  live
machine: {}
YAML
assert_eq "short" "$(header_value "$TMP/h.yaml" What)" "reads a one-line value"
assert_eq "first line second line third line" "$(header_value "$TMP/h.yaml" Why)" "joins continuation lines"
assert_eq "live" "$(header_value "$TMP/h.yaml" Apply)" "reads the last header line"
assert_eq "" "$(header_value "$TMP/h.yaml" Missing)" "an absent key is empty"

echo "-- touches"
cat > "$TMP/t1.yaml" <<'YAML'
machine:
  sysctls: {}
cluster:
  etcd: {}
YAML
cat > "$TMP/t2.yaml" <<'YAML'
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
YAML
cat > "$TMP/t3.yaml" <<'YAML'
apiVersion: v1alpha1
kind: HostnameConfig
$patch: delete
YAML
assert_eq "machine.sysctls cluster.etcd" "$(touches "$TMP/t1.yaml" | tr '\n' ' ' | sed 's/ $//')" "legacy shape lists machine.* and cluster.* keys"
assert_eq "EthernetConfig/eth0" "$(touches "$TMP/t2.yaml")" "a named document lists kind/name"
assert_eq "HostnameConfig" "$(touches "$TMP/t3.yaml")" "an unnamed document lists the kind only"

echo "-- patch_files order"
touch "$TMP/p/all/20-b.yaml" "$TMP/p/all/10-a.yaml" "$TMP/p/controlplane/10-c.yaml" "$TMP/p/worker/10-w.yaml" "$TMP/p/node/mc1/10-n.yaml" "$TMP/p/all/readme.txt"
assert_eq "all/10-a.yaml all/20-b.yaml controlplane/10-c.yaml node/mc1/10-n.yaml" \
  "$(patch_files mc1 | sed "s#$TMP/p/##" | tr '\n' ' ' | sed 's/ $//')" "control plane: all, then controlplane, then node, sorted, yaml only"
assert_eq "all/10-a.yaml all/20-b.yaml worker/10-w.yaml" \
  "$(patch_files nv1 | sed "s#$TMP/p/##" | tr '\n' ' ' | sed 's/ $//')" "worker: all, then worker (a missing node directory is skipped)"

echo "-- expected-version.sh"
cat > "$TMP/r.yaml" <<'YAML'
version: v1alpha1
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
assert_eq "v1.14.0" "$("$SCRIPTS/expected-version.sh" "$TMP/r.yaml")" "prints the leading Talos version of a custom tag"
assert_fails "fails without an argument" "$SCRIPTS/expected-version.sh"
finish
```

- [ ] **Step 3: Run them to see them fail**

```bash
bash provision/talos/tests/test_normalize_mask.sh
```

Expected: several `FAIL` lines (the scripts do not exist yet). The `assert_not_contains` checks pass trivially while the script is missing; the positive assertions are the ones that fail.

- [ ] **Step 4: Create the library and the three scripts**

`provision/talos/scripts/lib.sh`

```bash
#!/usr/bin/env bash
# Shared helpers for the Talos render/explain/diff scripts. Source it, do not execute it.

TALOS_DIR="${TALOS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PATCHES_DIR="${PATCHES_DIR:-$TALOS_DIR/patches}"
NODES_FILE="${NODES_FILE:-$TALOS_DIR/nodes.yaml}"

# Talos config contract that `talosctl gen config` is pinned to. It must match what the live nodes
# run: the 1.14 contract generates a fully multi-document base that cannot be mixed with the
# legacy fields still used here. Bump it deliberately, see README.md.
TALOS_CONTRACT="${TALOS_CONTRACT:-v1.13}"
CLUSTER_NAME="${CLUSTER_NAME:-home}"

# The only variables envsubst may replace, and only inside *.yaml.tpl patches.
TPL_VARS='${TALHELPER_CLUSTERENDPOINTIP} ${TALHELPER_CLUSTERDOMAIN} ${TALHELPER_OIDCCLIENTID} ${TALHELPER_OIDCISSUERURL} ${TALHELPER_UPSMONHOST} ${TALHELPER_UPSMONUSER} ${TALHELPER_UPSMONPASSWD} ${TALOS_VERSION}'

die() { echo "error: $*" >&2; exit 1; }

# node_field <node> <field>: a field from nodes.yaml (empty when the node does not exist)
node_field() {
  yq -r ".nodes[] | select(.name == \"$1\") | .$2" "$NODES_FILE"
}

# node_names: every node name, one per line
node_names() {
  yq -r '.nodes[].name' "$NODES_FILE"
}

# patch_dirs <node>: the layer directories for a node in merge order (only those that exist)
patch_dirs() {
  local node="$1" type
  type="$(node_field "$node" type)"
  [ -n "$type" ] || die "unknown node: $node"
  local d
  for d in "$PATCHES_DIR/all" "$PATCHES_DIR/$type" "$PATCHES_DIR/node/$node"; do
    [ -d "$d" ] && echo "$d"
  done
  return 0
}

# patch_files <node>: the patch files for a node in merge order, one path per line
patch_files() {
  local d
  while IFS= read -r d; do
    find "$d" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yaml.tpl' \) | LC_ALL=C sort
  done < <(patch_dirs "$1")
}

# header_value <file> <Key>: value of a "# Key: value" header line, continuation lines
# ("#   more text", three or more spaces) joined with single spaces
header_value() {
  awk -v key="$2" '
    BEGIN { pat = "^# " key ":[ ]*" }
    $0 ~ pat { sub(pat, ""); out = $0; found = 1; next }
    found && /^#   [ ]*[^ ]/ { sub(/^#[ ]+/, ""); out = out " " $0; next }
    found { exit }
    END { if (found) print out }
  ' "$1"
}

# touches <file>: what a patch changes, one item per line: Kind/name for a document,
# machine.<key> or cluster.<key> for the legacy v1alpha1 shape
touches() {
  yq -N 'select(.kind != null) | (.kind + "/" + (.name // "")) | sub("/$"; "")' "$1"
  yq -N 'select(.kind == null) | ((.machine // {} | keys | map("machine." + .)) + (.cluster // {} | keys | map("cluster." + .))) | .[]' "$1"
}

# expected_version <rendered-config>: the Talos version a node should run, read from the tag of its
# install image ("v1.14.2" for a Factory image, "v1.14.0" for v1.14.0-6.18.48-nvgpu... custom tags)
expected_version() {
  local image tag
  image="$(yq -N 'select(.machine != null) | .machine.install.image' "$1")"
  tag="${image##*:}"
  echo "${tag%%-*}"
}
```

`provision/talos/scripts/normalize.sh`

```bash
#!/usr/bin/env bash
# normalize.sh <machineconfig.yaml>
# Canonical form of a (multi-document) machine config on stdout: documents sorted by kind/name, keys
# sorted at every depth, comments dropped. Values are kept as they are, so two configs normalize
# equal only if they are semantically equal. Pipe diffs through mask.sh before showing them.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: normalize.sh <machineconfig.yaml>" >&2; exit 2; }
yq ea -o=json '[.]' "$1" \
  | jq -S 'map(select(. != null)) | sort_by((.kind // "v1alpha1") + "/" + (.name // ""))' \
  | yq -P -o=yaml
```

`provision/talos/scripts/mask.sh`

```bash
#!/usr/bin/env bash
# mask.sh: stdin to stdout, hides the values of secret-looking keys and the nut MONITOR line.
# Display filter only: it never changes what is compared, just what is shown.
sed -E '
  s/^([ +-]*(- )?)(crt|key|token|secret|secretboxEncryptionSecret|aescbcEncryptionSecret|password|id|bootstraptoken):[ ]*.*/\1\3: <masked>/
  s/MONITOR .*/MONITOR <masked>/
'
```

`provision/talos/scripts/expected-version.sh`

```bash
#!/usr/bin/env bash
# expected-version.sh <rendered-config>: the Talos version a node should run, from its install image tag.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 1 ] || { echo "usage: expected-version.sh <rendered-config>" >&2; exit 2; }
expected_version "$1"
```

```bash
chmod +x provision/talos/scripts/*.sh provision/talos/tests/run.sh
```

- [ ] **Step 5: Run the tests to see them pass**

```bash
bash provision/talos/tests/test_normalize_mask.sh   # Expected: 10 tests, 0 failed
bash provision/talos/tests/test_lib.sh              # Expected: 11 tests, 0 failed
```

- [ ] **Step 6: Commit**

```bash
git add provision/talos/scripts provision/talos/tests
git commit -m "feat(talos): shell test harness, shared library, config normalize and secret mask"
```

---

## Task 2: check-patches.sh

**Files:**

- Create: `provision/talos/tests/test_check_patches.sh`, `provision/talos/scripts/check-patches.sh`

**Interfaces:**

- Consumes: `lib.sh` (`PATCHES_DIR`, `NODES_FILE`, `TPL_VARS`, `node_names`, `header_value`).
- Produces: `check-patches.sh` (no arguments). Prints every problem to stderr, exits 1 on any, prints `check-patches: ok` otherwise. Review Focus 3: node types other than `controlplane`/`worker` are rejected.

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_check_patches.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/check-patches.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkfix() { # fresh fixture tree with one valid file per layer
  rm -rf "$TMP/p"; mkdir -p "$TMP/p/all" "$TMP/p/controlplane" "$TMP/p/worker" "$TMP/p/node/mc1"
  cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
  - name: nv1
    ip: 192.168.48.5
    type: worker
YAML
  cat > "$TMP/p/all/10-time.yaml" <<'YAML'
# What:   NTP servers
# Why:    etcd needs time sync
# Nodes:  all nodes
# Apply:  live
machine:
  time:
    disabled: false
YAML
  cat > "$TMP/p/controlplane/10-etcd.yaml" <<'YAML'
# What:   etcd metrics
# Why:    prometheus
#         continues on a second line
# Nodes:  control plane
# Apply:  reboot (etcd reads its arguments at start)
cluster:
  etcd:
    extraArgs:
      listen-metrics-urls: http://127.0.0.1:2381
YAML
  cat > "$TMP/p/worker/10-taint.yaml" <<'YAML'
# What:   taint
# Why:    keep pods off
# Nodes:  workers
# Apply:  install-only
machine:
  nodeTaints:
    a: b:NoSchedule
YAML
  cat > "$TMP/p/node/mc1/10-net.yaml.tpl" <<'YAML'
# What:   network
# Why:    static
# Nodes:  mc1
# Apply:  live
machine:
  certSANs:
    - ${TALHELPER_CLUSTERDOMAIN}
YAML
}
check() { PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/check-patches.sh"; }

echo "-- valid tree"
mkfix; assert_ok "a valid tree passes" check

echo "-- header rules"
mkfix; sed -i '/^# Why:/d' "$TMP/p/all/10-time.yaml"
assert_fails "a missing Why line fails" check
mkfix; sed -i 's/^# Apply:  live/# Apply:  sometimes/' "$TMP/p/all/10-time.yaml"
assert_fails "an unknown Apply value fails" check
mkfix; sed -i 's/^# Nodes:  all nodes/# Nodes:  workers/' "$TMP/p/all/10-time.yaml"
assert_fails "a Nodes line that does not match the directory fails" check
mkfix; sed -i 's/^# Nodes:  mc1/# Nodes:  mc2/' "$TMP/p/node/mc1/10-net.yaml.tpl"
assert_fails "a node directory with another node's name in Nodes fails" check

echo "-- file naming and layout"
mkfix; mv "$TMP/p/all/10-time.yaml" "$TMP/p/all/time.yaml"
assert_fails "a file without a NN- prefix fails" check
mkfix; mkdir -p "$TMP/p/node/ghost"; cp "$TMP/p/node/mc1/10-net.yaml.tpl" "$TMP/p/node/ghost/10-net.yaml.tpl"
assert_fails "a node directory that is not in nodes.yaml fails" check
mkfix; cat >> "$TMP/p/all/10-time.yaml" <<'YAML'
---
machine:
  type: worker
YAML
assert_fails "two documents in one file fail" check

echo "-- node types"
mkfix; sed -i 's/type: worker/type: master/' "$TMP/nodes.yaml"
assert_fails "an unknown node type in nodes.yaml fails" check

echo "-- secrets and variables"
mkfix; sed -i 's/disabled: false/disabled: ${TALHELPER_CLUSTERDOMAIN}/' "$TMP/p/all/10-time.yaml"
assert_fails "a variable in a plain .yaml file fails" check
mkfix; sed -i 's/TALHELPER_CLUSTERDOMAIN/SOMETHING_ELSE/' "$TMP/p/node/mc1/10-net.yaml.tpl"
assert_fails "a variable outside the allowlist in a .tpl file fails" check
mkfix; printf '\n# a stray ${NOT_ALLOWED} in a comment\n' >> "$TMP/p/node/mc1/10-net.yaml.tpl"
assert_fails "a variable outside the allowlist in a comment of a .tpl file fails" check
finish
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash provision/talos/tests/test_check_patches.sh
```

Expected: `FAIL a valid tree passes` (the "must fail" cases pass trivially while the script is missing).

- [ ] **Step 3: Implement the script**

`provision/talos/scripts/check-patches.sh`

```bash
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

  case "$rel" in
    node/*/*) n="${rel#node/}"; n="${n%%/*}"; grep -qx "$n" <<<"$nodes" || err "$rel" "node directory '$n' is not in nodes.yaml" ;;
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
```

```bash
chmod +x provision/talos/scripts/check-patches.sh
```

- [ ] **Step 4: Run the test to see it pass**

```bash
bash provision/talos/tests/test_check_patches.sh   # Expected: 12 tests, 0 failed
```

- [ ] **Step 5: Commit**

```bash
git add provision/talos/scripts/check-patches.sh provision/talos/tests/test_check_patches.sh
git commit -m "feat(talos): check-patches enforces the patch file conventions"
```

---

## Task 3: The layer files

**Files:**

- Create: 39 files under `provision/talos/patches/` (listed below)
- Create: `provision/talos/secrets.yaml.tpl` (a **copy** of `templates/talosctl-secrets.yaml`; the old file stays until Task 6 because the old pipeline still uses it)

**Interfaces:**

- Consumes: `check-patches.sh` (Task 2), the conventions in Global Constraints.
- Produces: the complete configuration of the four nodes as layers. Content equals what the old `templates/*` and `nodes/*` produce today; Task 5 proves it. nv1's custom installer image lives in `node/nv1/20-install-image.yaml`.

Each file below is the old template content split by concern, with the header added. Comments that explain a decision stay in the file body. Create each file with exactly this content.

- [ ] **Step 1: Create the files**

```bash
mkdir -p provision/talos/patches/{all,controlplane,worker,node/mc1,node/mc2,node/mc3,node/nv1}
cp provision/talos/templates/talosctl-secrets.yaml provision/talos/secrets.yaml.tpl
```

`provision/talos/patches/all/05-hostname-config-delete.yaml`

```yaml
# What:   Remove the HostnameConfig document that talosctl gen config adds
# Why:    Hostnames are set statically per node (node/<name>/10-network.yaml); the generated
#         "auto: stable" document would conflict with them
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: HostnameConfig
$patch: delete
```

`provision/talos/patches/all/10-api-sans.yaml.tpl`

```yaml
# What:   Names and IPs the node API certificate is valid for: the control-plane VIP, the cluster domain, loopback
# Why:    talosctl and kubectl connect through the VIP and the public cluster name
# Nodes:  all nodes
# Apply:  live
machine:
  certSANs:
    - ${TALHELPER_CLUSTERENDPOINTIP}
    - ${TALHELPER_CLUSTERDOMAIN}
    - 127.0.0.1
```

`provision/talos/patches/all/20-nameservers.yaml`

```yaml
# What:   DNS servers for the node itself: the two in-cluster AdGuard instances first, the router last
# Why:    Internal-only names (S3, QNAP, the OIDC issuer) exist only in AdGuard; the router serves public names only
# Nodes:  all nodes
# Apply:  live
machine:
  network:
    # Host-originated traffic reaches both LB addresses from every node (externalTrafficPolicy: Local
    # does not apply to it), including nodes that run no AdGuard pod. The UCG-Max (public names only)
    # is the fallback if both AdGuard instances are down.
    nameservers:
      - 192.168.48.25
      - 192.168.48.31
      - 192.168.48.254
```

`provision/talos/patches/all/25-kubelet.yaml`

```yaml
# What:   Kubelet: rotate serving certificates, default seccomp profile, no static manifests directory, pinned cluster DNS
# Why:    kubelet-csr-approver signs the rotated serving certificates; CoreDNS is self-provisioned
#         (cluster.coreDNS.disabled), so the kube-dns Service address is pinned
# Nodes:  all nodes
# Apply:  live
machine:
  kubelet:
    extraArgs:
      rotate-server-certificates: "true"
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true
    clusterDNS:
      - 10.96.0.10
```

`provision/talos/patches/all/30-install.yaml`

```yaml
# What:   Install target: the NVMe system disk, no wipe, keep the UKI kernel command line
# Why:    Every node boots from /dev/nvme0n1; the install image itself is set per role and per node
# Nodes:  all nodes
# Apply:  install-only
machine:
  install:
    disk: /dev/nvme0n1
    wipe: false
    grubUseUKICmdline: true
```

`provision/talos/patches/all/40-cri-customization.yaml`

```yaml
# What:   containerd: unprivileged ports and ICMP allowed in pods, unpacked image layers kept
# Why:    Pods may bind ports below 1024 and send ICMP without extra capabilities; discard_unpacked_layers stays false
# Nodes:  all nodes
# Apply:  reboot (containerd reads its config files only at start; the CRICustomizationConfig document restarts it itself)
machine:
  files:
    - content: |
        [plugins]
          [plugins."io.containerd.grpc.v1.cri"]
            enable_unprivileged_ports = true
            enable_unprivileged_icmp = true
        [plugins."io.containerd.grpc.v1.cri".containerd]
          discard_unpacked_layers = false
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          discard_unpacked_layers = false
      permissions: 0o0
      path: /etc/cri/conf.d/20-customization.part
      op: create
```

`provision/talos/patches/all/50-time.yaml`

```yaml
# What:   NTP servers, by IP
# Why:    etcd refuses to start until time syncs, so time must not depend on DNS (the nameserver is the router) or on any LAN host
# Nodes:  all nodes
# Apply:  live
machine:
  time:
    disabled: false
    # Public anycast NTP. The UCG-Max does not serve NTP on any interface.
    servers:
      - 162.159.200.123
      - 162.159.200.1
      - 216.239.35.0
      - 216.239.35.4
```

`provision/talos/patches/all/60-features.yaml`

```yaml
# What:   Disk quota support, KubePrism (local API load balancer on :7445), host DNS with member-name resolution
# Why:    Platform features the cluster relies on: XFS project quotas, API access that does not depend on the VIP, member names in host DNS
# Nodes:  all nodes
# Apply:  live
machine:
  features:
    diskQuotaSupport: true
    kubePrism:
      enabled: true
      port: 7445
    hostDNS:
      enabled: true
      forwardKubeDNSToHost: false
      resolveMemberNames: true
```

`provision/talos/patches/all/70-node-labels.yaml`

```yaml
# What:   Topology labels region=home and zone=m
# Why:    Topology labels used for scheduling and spread constraints
# Nodes:  all nodes
# Apply:  live
machine:
  nodeLabels:
    topology.kubernetes.io/region: home
    topology.kubernetes.io/zone: m
```

`provision/talos/patches/all/80-cluster-network.yaml`

```yaml
# What:   No Talos-managed CNI, cluster DNS domain, pod and service CIDRs
# Why:    Cilium is installed by ArgoCD, so Talos must not install a CNI; the CIDRs were fixed at cluster creation
# Nodes:  all nodes
# Apply:  live (never change the CIDRs of a running cluster)
cluster:
  network:
    cni:
      name: none
    dnsDomain: cluster.local
    podSubnets:
      - 10.244.0.0/16
    serviceSubnets:
      - 10.96.0.0/12
```

`provision/talos/patches/all/85-coredns-disabled.yaml`

```yaml
# What:   Talos does not deploy CoreDNS
# Why:    CoreDNS is managed as an ArgoCD app (cluster/apps/system/coredns)
# Nodes:  all nodes
# Apply:  live
cluster:
  coreDNS:
    disabled: true
```

`provision/talos/patches/all/90-discovery.yaml`

```yaml
# What:   Cluster member discovery through the discovery service only; the Kubernetes registry is off
# Why:    Members discover each other without depending on the Kubernetes API
# Nodes:  all nodes
# Apply:  live
cluster:
  discovery:
    enabled: true
    registries:
      kubernetes:
        disabled: true
      service: {}
```

`provision/talos/patches/all/98-nut-client.yaml.tpl`

```yaml
# What:   NUT client: watch the UPS and power the node off when it reports low battery
# Why:    Clean shutdown on power loss; the NUT server runs on the QNAP (docs/src/general/ups.md)
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: nut-client
configFiles:
  - content: |
      MONITOR ${TALHELPER_UPSMONHOST} 1 ${TALHELPER_UPSMONUSER} ${TALHELPER_UPSMONPASSWD} secondary
      SHUTDOWNCMD "/sbin/poweroff"
    mountPath: /usr/local/etc/nut/upsmon.conf
```

`provision/talos/patches/controlplane/05-install-image.yaml.tpl`

```yaml
# What:   Installer image: Image Factory schematic with the i915, intel-ucode and nut-client extensions, at the Talos version
# Why:    Control-plane nodes are Lenovo M720q with Intel GPUs and a UPS; the version tag follows TALOS_VERSION
# Nodes:  control plane
# Apply:  install-only
machine:
  install:
    image: factory.talos.dev/metal-installer/a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0:${TALOS_VERSION}
```

`provision/talos/patches/controlplane/10-etcd-metrics.yaml`

```yaml
# What:   Serve etcd /metrics over plain HTTP on 127.0.0.1:2381
# Why:    Since Talos 1.14 the default /metrics is on :2383 behind client mTLS; kube-system/metrics-proxy
#         (haproxy on <node-ip>:2381) forwards to this loopback listener for Prometheus
# Nodes:  control plane
# Apply:  reboot (etcd reads its arguments only at start; applying does not restart it and talosctl refuses to restart etcd)
cluster:
  etcd:
    extraArgs:
      listen-metrics-urls: http://127.0.0.1:2381
```

`provision/talos/patches/controlplane/20-apiserver-oidc.yaml.tpl`

```yaml
# What:   kube-apiserver OIDC login (Keycloak) and the extra names its certificate is valid for
# Why:    kubectl users authenticate through Keycloak; the SANs let clients use the VIP and the cluster domain
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
cluster:
  apiServer:
    extraArgs:
      oidc-client-id: ${TALHELPER_OIDCCLIENTID}
      oidc-groups-claim: groups
      oidc-groups-prefix: "oidc:"
      oidc-issuer-url: ${TALHELPER_OIDCISSUERURL}
      oidc-username-claim: email
      oidc-username-prefix: "oidc:"
    certSANs:
      - ${TALHELPER_CLUSTERENDPOINTIP}
      - ${TALHELPER_CLUSTERDOMAIN}
      - 127.0.0.1
```

`provision/talos/patches/controlplane/21-apiserver-pod-security.yaml`

```yaml
# What:   PodSecurity admission: enforce baseline, audit and warn on restricted
# Why:    Baseline blocks the dangerous pod settings without breaking existing workloads; restricted is reported only.
#         kube-system is exempt through the generated base configuration (do not list it again, lists append)
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
cluster:
  apiServer:
    admissionControl:
      - name: PodSecurity
        configuration:
          apiVersion: pod-security.admission.config.k8s.io/v1alpha1
          defaults:
            audit: restricted
            audit-version: latest
            enforce: baseline
            enforce-version: latest
            warn: restricted
            warn-version: latest
          exemptions:
            runtimeClasses: []
            usernames: []
          kind: PodSecurityConfiguration
```

`provision/talos/patches/controlplane/22-apiserver-audit-policy.yaml`

```yaml
# What:   API audit log: every request at Metadata level
# Why:    Who did what is recorded without storing request or response bodies
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
cluster:
  apiServer:
    auditPolicy:
      apiVersion: audit.k8s.io/v1
      kind: Policy
      rules:
        - level: Metadata
```

`provision/talos/patches/controlplane/30-controller-manager.yaml`

```yaml
# What:   kube-controller-manager listens on all addresses
# Why:    Exposes the metrics endpoint so Prometheus can scrape it
# Nodes:  control plane
# Apply:  live (the static pod restarts)
cluster:
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
```

`provision/talos/patches/controlplane/31-scheduler.yaml`

```yaml
# What:   kube-scheduler listens on all addresses
# Why:    Exposes the metrics endpoint so Prometheus can scrape it
# Nodes:  control plane
# Apply:  live (the static pod restarts)
cluster:
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
```

`provision/talos/patches/controlplane/32-kube-proxy-disabled.yaml`

```yaml
# What:   kube-proxy is not deployed
# Why:    Cilium replaces kube-proxy; bind-address is kept as configured
# Nodes:  control plane
# Apply:  live
cluster:
  proxy:
    disabled: true
    extraArgs:
      bind-address: 0.0.0.0
```

`provision/talos/patches/controlplane/40-talos-api-access.yaml`

```yaml
# What:   Let the talos-backup namespace call the Talos API with the os:etcd:backup role
# Why:    talos-backup takes etcd snapshots through the Kubernetes-to-Talos API bridge
# Nodes:  control plane
# Apply:  live
machine:
  features:
    kubernetesTalosAPIAccess:
      enabled: true
      allowedRoles:
        - os:etcd:backup
      allowedKubernetesNamespaces:
        - talos-backup
```

`provision/talos/patches/controlplane/50-udev-render-device.yaml`

```yaml
# What:   GPU render nodes (/dev/dri/renderD*) belong to group 44 and are group read-write
# Why:    Intel GPU workloads (intel-device-plugins) need access to the render node
# Nodes:  control plane
# Apply:  live
machine:
  udev:
    rules:
      - SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="44", MODE="0660"
```

`provision/talos/patches/controlplane/60-node-labels.yaml`

```yaml
# What:   Label daytona-sandbox-c=true on the control-plane nodes
# Why:    Scheduling label from the Daytona installation (docs/superpowers/archive/2026-06-02-daytona-installation.md)
# Nodes:  control plane
# Apply:  live
machine:
  nodeLabels:
    daytona-sandbox-c: "true"
```

`provision/talos/patches/controlplane/70-sysctls.yaml`

```yaml
# What:   inotify limits, 64 MiB socket buffers and 1024 hugepages
# Why:    Controllers and exporters hold many inotify watches; large socket buffers for network throughput;
#         hugepages for workloads that request them
# Nodes:  control plane
# Apply:  live
machine:
  sysctls:
    fs.inotify.max_user_instances: "8192"
    fs.inotify.max_user_watches: "1048576"
    net.core.rmem_max: "67108864"
    net.core.wmem_max: "67108864"
    vm.nr_hugepages: "1024"
```

`provision/talos/patches/controlplane/80-schedule-on-control-plane.yaml`

```yaml
# What:   Ordinary pods may run on the control-plane nodes
# Why:    There are no dedicated workers besides nv1 (a GPU node)
# Nodes:  control plane
# Apply:  live
cluster:
  allowSchedulingOnMasters: true
```

`provision/talos/patches/controlplane/85-delete-lb-exclusion-label.yaml`

```yaml
# What:   Remove the node.kubernetes.io/exclude-from-external-load-balancers label that talosctl gen config adds to control planes
# Why:    Keeps parity with the configuration the nodes already run (they never had the label). Delete this file to adopt
#         the Talos default, after checking LoadBalancer behaviour
# Nodes:  control plane
# Apply:  live
machine:
  nodeLabels:
    node.kubernetes.io/exclude-from-external-load-balancers:
      $patch: delete
```

`provision/talos/patches/controlplane/90-ethernet-rings.yaml`

```yaml
# What:   NIC ring buffers rx/tx 4096 on eth0
# Why:    Avoids packet drops under load (see the talos-ethernet-config skill)
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
  tx: 4096
```

`provision/talos/patches/worker/05-install-image.yaml.tpl`

```yaml
# What:   Installer image: Image Factory schematic with kernel arguments only (no extensions), at the Talos version
# Why:    Default worker image; nv1 overrides it with its custom installer (node/nv1/20-install-image.yaml)
# Nodes:  workers
# Apply:  install-only
machine:
  install:
    image: factory.talos.dev/metal-installer/185266ddb5b9bb403289377302af1fd44575fe7f2864db5a7a96858837ccbcba:${TALOS_VERSION}
```

`provision/talos/patches/worker/20-sysctls.yaml`

```yaml
# What:   BPF JIT hardening
# Why:    Hardening setting carried over from the original worker template; not set on control planes
# Nodes:  workers
# Apply:  live
machine:
  sysctls:
    net.core.bpf_jit_harden: "1"
```

`provision/talos/patches/worker/30-node-taints.yaml`

```yaml
# What:   Taint workers nvidia.com/gpu=present:NoSchedule
# Why:    Keeps ordinary pods off the GPU node (nv1 shares 16 GB between CPU and GPU); GPU pods tolerate the taint
# Nodes:  workers
# Apply:  live (changing an existing taint needs a manual kubectl taint: NodeRestriction blocks the kubelet from updating it)
machine:
  nodeTaints:
    # value:effect, parsed by Talos labels.ParseTaint (strings.Cut on ":")
    nvidia.com/gpu: present:NoSchedule
```

`provision/talos/patches/node/mc1/10-network.yaml`

```yaml
# What:   mc1 identity on the network: hostname, static address, default route and the control-plane VIP 192.168.48.1
# Why:    DHCP is disabled on VLAN 48, so every node address is static; the VIP is shared by the three control planes
# Nodes:  mc1
# Apply:  live (a wrong address or route can make the node unreachable)
machine:
  network:
    hostname: mc1
    interfaces:
      - interface: eth0
        addresses:
          - 192.168.48.2/24
        mtu: 1500
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.48.254
        vip:
          ip: 192.168.48.1
```

`provision/talos/patches/node/mc2/10-network.yaml`

```yaml
# What:   mc2 identity on the network: hostname, static address, default route and the control-plane VIP 192.168.48.1
# Why:    DHCP is disabled on VLAN 48, so every node address is static; the VIP is shared by the three control planes
# Nodes:  mc2
# Apply:  live (a wrong address or route can make the node unreachable)
machine:
  network:
    hostname: mc2
    interfaces:
      - interface: eth0
        addresses:
          - 192.168.48.3/24
        mtu: 1500
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.48.254
        vip:
          ip: 192.168.48.1
```

`provision/talos/patches/node/mc3/10-network.yaml`

```yaml
# What:   mc3 identity on the network: hostname, static address, default route and the control-plane VIP 192.168.48.1
# Why:    DHCP is disabled on VLAN 48, so every node address is static; the VIP is shared by the three control planes
# Nodes:  mc3
# Apply:  live (a wrong address or route can make the node unreachable)
machine:
  network:
    hostname: mc3
    interfaces:
      - interface: eth0
        addresses:
          - 192.168.48.4/24
        mtu: 1500
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.48.254
        vip:
          ip: 192.168.48.1
```

`provision/talos/patches/node/nv1/10-network.yaml`

```yaml
# What:   nv1 identity on the network: hostname, static address on enP8p1s0, default route, DHCP off
# Why:    Talos runs DHCP on every linked interface and a static address does not turn it off; see the comment below
# Nodes:  nv1
# Apply:  live (a wrong address or route can make the node unreachable; nv1 has no easy console)
machine:
  network:
    hostname: nv1
    interfaces:
      - interface: enP8p1s0
        # Talos runs DHCP on every linked interface by default; a static address
        # does not turn it off. Without this, nv1 also leased 192.168.48.210, and
        # lease churn flapped .5, restarted the kubelet, and dropped the GPU
        # device-plugin registration (nvidia.com/gpu: 0).
        dhcp: false
        addresses:
          - 192.168.48.5/24
        mtu: 1500
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.48.254
```

`provision/talos/patches/node/nv1/20-install-image.yaml`

```yaml
# What:   Custom installer image (OE4T nvgpu kernel modules for the Jetson Orin NX)
# Why:    The Jetson GPU needs the matching kernel and out-of-tree modules, built by schwankner/talos-jetson-orin.
#         The tag is <talos>-<kernel>-nvgpu<version>; the kernel module ABI must match the image (see provision/talos/README.md)
# Nodes:  nv1
# Apply:  install-only
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
```

`provision/talos/patches/node/nv1/30-kernel-modules.yaml`

```yaml
# What:   Kernel modules for the Jetson iGPU: host1x stack, tegra_drm, nvmap, nvgpu and the frequency governor
# Why:    The OE4T driver stack creates /dev/dri/renderD128 and provides CUDA; the modules are ABI-bound to the custom installer's kernel
# Nodes:  nv1
# Apply:  reboot (module parameters and removals only apply when a module is loaded)
machine:
  kernel:
    modules:
      # OE4T host1x stack — prerequisite for all GPU modules
      - name: host1x
      - name: host1x_fence
      - name: host1x_nvhost
      # OE4T DRM stack — creates /dev/dri/renderD128, required for CUDA
      - name: tegra_drm
      # GPU memory + bandwidth
      - name: nvmap
      - name: mc_utils
      # Main CUDA driver (GA10B / Ampere)
      - name: nvgpu
      # GPU frequency scaling governor
      - name: governor_pod_scaling
```

`provision/talos/patches/node/nv1/40-node-labels.yaml`

```yaml
# What:   Labels accelerator=jetson-orin and nvidia.com/gpu.type=igpu
# Why:    GPU workloads and the device plugin select the Jetson node by these labels
# Nodes:  nv1
# Apply:  live
machine:
  nodeLabels:
    accelerator: jetson-orin
    nvidia.com/gpu.type: igpu
```

`provision/talos/patches/node/nv1/50-containerd-config.yaml`

```yaml
# What:   Whole-file replacement of /etc/cri/containerd.toml with CDI enabled
# Why:    Talos builds containerd with CDI disabled and op: overwrite needs the file to exist, so the full file is carried here.
#         Re-diff against the live file on every Talos upgrade (containerd changes between versions)
# Nodes:  nv1
# Apply:  reboot (containerd reads its config file only at start)
machine:
  files:
    # Talos builds containerd with CDI disabled, and op:overwrite requires the
    # file to pre-exist — so CDI is enabled inline here rather than as a new
    # conf.d drop-in. Content below is nv1's current containerd.toml verbatim
    # plus the CDI block. Re-diff against the live file on every Talos upgrade.
    - path: /etc/cri/containerd.toml
      op: overwrite
      permissions: 0o644
      content: |
        version = 3

        disabled_plugins = [
            "io.containerd.differ.v1.erofs",
            "io.containerd.internal.v1.tracing",
            "io.containerd.snapshotter.v1.blockfile",
            "io.containerd.snapshotter.v1.erofs",
            "io.containerd.ttrpc.v1.otelttrpc",
            "io.containerd.tracing.processor.v1.otlp",
        ]

        imports = [
            "/etc/cri/conf.d/cri.toml",
        ]

        [debug]
        level = "info"
        format = "json"

        [plugins."io.containerd.cri.v1.runtime"]
          enable_cdi = true
          cdi_spec_dirs = ["/var/run/cdi"]
```

- [ ] **Step 2: Check conventions and lint**

```bash
provision/talos/scripts/check-patches.sh                              # Expected: check-patches: ok
yamllint -c .github/linters/.yamllint.yaml provision/talos/patches    # Expected: no output
prettier --ignore-unknown --config .github/linters/.prettierrc.yaml --check provision/talos/patches
# Expected: All matched files use Prettier code style!
```

- [ ] **Step 3: Commit**

```bash
git add provision/talos/patches provision/talos/secrets.yaml.tpl
git commit -m "feat(talos): the node configuration as layered, self-describing patch files"
```

---

## Task 4: render.sh

**Files:**

- Create: `provision/talos/tests/test_render.sh`, `provision/talos/scripts/render.sh`

**Interfaces:**

- Consumes: `lib.sh` (`patch_files`, `node_field`, `TALOS_CONTRACT`, `CLUSTER_NAME`, `TPL_VARS`), the patches (Task 3), `secrets.yaml.tpl`.
- Produces: `render.sh <node> [out-file]`. Default output `provision/talos/clusterconfig/home-<node>.yaml`, mode 600. Needs `KUBERNETES_VERSION`, `TALOS_VERSION`, `TALHELPER_CLUSTERDOMAIN`; secrets from `SECRETS_FILE` (a talosctl secrets bundle; tests and CI use a throwaway one) or from `secrets.yaml.tpl` plus the `TALHELPER_*` variables. Fails when a `.tpl` patch needs an unset variable, and always removes its temporary directory (Review Focus 1 and 5).

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_render.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/render.sh: renders real nodes with a throwaway secrets bundle and dummy values.
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

talosctl gen secrets -o "$TMP/secrets.yaml" >/dev/null 2>&1
export SECRETS_FILE="$TMP/secrets.yaml"
export KUBERNETES_VERSION=v1.35.9 TALOS_VERSION=v1.14.2
export TALHELPER_CLUSTERDOMAIN=cluster.test TALHELPER_CLUSTERENDPOINTIP=192.0.2.1
export TALHELPER_OIDCCLIENTID=oidc-client TALHELPER_OIDCISSUERURL=https://sso.test/realms/x
export TALHELPER_UPSMONHOST=ups.test TALHELPER_UPSMONUSER=upsuser TALHELPER_UPSMONPASSWD=upspass
export SECRET_SHOULD_NOT_LEAK=leaked

render() { "$SCRIPTS/render.sh" "$1" "$TMP/$1.yaml"; }

echo "-- control plane (mc1)"
assert_ok "mc1 renders" render mc1
assert_ok "mc1 output is a valid metal config" talosctl validate --config "$TMP/mc1.yaml" --mode metal
out="$(cat "$TMP/mc1.yaml")"
assert_contains "$out" "kind: EthernetConfig" "control plane gets the EthernetConfig document"
assert_contains "$out" "kind: ExtensionServiceConfig" "every node gets the nut-client document"
assert_contains "$out" "listen-metrics-urls: http://127.0.0.1:2381" "etcd metrics argument is applied"
assert_contains "$out" "oidc-client-id: oidc-client" "template variables are substituted in .tpl patches"
assert_contains "$out" "ups.test 1 upsuser upspass secondary" "the nut-client secrets are substituted"
assert_not_contains "$out" "kind: HostnameConfig" "the generated HostnameConfig document is removed"
assert_not_contains "$out" 'exclude-from-external-load-balancers' "the generated load-balancer exclusion label is removed"
assert_not_contains "$out" '${' "no unexpanded variable is left"
assert_eq "600" "$(stat -c '%a' "$TMP/mc1.yaml")" "the rendered file is readable by the owner only"

echo "-- worker (nv1)"
assert_ok "nv1 renders" render nv1
assert_ok "nv1 output is a valid metal config" talosctl validate --config "$TMP/nv1.yaml" --mode metal
out="$(cat "$TMP/nv1.yaml")"
assert_contains "$out" "ghcr.io/schwankner/custom-installer:" "nv1 uses its custom installer image"
assert_not_contains "$out" "factory.talos.dev/metal-installer" "the role image is overridden by the node patch"
assert_contains "$out" "nvidia.com/gpu: present:NoSchedule" "workers get the GPU taint"
assert_not_contains "$out" "kind: EthernetConfig" "workers do not get the control-plane EthernetConfig"

echo "-- failure modes"
(unset TALHELPER_OIDCISSUERURL; assert_fails "an unset variable used by a .tpl patch fails the render" "$SCRIPTS/render.sh" mc1 "$TMP/unset.yaml")
mkdir -p "$TMP/tmpdir"
TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/clean.yaml" >/dev/null 2>&1
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory (with the secrets bundle) is left behind"
(unset TALHELPER_OIDCISSUERURL; TMPDIR="$TMP/tmpdir" "$SCRIPTS/render.sh" mc1 "$TMP/unset2.yaml" >/dev/null 2>&1 || true)
assert_eq "" "$(ls -A "$TMP/tmpdir")" "no temporary directory is left behind after a failed render either"

echo "-- safety"
out="$(cat "$TMP/mc1.yaml" "$TMP/nv1.yaml")"
assert_not_contains "$out" "leaked" "variables outside the allowlist are never substituted"
assert_fails "an unknown node is rejected" "$SCRIPTS/render.sh" nope "$TMP/x.yaml"
finish
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash provision/talos/tests/test_render.sh
```

Expected: many `FAIL` lines (the script does not exist).

- [ ] **Step 3: Implement the script**

`provision/talos/scripts/render.sh`

```bash
#!/usr/bin/env bash
# render.sh <node> [out-file]
# Render one node's machine config: talosctl gen config base (pinned contract) + the patch layers
# all/, <role>/, node/<name>/ in order. Writes clusterconfig/home-<node>.yaml by default (mode 600).
#
# Needs in the environment: KUBERNETES_VERSION, TALOS_VERSION, TALHELPER_CLUSTERDOMAIN, and either the
# Bitwarden-derived TALHELPER_* secrets (rendered into secrets.yaml.tpl) or SECRETS_FILE pointing at a
# talosctl secrets bundle (tests and CI use a throwaway one).
set -euo pipefail
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

mkdir -p "$(dirname "$out")"
talosctl machineconfig patch "$work/base.yaml" "${args[@]}" -o "$out"
chmod 600 "$out"
```

```bash
chmod +x provision/talos/scripts/render.sh
```

- [ ] **Step 4: Run the test to see it pass**

```bash
bash provision/talos/tests/test_render.sh   # Expected: 21 tests, 0 failed
```

- [ ] **Step 5: Commit**

```bash
git add provision/talos/scripts/render.sh provision/talos/tests/test_render.sh
git commit -m "feat(talos): render.sh builds a node config from gen config plus the patch layers"
```

---

## Task 5: parity.sh and the parity gate (opens PR A)

**Files:**

- Create: `provision/talos/tests/test_parity.sh`, `provision/talos/scripts/parity.sh`
- Modify: `.taskfiles/talos/Taskfile.yaml` (add the `parity` task)

**Interfaces:**

- Consumes: `normalize.sh`, `mask.sh`, `node_names`.
- Produces: `parity.sh <old-dir> <new-dir>`: for every node in `nodes.yaml` compares `home-<node>.yaml` in both directories after normalizing; prints `== <node>: identical` or `== <node>: DIFFERS` followed by a masked unified diff; exit 1 on any difference or missing file. Task `task talos:parity -- <old-dir> <new-dir>`.

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_parity.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/parity.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/old" "$TMP/new"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
YAML
cat > "$TMP/old/home-mc1.yaml" <<'YAML'
version: v1alpha1
machine:
  token: oldtoken
  sysctls:
    a: "1"
cluster:
  id: thecluster
YAML
cp "$TMP/old/home-mc1.yaml" "$TMP/new/home-mc1.yaml"
run() { NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/parity.sh" "$TMP/old" "$TMP/new"; }

assert_ok "identical configs pass" run
cat > "$TMP/new/home-mc1.yaml" <<'YAML'
cluster:
  id: thecluster
machine:
  sysctls:
    a: "1"
  token: oldtoken
version: v1alpha1
YAML
assert_ok "the same config in a different key order passes" run

sed -i 's/a: "1"/a: "2"/' "$TMP/new/home-mc1.yaml"
assert_fails "a changed value fails" run
out="$(run 2>&1 || true)"
assert_contains "$out" 'a: "2"' "the difference is shown"

sed -i 's/oldtoken/newtoken/' "$TMP/new/home-mc1.yaml"
out="$(run 2>&1 || true)"
assert_not_contains "$out" "newtoken" "a changed secret is not printed"
assert_not_contains "$out" "oldtoken" "the old secret is not printed either"
assert_contains "$out" "token: <masked>" "a changed secret still shows as a masked change"

rm "$TMP/new/home-mc1.yaml"
assert_fails "a missing rendered file fails" run
finish
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash provision/talos/tests/test_parity.sh   # Expected: FAIL lines (script missing)
```

- [ ] **Step 3: Implement the script and the task**

`provision/talos/scripts/parity.sh`

```bash
#!/usr/bin/env bash
# parity.sh <old-dir> <new-dir>
# Compare home-<node>.yaml for every node in nodes.yaml between two directories, after normalizing both.
# Differences are shown masked (secret values hidden). Exit 1 when any node differs or a file is missing.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 2 ] || { echo "usage: parity.sh <old-dir> <new-dir>" >&2; exit 2; }
old="$1"; new="$2"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

status=0
while IFS= read -r node; do
  for side in old new; do
    f="${!side}/home-$node.yaml"
    if [ ! -f "$f" ]; then echo "== $node: missing $f" >&2; status=1; continue 2; fi
    "$SCRIPTS/normalize.sh" "$f" > "$tmp/$side.norm" || { echo "== $node: cannot normalize $f" >&2; status=1; continue 2; }
  done
  if diff -u "$tmp/old.norm" "$tmp/new.norm" > "$tmp/diff.txt"; then
    echo "== $node: identical"
  else
    echo "== $node: DIFFERS"
    "$SCRIPTS/mask.sh" < "$tmp/diff.txt"
    status=1
  fi
done < <(node_names)
exit $status
```

```bash
chmod +x provision/talos/scripts/parity.sh
```

In `.taskfiles/talos/Taskfile.yaml`, add this task directly before `wait_for_health:` (indentation: two spaces, like its neighbours):

```yaml
  parity:
    desc: Compare two directories of rendered configs after normalizing, secrets masked (task talos:parity -- OLD NEW)
    cmds:
      - "{{.TALOS_DIR}}/scripts/parity.sh {{.CLI_ARGS}}"

```

- [ ] **Step 4: Run the test to see it pass**

```bash
bash provision/talos/tests/test_parity.sh   # Expected: 8 tests, 0 failed
task --list | grep talos:parity             # Expected: one line
```

- [ ] **Step 5: Commit**

```bash
git add provision/talos/scripts/parity.sh provision/talos/tests/test_parity.sh .taskfiles/talos/Taskfile.yaml
git commit -m "feat(talos): parity script and task to compare rendered configs"
```

- [ ] **Step 6: Run the parity gate (read-only; secrets stay in a private temp directory)**

Old pipeline output against the new layers, for all four nodes:

```bash
task talos:generate                                   # old pipeline: refreshes provision/talos/clusterconfig/
export TALOS_VERSION="$(yq '.vars.TALOS_VERSION' .taskfiles/talos/Taskfile.yaml)"
export KUBERNETES_VERSION="$(yq '.vars.KUBERNETES_VERSION' .taskfiles/talos/Taskfile.yaml)"
new="$(mktemp -d)"; chmod 700 "$new"
for n in mc1 mc2 mc3 nv1; do provision/talos/scripts/render.sh "$n" "$new/home-$n.yaml"; done
out="$(mktemp -d)"
task talos:parity -- provision/talos/clusterconfig "$new" | tee "$out/old-vs-new.txt"
```

Expected (exit 0):

```text
== mc1: identical
== mc2: identical
== mc3: identical
== nv1: identical
```

If any node DIFFERS, fix the layer file named in the (masked) diff and rerun; do not continue until all four are identical.

New render against what the nodes actually run (read-only `talosctl`):

```bash
export TALOSCONFIG="$PWD/provision/talos/clusterconfig/talosconfig"
live="$(mktemp -d)"; chmod 700 "$live"
for pair in mc1:192.168.48.2 mc2:192.168.48.3 mc3:192.168.48.4 nv1:192.168.48.5; do
  talosctl get machineconfig -n "${pair##*:}" -o yaml | yq '.spec' > "$live/home-${pair%%:*}.yaml"
done
task talos:parity -- "$live" "$new" | tee "$out/new-vs-live.txt"
```

Expected: mc1, mc2, mc3 `identical`; nv1 `DIFFERS` with exactly one changed line pair, the install image tag (`custom-installer:v1.13.10-...` live, `v1.14.0-...` in the repo). That lag is known; nothing else may differ.

```bash
rm -rf "$new" "$live"
```

- [ ] **Step 7: Push and open PR A**

The saved outputs are masked, so they are safe to paste.

```bash
git push -u origin HEAD
gh pr create --title "feat(talos): layered patch pipeline beside the old one, with a parity gate" --body "$(cat <<BODY
Phase 1a of docs/superpowers/specs/2026-10-05-talos-config-layout-design.md: the new render pipeline (gen config base plus layered, self-describing patch files) built beside the old one.

Parity, old pipeline vs the new layers:

$(cat "$out/old-vs-new.txt")

Parity, new layers vs what the nodes run (nv1 differs only in its stored install image tag, a known lag):

$(cat "$out/new-vs-live.txt")

Nothing is applied to any node and the old pipeline is untouched.
BODY
)"
rm -rf "$out"
```

---

## Task 6: Switch the pipeline (PR B)

Start after PR A is merged: `git fetch origin && git switch -c feat/talos-layers-switch origin/main`.

**Files:**

- Modify: `.taskfiles/talos/Taskfile.yaml` (`generate`, `generate:talosconfig`, `upgrade` and the role-list variables; the `parity` task from Task 5 stays as it is)
- Delete: `provision/talos/templates/` (5 files), `provision/talos/nodes/` (4 files)
- Modify: `provision/talos/clusterconfig/.gitignore`, `provision/talos/README.md`
- Modify: `.claude/skills/talos-config-editing/SKILL.md`, `.claude/skills/talos-ethernet-config/SKILL.md`, `.claude/skills/cluster-reference/SKILL.md`
- Modify: `cluster/apps/system/prometheus-stack/values.yaml` (comment), `docs/src/general/network.md` (two path references), `.plans/TODO.md` (paths and method text)

**Interfaces:**

- Consumes: everything from Tasks 1 to 5.
- Produces: `task talos:generate` renders through `scripts/render.sh` for every node in `nodes.yaml`; `task talos:upgrade` takes the expected version from the rendered config (`scripts/expected-version.sh`); Review Focus 2 and 4 are handled here.

- [ ] **Step 1: Snapshot the old pipeline's output (this is the regression baseline)**

```bash
task talos:generate                      # old pipeline, still in place
base="$(mktemp -d)"; chmod 700 "$base"
cp provision/talos/clusterconfig/home-*.yaml "$base/"
echo "$base"                             # keep this path for Step 9
```

- [ ] **Step 2: Edit the Taskfile**

In `.taskfiles/talos/Taskfile.yaml`:

(a) Delete these four lines from the top-level `vars:` (only `generate` used them):

```yaml
  CP_LIST:
    sh: yq '.nodes[] | select(.type == "controlplane") | .name' < {{.TALOS_DIR}}/nodes.yaml | tr '\n' ',' | sed 's/,$//'
  WORKER_LIST:
    sh: yq '.nodes[] | select(.type == "worker") | .name' < {{.TALOS_DIR}}/nodes.yaml | tr '\n' ',' | sed 's/,$//'
```

(b) Replace the whole `generate:` task (from the line `generate:` up to, not including, the line `generate:talosconfig:`, both indented by two spaces) with:

```yaml
  generate:
    desc: Render Talos machine configs from provision/talos/patches (task talos:generate)
    dir: provision/talos
    env:
      TALOS_VERSION: "{{.TALOS_VERSION}}"
      KUBERNETES_VERSION: "{{.KUBERNETES_VERSION}}"
    cmds:
      - task: generate:talosconfig
      - for:
          var: NODE_LIST
          split: ","
        cmd: "{{.TALOS_DIR}}/scripts/render.sh {{.ITEM}}"
    preconditions:
      - which envsubst
      - which yq
      - which talosctl
      - sh: talosctl version --client --short | grep -q 'Talos {{ .TALOS_VERSION }}'
        msg: talosctl does not match {{ .TALOS_VERSION }}, run task talos:install
      - test -n "$TALHELPER_OSCERT"

```

(c) In `generate:talosconfig`, change the secrets template path:

```yaml
      - envsubst < secrets.yaml.tpl > /tmp/talos-secrets.yaml
```

(d) In the `upgrade:` task, replace the comment block and the `NODE_TALOS_VERSION:` variable (from the comment line `# Derived from the install image tag` through the line `echo "${v:-{{ .TALOS_VERSION }}}"`, i.e. everything up to the `status:` key) with:

```yaml
      # The expected version is the tag of the install image in the rendered config (FILE above, which
      # must exist, so there is no silent fallback): a Factory tag is the version, a custom installer
      # tag (v1.14.0-6.18.48-nvgpu...) yields its leading Talos version.
      NODE_TALOS_VERSION:
        sh: "{{.TALOS_DIR}}/scripts/expected-version.sh {{.FILE}}"
```

- [ ] **Step 3: Remove the old pipeline and make the ignore file a glob**

```bash
git rm -r provision/talos/templates provision/talos/nodes
printf 'talosconfig\nhome-*.yaml\n' > provision/talos/clusterconfig/.gitignore
```

- [ ] **Step 4: Rewrite the README**

Replace the whole content of `provision/talos/README.md` with:

````markdown
# Talos configuration as code

Machine configs for the four nodes are rendered from small, self-describing patch files layered on top of a
`talosctl gen config` base. Nothing in `clusterconfig/` is edited by hand.

## How a node's config is built

```text
Bitwarden (bws, loaded by .envrc) ──▶ TALHELPER_* environment variables
        │
        ├─ secrets.yaml.tpl ──envsubst──▶ secrets bundle (temp file, deleted afterwards)
        │                                        │
        │                  talosctl gen config (pinned contract) ──▶ base config for the node's role
        │                                                                  │
        └─ patches/all/*  ─▶  patches/<role>/*  ─▶  patches/node/<name>/*   (talosctl machineconfig patch, in this order)
                                                                           │
                                                                           ▼
                                      clusterconfig/home-<node>.yaml  (gitignored, contains secrets)
                                                                           │
                                                          task talos:apply N=<node>
```

`scripts/render.sh <node>` does the whole thing; `task talos:generate` runs it for every node in `nodes.yaml`.

## Layout

```text
nodes.yaml                 node index: name, ip, type (controlplane or worker)
secrets.yaml.tpl           maps TALHELPER_* variables to the talosctl secrets bundle format
patches/
  all/                     every node
  controlplane/            control-plane nodes
  worker/                  workers
  node/<name>/             one node
scripts/                   render.sh and the tools around it
tests/                     shell tests for the scripts (tests/run.sh)
clusterconfig/             gitignored output of task talos:generate
```

## Conventions for patch files

- **One document per file**, named `NN-what-it-configures.yaml`. Files merge in directory order (`all`, then the
  role directory, then `node/<name>`) and by file name inside a directory; later files win. A file may not modify
  the same document twice, which is why there is one document per file.
- **Strategic merge patches only.** Scalars override, maps merge, lists append (so do not repeat a value the base
  already has, the PodSecurity `kube-system` exemption is the example). JSON patches are not used.
- **Every file starts with a header**, checked by `scripts/check-patches.sh`:

  ```yaml
  # What:   Serve etcd /metrics over plain HTTP on 127.0.0.1:2381
  # Why:    Prometheus scrapes it through kube-system/metrics-proxy
  # Nodes:  control plane
  # Apply:  reboot (etcd reads its arguments only at start)
  ```

  `Nodes:` must match the directory (`all nodes`, `control plane`, `workers` or the node name). `Apply:` says what
  applying costs: `live` takes effect immediately, `install-only` only matters at the next install or upgrade
  (the `machine.install` fields), `reboot` takes effect only after a node reboot (etcd settings, kernel modules,
  containerd config, environment variables, volume encryption, workload isolation). A reason in brackets is welcome.

- **Variables only in `*.yaml.tpl` files**, and only the ones listed in `TPL_VARS` in `scripts/lib.sh`.
  `envsubst` never touches a plain `.yaml` file, and a `.tpl` file that needs an unset variable fails the render.
  The file name therefore tells you which patches carry secrets or environment values.
- **Config contract pin.** `scripts/lib.sh` pins `talosctl gen config` to `TALOS_CONTRACT` (now `v1.13`). The 1.14
  contract generates a fully multi-document base that cannot be combined with the legacy fields still used here,
  so the pin moves only when the deprecated fields have been migrated (see `.plans/TODO.md`).

## Usage

Render all node configs and the talosconfig:

```bash
task talos:generate
```

Apply config to a node (no reboot; most changes are live, see the `Apply:` line of the file you changed):

```bash
task talos:apply N=mc1
```

Apply config with reboot:

```bash
task talos:apply:restart N=mc1
```

Upgrade Talos on all nodes (a node is only considered done when it runs the expected version):

```bash
task talos:upgrade:all
```

Compare two directories of rendered configs after normalizing, with secret values masked:

```bash
task talos:parity -- <old-dir> <new-dir>
```

Bootstrap a fresh cluster (first-time only):

```bash
talosctl --nodes 192.168.48.2 apply-config --insecure -f provision/talos/clusterconfig/home-mc1.yaml
kubectl get csr -o name | grep "certificates.k8s.io" | xargs kubectl certificate approve
```

Apply CNI and ArgoCD after bootstrap:

```bash
helm dependencies update cluster/apps/core/cilium
helm template -n kube-system cluster/apps/core/cilium | kubectl apply -f -
kustomize build cluster/apps/core/argocd | argocd-secret-replacer sops -f cluster/apps/core/argocd/secret.sec.yaml | kubectl apply -f -
```

## Changing the config

1. Find or create the patch file: the directory says which nodes it affects, the number sets the order.
   Run `scripts/check-patches.sh` after editing.
2. `task talos:generate`, then inspect `clusterconfig/home-<node>.yaml`.
3. Apply one node at a time with `task talos:apply N=<node>` and wait for the cluster to be healthy in between.
   Changes marked `reboot` need the cordon, drain, reboot, uncordon routine.

Examples:

- A sysctl on the control planes: edit `patches/controlplane/70-sysctls.yaml`.
- A new document (for example `KmsgLogConfig`): add `patches/all/NN-kmsg-log.yaml` with the header and the document.
- A per-node setting: add a file under `patches/node/<name>/`.

## Adding a new node

1. Add the node to `nodes.yaml` (name, ip, type: `controlplane` or `worker`).
2. Create `patches/node/<name>/10-network.yaml` with hostname, interface, address, route (and the VIP on a control plane).
3. Add a per-node install image only if the node needs its own installer (see below).
4. `scripts/check-patches.sh`, then `task talos:generate`.

### Nodes on a non-default Talos version

There is no per-node `talosVersion` key. A node's expected version is **derived from the tag of the install image**
in its rendered config (`scripts/expected-version.sh`): a Factory image tag such as `v1.14.2` is the version, and a
custom installer tag such as `v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim` yields its leading Talos version, `v1.14.0`.
`task talos:upgrade N=<name>` (and `task talos:upgrade:all`) compares the node's running version with that and fails
when the node comes back on something else.

nv1 is such a node. Its image lives in `patches/node/nv1/20-install-image.yaml`:

```yaml
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
```

To move such a node to a new Talos version, bump the tag in that file, nothing else. **Confirm a matching custom
installer exists first.** nv1's GPU kernel modules (`host1x`, `tegra_drm`, `nvgpu`, …) are ABI-bound to the exact
kernel build in that image, and Talos loads them during the boot sequence before starting services, so a mismatched
image can leave the node with networking up but `apid` never starting: reachable at the TCP level, unmanageable, and
fixable only over the console. See `docs/superpowers/specs/2026-08-13-jetson-igpu-design.md` and
`docs/superpowers/specs/2026-08-13-jetson-installer-build-design.md`.

#### nv1 boots the wrong UKI after an upgrade (Jetson UEFI)

The Jetson UEFI does not persist the sd-boot default entry the installer sets
(upstream `BUGS.md`, [Bug 25](https://github.com/schwankner/talos-jetson-orin/blob/main/BUGS.md#bug-25--same-version-talosctl-upgrade-never-boots-the-new-uki-on-jetson-uefi-reports-success-anyway)).
The persisted `LoaderEntryDefault` keeps naming an old UKI, sd-boot honours it
while that file exists, and the node reboots into the old version. `talosctl
upgrade` and `talosctl health` both still succeed. `task talos:upgrade` now
fails with `ERROR: nv1 runs vX, expected vY` when this happens. **Do not re-run
the upgrade**, it repeats the same thing. The 1.13 -> 1.14 upgrade hit this.

Check what sd-boot sees and what it picked:

```sh
export TALOSCONFIG=$PWD/provision/talos/clusterconfig/talosconfig
G=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
for v in LoaderEntryDefault LoaderEntrySelected; do
  printf "$v: "; talosctl read /sys/firmware/efi/efivars/$v-$G -n 192.168.48.5 | tail -c +5 | iconv -f UTF-16LE -t UTF-8
  echo
done
```

Fix without a console (verified on nv1): make the stale default point at a file
that does not exist, so sd-boot falls back to its own ordering (newest UKI
first).

1. Run a short-lived privileged pod pinned to nv1 in `kube-system` (exempt from
   the PodSecurity baseline) with hostPath `/dev` and mount `/dev/nvme0n1p1`
   (vfat). Talos does not mount the EFI partition at runtime and has no API to
   write it, so this is the only remote route.
2. Rename the stale UKI, do not delete it:
   `mv EFI/Linux/Talos-vOLD.efi EFI/Linux/Talos-vOLD.efi.bak`, then `sync`,
   `umount`, delete the pod.
3. `talosctl reboot --nodes 192.168.48.5`, then confirm the running version,
   `LoaderEntrySelected`, `nvidia.com/gpu: 1`, `/dev/dri` and `/etc/cri/containerd.toml`.

Notes:

- Editing `loader/loader.conf` (`default <entry>`) does **not** help: the
  `LoaderEntryDefault` EFI variable outranks it. The installer rewrites that file
  on every install anyway.
- After the rename there is no fallback entry. If the new UKI does not boot, the
  node needs the console or the USB image. Confirm a matching custom installer
  exists first (see above).
- Same-version bumps (only the nvgpu extension changes) hit this too, plus the
  installer names the new UKI `Talos-vX~N.efi`. Expect to repeat the rename.
- Do not upgrade nv1 before the control plane: worker one minor behind is fine,
  the reverse is not.

## Secrets

All secrets come from Bitwarden Secrets Manager: `.envrc` runs `bws` and exports them as `TALHELPER_*` environment
variables (the prefix is inherited from talhelper, which is no longer used). `secrets.yaml.tpl` maps them to the
talosctl secrets bundle format, and the few `.yaml.tpl` patches substitute the values they need. Nothing encrypted
is committed; the rendered files in `clusterconfig/` contain secrets and stay gitignored.
````

- [ ] **Step 5: Rewrite the skills**

Replace the whole content of `.claude/skills/talos-config-editing/SKILL.md` with:

````markdown
---
name: talos-config-editing
description: >
  How to edit Talos node configs in this repo: which patch file for which change,
  the file header convention, strategic merge patch rules, and how to add new config documents.
when_to_use: >
  Trigger phrases: "edit talos config", "add talos extension", "change sysctl",
  "modify kubelet", "add node label", "talos machine config", "new config document",
  "ExtensionServiceConfig", "talos patch", "per-node config".
---

# Editing Talos Config

## Pipeline

`task talos:generate` runs `provision/talos/scripts/render.sh <node>` for every node in `provision/talos/nodes.yaml`:

```text
talosctl gen config (contract pinned in scripts/lib.sh)  → base config for the node's role
talosctl machineconfig patch … in this order:
  patches/all/*  →  patches/<controlplane|worker>/*  →  patches/node/<name>/*   (by file name inside a directory)
→ clusterconfig/home-<node>.yaml   (gitignored, contains secrets)
```

Output is multi-document YAML. Read `provision/talos/README.md` for the full picture.

## Edit Decision Map

| Change type                                                                         | Where                                                                             |
| ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Setting for every node (kubelet, nameservers, time, CRI, features, cluster network) | `provision/talos/patches/all/`                                                    |
| Control-plane only (etcd, apiServer, sysctls, udev, EthernetConfig, API access)     | `provision/talos/patches/controlplane/`                                           |
| Worker only (taints, sysctls, role install image)                                   | `provision/talos/patches/worker/`                                                 |
| One node (hostname, IP, VIP, custom installer image, kernel modules)                | `provision/talos/patches/node/<name>/`                                            |
| New Talos document (EthernetConfig, ExtensionServiceConfig, KmsgLogConfig, …)       | A new `NN-name.yaml` in the layer it applies to, no Taskfile change               |
| Needs a secret or environment value                                                 | A `NN-name.yaml.tpl` file; the variable must be in `TPL_VARS` in `scripts/lib.sh` |

**Never edit** `clusterconfig/home-*.yaml` directly: it is regenerated by `task talos:generate`.

## File rules (checked by `scripts/check-patches.sh`)

- Name: `NN-some-name.yaml` or `NN-some-name.yaml.tpl` (two digits first). **One YAML document per file.**
- Header at the top, all four lines:

  ```yaml
  # What:   what it configures
  # Why:    why it is set this way
  # Nodes:  all nodes | control plane | workers | <node name>   (must match the directory)
  # Apply:  live | install-only | reboot   (optionally followed by a reason in brackets)
  ```

  `live` takes effect immediately, `install-only` only matters at the next install or upgrade (`machine.install`),
  `reboot` needs a node reboot (etcd settings, kernel modules, containerd config, env, volume encryption).

- `${VAR}` only in `.yaml.tpl` files, only variables from `TPL_VARS`. An unset variable fails the render.

## Strategic Merge Patch Rules

Patches are partial documents: only the keys to override.

- **Scalars** override the base value
- **Maps** merge recursively
- **Lists** append, **except**:
  - `cluster.network.podSubnets` and `cluster.network.serviceSubnets` are **replaced** entirely
- **`machine.network.interfaces[]`** merges on matching `interface:` or `deviceSelector:` key: a patch entry for `eth0` updates the existing `eth0` entry, it does not add a second one
- Lists append, so do not repeat a value the generated base already carries (the PodSecurity `kube-system` exemption)
- Remove something the base generates with `$patch: delete` (see `all/05-hostname-config-delete.yaml` and `controlplane/85-delete-lb-exclusion-label.yaml`)
- A single patch file cannot modify the same document twice; hence one document per file

## Adding a New Config Document

Config documents that are not `v1alpha1` (for example `ExtensionServiceConfig`, `EthernetConfig`, `KmsgLogConfig`) are separate YAML documents. Add one as its own patch file with the header, for example `provision/talos/patches/controlplane/90-ethernet-rings.yaml`:

```yaml
# What:   NIC ring buffers rx/tx 4096 on eth0
# Why:    Avoids packet drops under load
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
  tx: 4096
```

Then `scripts/check-patches.sh` and `task talos:generate`. No Taskfile edit is needed.

## After Any Edit

```sh
scripts/check-patches.sh     # conventions
task talos:generate          # re-render clusterconfig/

task talos:apply N=mc1       # apply (most fields are live)
# or
task talos:apply:restart N=mc1   # apply + reboot
```

The `Apply:` line of the file you changed tells you whether a reboot is needed. Applying never restarts etcd and
`talosctl service etcd restart` is refused, so etcd setting changes only take effect after a node reboot.
`talosctl reboot` is blocked for Claude by the permission settings: ask the user to run it.
````

In `.claude/skills/talos-ethernet-config/SKILL.md`, replace the section from the heading `## Repo Pattern` up to (not including) `## Check Supported Values First` with:

````markdown
## Repo Pattern

Add the document as its own patch file, with the header the repo requires (`provision/talos/README.md`):

`provision/talos/patches/controlplane/90-ethernet-rings.yaml`

```yaml
# What:   NIC ring buffers rx/tx 4096 on eth0
# Why:    Avoids packet drops under load
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
  tx: 4096
```

No Taskfile change is needed: files in the layer directory are merged automatically. Run
`provision/talos/scripts/check-patches.sh` and `task talos:generate`.

````

In `.claude/skills/cluster-reference/SKILL.md`, replace the line

```text
- Managed with `talosctl` + `envsubst` from `provision/talos/templates/` and `provision/talos/nodes/`
```

with

```text
- Rendered from `talosctl gen config` plus the layered patch files in `provision/talos/patches/` (see `provision/talos/README.md`)
```

and replace the line

```text
> DHCP is disabled on VLAN 48; all node addresses are static in `provision/talos/nodes/`.
```

with

```text
> DHCP is disabled on VLAN 48; all node addresses are static in `provision/talos/patches/node/`.
```

- [ ] **Step 6: Fix the remaining path references**

```bash
sed -i 's#provision/talos/templates/controlplane.yaml); kube-system/metrics-proxy#provision/talos/patches/controlplane/10-etcd-metrics.yaml); kube-system/metrics-proxy#' cluster/apps/system/prometheus-stack/values.yaml
sed -i 's#(see `provision/talos/templates/controlplane.yaml`)#(see `provision/talos/patches/all/20-nameservers.yaml`)#; s#(static in `provision/talos/nodes/`)#(static in `provision/talos/patches/node/`)#' docs/src/general/network.md
```

In `.plans/TODO.md`, in the entry "Migrate deprecated v1alpha1 Talos config fields", make these exact replacements:

- In the bullet **Method per migration**: replace "Move the field into a new template document appended in `.taskfiles/talos/Taskfile.yaml` (`generate` task, see the `talos-config-editing` skill), run `task talos:generate`, then `talosctl apply-config --nodes <ip> --file provision/talos/clusterconfig/home-<node>.yaml --mode auto --dry-run` and confirm the diff has no functional change (note: the dry-run diff prints the etcd CA key as unchanged context, do not paste it anywhere)." with "Move the field into its own patch file under `provision/talos/patches/` (see `provision/talos/README.md`), run `task talos:generate`, then `task talos:diff` (repo vs live, secrets masked) and confirm the diff shows only the intended move."
- Replace "(`templates/talosctl-secrets.yaml`)" with "(`provision/talos/secrets.yaml.tpl`)".
- Replace "(`templates/controlplane.yaml`, `worker.yaml`)" with "(`provision/talos/patches/all/20-nameservers.yaml`)".
- Replace "as the comment in `nodes/nv1.yaml` says" with "as the header of `provision/talos/patches/node/nv1/50-containerd-config.yaml` says".

- [ ] **Step 7: Verify the new `generate` and its safeguards**

```bash
task talos:generate                                    # renders mc1, mc2, mc3, nv1 through scripts/render.sh
ls -l provision/talos/clusterconfig/ | grep -E "home-|talosconfig"   # home-*.yaml are -rw-------
git check-ignore -v provision/talos/clusterconfig/home-newnode.yaml  # Expected: matched by the home-*.yaml glob (Review Focus 2)
task talos:generate TALOS_VERSION=v1.13.0 2>&1 | tail -3             # Expected: precondition fails: "talosctl does not match v1.13.0" (Review Focus 4)
provision/talos/scripts/expected-version.sh provision/talos/clusterconfig/home-nv1.yaml   # Expected: v1.14.0
provision/talos/scripts/expected-version.sh provision/talos/clusterconfig/home-mc1.yaml   # Expected: v1.14.2
```

- [ ] **Step 8: Verify the new pipeline reproduces the baseline**

```bash
out="$(mktemp -d)"
task talos:parity -- "$base" provision/talos/clusterconfig | tee "$out/parity.txt"     # $base from Step 1
```

Expected: four `identical` lines. Then `rm -rf "$base"`.

- [ ] **Step 9: Lint and test**

```bash
provision/talos/tests/run.sh                                  # Expected: every file "0 failed"
prettier --ignore-unknown --config .github/linters/.prettierrc.yaml --check provision/talos/README.md .claude/skills/talos-config-editing/SKILL.md
yamllint -c .github/linters/.yamllint.yaml .taskfiles/talos/Taskfile.yaml
grep -rn "templates/controlplane\|templates/worker\|provision/talos/nodes/\|nodes/<name>" --include=*.md --include=*.yaml --include=*.yml . | grep -v "^./docs/superpowers/\|^./.archive\|^./.git/" ; echo "(nothing above = no stale references)"
```

- [ ] **Step 10: Commit, push, open PR B**

```bash
git add -A
git commit -m "feat(talos): render node configs from the layered patches, remove the envsubst templates"
git push -u origin HEAD
gh pr create --title "feat(talos): switch to the layered patch pipeline" --body "$(cat <<BODY
Phase 1a switch: task talos:generate now renders through scripts/render.sh, the envsubst templates and per-node patches are removed, docs and skills follow the new layout.

Regression check, output of the old pipeline (snapshot taken before the switch) vs the new one:

$(cat "$out/parity.txt")

Nothing is applied to any node.
BODY
)"
rm -rf "$out"
```

---

## Task 7: explain (PR C starts: `git fetch origin && git switch -c feat/talos-layers-tooling origin/main` after PR B is merged)

**Files:**

- Create: `provision/talos/tests/test_explain.sh`, `provision/talos/scripts/explain.sh`
- Modify: `.taskfiles/talos/Taskfile.yaml`, `provision/talos/README.md`, `.claude/skills/talos-config-editing/SKILL.md`

**Interfaces:**

- Consumes: `lib.sh` (`node_names`, `node_field`, `patch_files`, `header_value`, `touches`).
- Produces: `explain.sh [--markdown] [node...]`. Terminal form per node: each patch file in merge order with `what`, `why`, `apply`, `touches` and, when a later file touches the same top-level item as an earlier one, `notes: shares <item> with <file>`. `--markdown` form: a `## <node>` section with the table `| File | What | Apply | Touches | Notes |`, pipes escaped. Task `task talos:explain -- [--markdown] [node...]`.

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_explain.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/explain.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p/all" "$TMP/p/controlplane" "$TMP/p/worker" "$TMP/p/node/mc1"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
  - name: nv1
    ip: 192.168.48.5
    type: worker
YAML
cat > "$TMP/p/all/10-install.yaml" <<'YAML'
# What:   Install target
# Why:    one disk
# Nodes:  all nodes
# Apply:  install-only
machine:
  install:
    disk: /dev/nvme0n1
YAML
cat > "$TMP/p/controlplane/10-rings.yaml" <<'YAML'
# What:   NIC rings | with a pipe
# Why:    drops
#         second line of the reason
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
YAML
cat > "$TMP/p/node/mc1/20-install.yaml" <<'YAML'
# What:   mc1 installs from a custom image
# Why:    custom
# Nodes:  mc1
# Apply:  install-only
machine:
  install:
    image: example.test/custom:v1
YAML
cat > "$TMP/p/worker/10-taint.yaml" <<'YAML'
# What:   taint
# Why:    keep pods off
# Nodes:  workers
# Apply:  live
machine:
  nodeTaints:
    a: b:NoSchedule
YAML
ex() { PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/explain.sh" "$@"; }

echo "-- terminal output"
out="$(ex mc1)"
assert_contains "$out" "mc1" "names the node"
assert_contains "$out" "patches/all/10-install.yaml" "lists the all layer file"
assert_contains "$out" "patches/controlplane/10-rings.yaml" "lists the role layer file"
assert_contains "$out" "patches/node/mc1/20-install.yaml" "lists the node layer file"
assert_contains "$out" "EthernetConfig/eth0" "shows document kind and name"
assert_contains "$out" "machine.install" "shows the legacy field it touches"
assert_contains "$out" "second line of the reason" "joins continuation lines of the reason"
assert_contains "$out" "shares machine.install with provision/talos/patches/all/10-install.yaml" "flags a later file that touches the same item"
assert_not_contains "$out" "10-taint.yaml" "does not list another role's files"

echo "-- node selection"
assert_contains "$(ex nv1)" "10-taint.yaml" "a worker lists the worker layer"
assert_not_contains "$(ex nv1)" "10-rings.yaml" "a worker does not list control-plane files"
assert_contains "$(ex)" "== nv1" "without arguments every node is shown"
assert_fails "an unknown node fails" ex nope

echo "-- markdown output"
md="$(ex --markdown mc1)"
assert_contains "$md" "## mc1" "markdown has a heading per node"
assert_contains "$md" "| File | What | Apply | Touches | Notes |" "markdown has a table header"
assert_contains "$md" 'NIC rings \| with a pipe' "pipes in text are escaped"
finish
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash provision/talos/tests/test_explain.sh   # Expected: FAIL lines (script missing)
```

- [ ] **Step 3: Implement**

`provision/talos/scripts/explain.sh`

```bash
#!/usr/bin/env bash
# explain.sh [--markdown] [node...]
# For each node (default: all), list every patch file in merge order with what it does, what applying
# it costs, what it touches, and which earlier file touches the same top-level item. Reads the file headers; needs yq.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

markdown=0
if [ "${1:-}" = "--markdown" ]; then markdown=1; shift; fi
nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || mapfile -t nodes < <(node_names)

repo_path() { echo "provision/talos/patches/${1#"$PATCHES_DIR"/}"; }
esc() { sed 's/|/\\|/g' <<<"$1"; }

first=1
for node in "${nodes[@]}"; do
  [ "$first" -eq 1 ] || echo
  first=0
  type="$(node_field "$node" type)"
  [ -n "$type" ] || die "unknown node: $node"
  ip="$(node_field "$node" ip)"
  if [ "$markdown" -eq 1 ]; then
    printf '## %s\n\n%s, %s\n\n' "$node" "$type" "$ip"
    printf '| File | What | Apply | Touches | Notes |\n| --- | --- | --- | --- | --- |\n'
  else
    printf '== %s (%s, %s)\n' "$node" "$type" "$ip"
  fi
  declare -A seen=()
  while IFS= read -r f; do
    what="$(header_value "$f" What)"; why="$(header_value "$f" Why)"; apply="$(header_value "$f" Apply)"
    mapfile -t items < <(touches "$f")
    notes=""
    for item in "${items[@]}"; do
      if [ -n "${seen[$item]:-}" ]; then notes="${notes:+$notes; }shares $item with $(repo_path "${seen[$item]}")"; fi
      seen[$item]="$f"
    done
    touched="${items[*]}"
    if [ "$markdown" -eq 1 ]; then
      printf '| `%s` | %s | %s | %s | %s |\n' "$(repo_path "$f")" "$(esc "$what")" "$(esc "$apply")" "$(esc "${touched:-}")" "$(esc "$notes")"
    else
      printf '\n%s\n  what:    %s\n  why:     %s\n  apply:   %s\n  touches: %s\n' "$(repo_path "$f")" "$what" "$why" "$apply" "${touched:-}"
      [ -z "$notes" ] || printf '  notes:   %s\n' "$notes"
    fi
  done < <(patch_files "$node")
  unset seen
done
```

```bash
chmod +x provision/talos/scripts/explain.sh
```

In `.taskfiles/talos/Taskfile.yaml`, add before `wait_for_health:`:

```yaml
  explain:
    desc: What is configured per node, from the patch headers (task talos:explain -- mc1, or --markdown)
    cmds:
      - "{{.TALOS_DIR}}/scripts/explain.sh {{.CLI_ARGS}}"

```

In `provision/talos/README.md`, insert this section directly before the `## Secrets` heading:

```markdown
## Inspecting the config

`task talos:explain -- mc1` lists, for a node, every patch file in merge order with what it does, why, what applying
it costs, what it touches and which earlier file touches the same top-level item. Without arguments it shows all nodes;
`--markdown` prints the tables used for the generated config map.

```

In `.claude/skills/talos-config-editing/SKILL.md`, replace the sentence

```text
Output is multi-document YAML. Read `provision/talos/README.md` for the full picture.
```

with

```text
Output is multi-document YAML. Read `provision/talos/README.md` for the full picture, or run
`task talos:explain -- <node>` to see every effective document and the file it comes from.
```

and in the `## After Any Edit` code block add the line `task talos:explain -- mc1    # what is configured, from where` directly after the `task talos:generate` line.

- [ ] **Step 4: Run the tests, check the real output, lint**

```bash
bash provision/talos/tests/test_explain.sh   # Expected: 16 tests, 0 failed
task talos:explain -- nv1 | head -20         # readable per-file blocks starting with all/05-hostname-config-delete.yaml
prettier --ignore-unknown --config .github/linters/.prettierrc.yaml --check provision/talos/README.md .claude/skills/talos-config-editing/SKILL.md
```

- [ ] **Step 5: Commit**

```bash
git add provision/talos .taskfiles/talos/Taskfile.yaml .claude/skills/talos-config-editing/SKILL.md
git commit -m "feat(talos): task talos:explain lists what is configured per node from the patch headers"
```

---

## Task 8: Config map

**Files:**

- Create: `provision/talos/tests/test_config_map.sh`, `provision/talos/scripts/config-map.sh`, `docs/src/talos/config-map.md` (generated)
- Modify: `.taskfiles/talos/Taskfile.yaml`, `.github/linters/.prettierignore`, `provision/talos/README.md`

**Interfaces:**

- Consumes: `explain.sh --markdown`.
- Produces: `config-map.sh [--check] [out-file]` (default `docs/src/talos/config-map.md`; needs no secrets and no cluster); `--check` writes nothing and exits 1 when the file is missing or differs. Task `task talos:config-map`.

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_config_map.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/config-map.sh
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p/all"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
YAML
cat > "$TMP/p/all/10-time.yaml" <<'YAML'
# What:   NTP servers
# Why:    etcd needs time sync
# Nodes:  all nodes
# Apply:  live
machine:
  time:
    disabled: false
YAML
gen() { PATCHES_DIR="$TMP/p" NODES_FILE="$TMP/nodes.yaml" "$SCRIPTS/config-map.sh" "$@"; }

gen "$TMP/map.md"
out="$(cat "$TMP/map.md")"
assert_contains "$out" "# Talos configuration map" "has a title"
assert_contains "$out" "Generated" "says it is generated"
assert_contains "$out" "markdownlint-disable MD013" "disables the line-length rule for the wide tables"
assert_contains "$out" "## mc1" "has a section per node"
assert_contains "$out" "NTP servers" "contains the patch descriptions"

assert_ok "check passes when the file is up to date" gen --check "$TMP/map.md"
sed -i 's/NTP servers/stale text/' "$TMP/map.md"
assert_fails "check fails when the file is stale" gen --check "$TMP/map.md"
assert_fails "check fails when the file is missing" gen --check "$TMP/missing.md"
finish
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash provision/talos/tests/test_config_map.sh   # Expected: FAIL lines (script missing)
```

- [ ] **Step 3: Implement**

`provision/talos/scripts/config-map.sh`

```bash
#!/usr/bin/env bash
# config-map.sh [--check] [out-file]
# Generate the Talos configuration map for the docs (default docs/src/talos/config-map.md) from the
# patch headers. It needs no secrets and no cluster. With --check, write nothing and exit 1 when the
# file differs from what would be generated (CI uses this to catch a stale map).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check=0
if [ "${1:-}" = "--check" ]; then check=1; shift; fi
out="${1:-$TALOS_DIR/../../docs/src/talos/config-map.md}"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
{
  cat <<'DOC'
<!-- markdownlint-disable MD013 -->

# Talos configuration map

> Generated by `task talos:config-map` from the headers of the files under `provision/talos/patches/`. Do not edit.
> Files are listed in merge order (later files win); see `provision/talos/README.md` for how they are applied.
> Apply: `live` takes effect immediately, `install-only` only matters at the next install or upgrade,
> `reboot` takes effect only after a node reboot.

DOC
  "$SCRIPTS/explain.sh" --markdown
} > "$tmp"

if [ "$check" -eq 1 ]; then
  [ -f "$out" ] || { echo "config-map: $out does not exist; run task talos:config-map" >&2; exit 1; }
  diff -u "$out" "$tmp" >&2 || { echo "config-map: $out is stale; run task talos:config-map" >&2; exit 1; }
  echo "config-map: up to date"
else
  mkdir -p "$(dirname "$out")"
  cp "$tmp" "$out"
  echo "config-map: wrote $out"
fi
```

```bash
chmod +x provision/talos/scripts/config-map.sh
```

In `.taskfiles/talos/Taskfile.yaml`, add before `wait_for_health:`:

```yaml
  config-map:
    desc: Regenerate docs/src/talos/config-map.md (task talos:config-map)
    cmds:
      - "{{.TALOS_DIR}}/scripts/config-map.sh"

```

Append this line to `.github/linters/.prettierignore` (prettier would re-align the generated tables):

```text
docs/src/talos/config-map.md
```

In `provision/talos/README.md`, append to the `## Inspecting the config` section:

```markdown
`task talos:config-map` writes the same information for all nodes to `docs/src/talos/config-map.md`
(published with the docs). The file is generated from the patch headers, contains no secrets, and CI fails when it
is stale; regenerate it after any change to a patch file.
```

- [ ] **Step 4: Generate the document and run the tests**

```bash
bash provision/talos/tests/test_config_map.sh    # Expected: 8 tests, 0 failed
task talos:config-map                            # Expected: config-map: wrote .../docs/src/talos/config-map.md
provision/talos/scripts/config-map.sh --check    # Expected: config-map: up to date
head -16 docs/src/talos/config-map.md
```

- [ ] **Step 5: Commit**

```bash
git add provision/talos docs/src/talos/config-map.md .taskfiles/talos/Taskfile.yaml .github/linters/.prettierignore
git commit -m "feat(talos): generated configuration map in the docs"
```

---

## Task 9: diff against the live nodes

**Files:**

- Create: `provision/talos/tests/test_diff_live.sh`, `provision/talos/scripts/diff-live.sh`
- Modify: `.taskfiles/talos/Taskfile.yaml`, `provision/talos/README.md`, `.claude/skills/talos-config-editing/SKILL.md`

**Interfaces:**

- Consumes: `render.sh`, `normalize.sh`, `mask.sh`, `expected_version` (lib.sh).
- Produces: `diff-live.sh [node...]`: per node prints `<node>: no differences` or `<node>: live (-) differs from the repo (+)` plus a masked unified diff, and `<node>: running vX` or `<node>: running vX, expected vY`; exit 1 on any difference or version mismatch. `RENDERED_DIR` and `LIVE_DIR` environment overrides replace the render and the `talosctl` reads (used by tests). Task `task talos:diff -- [node...]`.

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_diff_live.sh`

```bash
#!/usr/bin/env bash
# Tests for scripts/diff-live.sh and expected_version (lib.sh)
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
source "$SCRIPTS/lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rendered" "$TMP/live"
cat > "$TMP/nodes.yaml" <<'YAML'
nodes:
  - name: mc1
    ip: 192.168.48.2
    type: controlplane
YAML
cat > "$TMP/rendered/home-mc1.yaml" <<'YAML'
version: v1alpha1
machine:
  token: sometoken
  install:
    image: factory.talos.dev/metal-installer/abc:v1.14.2
  sysctls:
    a: "1"
YAML
cp "$TMP/rendered/home-mc1.yaml" "$TMP/live/mc1.yaml"
run() { NODES_FILE="$TMP/nodes.yaml" RENDERED_DIR="$TMP/rendered" LIVE_DIR="$TMP/live" "$SCRIPTS/diff-live.sh" "$@"; }

echo "-- expected_version"
assert_eq "v1.14.2" "$(expected_version "$TMP/rendered/home-mc1.yaml")" "a Factory image tag is the version"
cat > "$TMP/custom.yaml" <<'YAML'
machine:
  install:
    image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
YAML
assert_eq "v1.14.0" "$(expected_version "$TMP/custom.yaml")" "a custom installer tag yields its leading Talos version"

echo "-- diff"
assert_ok "identical live and repo configs pass" run
out="$(run)"
assert_contains "$out" "mc1: no differences" "reports no differences"

sed -i 's/a: "1"/a: "2"/' "$TMP/live/mc1.yaml"
assert_fails "a differing live config fails" run
assert_contains "$(run 2>&1 || true)" 'a: "' "shows the difference"

sed -i 's/sometoken/othertoken/' "$TMP/live/mc1.yaml"
out="$(run 2>&1 || true)"
assert_not_contains "$out" "sometoken" "never prints the repo-side secret"
assert_not_contains "$out" "othertoken" "never prints the live-side secret"
finish
```

- [ ] **Step 2: Run it to see it fail**

```bash
bash provision/talos/tests/test_diff_live.sh   # Expected: FAIL lines (script missing)
```

- [ ] **Step 3: Implement**

`provision/talos/scripts/diff-live.sh`

```bash
#!/usr/bin/env bash
# diff-live.sh [node...]
# Compare what the repo renders with what each node runs (machine config), and the running Talos
# version with the expected one. Differences are masked (secret values hidden). Exit 1 on any
# difference or version mismatch. Needs the same environment as render.sh and a reachable cluster.
#
# Test/offline overrides: RENDERED_DIR (pre-rendered home-<node>.yaml files, skips render.sh) and
# LIVE_DIR (<node>.yaml raw live configs, skips talosctl and the version check).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TALOSCONFIG="${TALOSCONFIG:-$TALOS_DIR/clusterconfig/talosconfig}"

nodes=("$@")
[ ${#nodes[@]} -gt 0 ] || mapfile -t nodes < <(node_names)
tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT

status=0
for node in "${nodes[@]}"; do
  ip="$(node_field "$node" ip)"
  [ -n "$ip" ] || { echo "unknown node: $node" >&2; status=1; continue; }

  if [ -n "${RENDERED_DIR:-}" ]; then rendered="$RENDERED_DIR/home-$node.yaml"
  else rendered="$tmp/rendered-$node.yaml"; "$SCRIPTS/render.sh" "$node" "$rendered" || { status=1; continue; }; fi

  if [ -n "${LIVE_DIR:-}" ]; then live="$LIVE_DIR/$node.yaml"
  else live="$tmp/live-$node.yaml"; talosctl get machineconfig -n "$ip" -o yaml 2>/dev/null | yq '.spec' > "$live" || { echo "$node: cannot read the live config" >&2; status=1; continue; }; fi

  "$SCRIPTS/normalize.sh" "$live" > "$tmp/live.norm" && "$SCRIPTS/normalize.sh" "$rendered" > "$tmp/repo.norm" \
    || { echo "$node: cannot normalize" >&2; status=1; continue; }
  if diff -u "$tmp/live.norm" "$tmp/repo.norm" > "$tmp/diff.txt"; then
    echo "$node: no differences"
  else
    echo "$node: live (-) differs from the repo (+)"
    "$SCRIPTS/mask.sh" < "$tmp/diff.txt"
    status=1
  fi

  if [ -z "${LIVE_DIR:-}" ]; then
    want="$(expected_version "$rendered")"
    have="$(talosctl version -n "$ip" 2>/dev/null | sed -n '/Server:/,$p' | sed -n 's/^[[:space:]]*Tag:[[:space:]]*//p' | head -1)"
    if [ "$have" = "$want" ]; then echo "$node: running $have"
    else echo "$node: running ${have:-unknown}, expected $want"; status=1; fi
  fi
done
exit $status
```

```bash
chmod +x provision/talos/scripts/diff-live.sh
```

In `.taskfiles/talos/Taskfile.yaml`, add before `wait_for_health:`:

```yaml
  diff:
    desc: Repo vs live machine config and running version per node, secrets masked (task talos:diff -- mc1)
    env:
      TALOS_VERSION: "{{.TALOS_VERSION}}"
      KUBERNETES_VERSION: "{{.KUBERNETES_VERSION}}"
    cmds:
      - "{{.TALOS_DIR}}/scripts/diff-live.sh {{.CLI_ARGS}}"

```

In `provision/talos/README.md`, append to the `## Inspecting the config` section:

```markdown
`task talos:diff -- mc1` renders the node from the repo, reads the config the node actually runs, and shows the
difference with secret values masked, plus the running Talos version against the expected one. It needs the same
environment as `task talos:generate` and a reachable cluster, and changes nothing. A node whose stored install-image tag
lags (for example nv1 after an upgrade) shows up here.
```

In `.claude/skills/talos-config-editing/SKILL.md`, add the line `task talos:diff -- mc1       # repo vs the live node, secrets masked` to the `## After Any Edit` code block, after the `task talos:explain -- mc1` line.

- [ ] **Step 4: Run the tests, then the real diff (read-only)**

```bash
bash provision/talos/tests/test_diff_live.sh   # Expected: 8 tests, 0 failed
task talos:diff
```

Expected: `mc1`, `mc2`, `mc3` report `no differences` and `running v1.14.2`; `nv1` reports a diff of exactly the install image tag line (live `v1.13.10-...`, repo `v1.14.0-...`) and `running v1.14.0`; the command exits 1 because of that known nv1 lag. No secret value appears anywhere in the output.

- [ ] **Step 5: Commit**

```bash
git add provision/talos .taskfiles/talos/Taskfile.yaml .claude/skills/talos-config-editing/SKILL.md
git commit -m "feat(talos): task talos:diff compares the repo with the live nodes"
```

---

## Task 10: Offline checks task and CI (opens PR C)

**Files:**

- Create: `.github/workflows/talos-config.yaml`
- Modify: `.taskfiles/talos/Taskfile.yaml`, `provision/talos/README.md`

**Interfaces:**

- Consumes: `check-patches.sh`, `config-map.sh --check`, `tests/run.sh`.
- Produces: `task talos:check` (no secrets, no cluster); a GitHub Actions workflow that runs the same three commands on pull requests touching Talos files.

- [ ] **Step 1: Add the task**

In `.taskfiles/talos/Taskfile.yaml`, add before `wait_for_health:`:

```yaml
  check:
    desc: Offline checks, no secrets or cluster needed (task talos:check)
    cmds:
      - "{{.TALOS_DIR}}/scripts/check-patches.sh"
      - "{{.TALOS_DIR}}/scripts/config-map.sh --check"
      - "{{.TALOS_DIR}}/tests/run.sh"

```

- [ ] **Step 2: Add the workflow**

`.github/workflows/talos-config.yaml`

```yaml
---
name: Talos config

on: # yamllint disable-line rule:truthy
  pull_request:
    branches:
      - main
    paths:
      - "provision/talos/**"
      - ".taskfiles/talos/**"
      - "docs/src/talos/**"
      - ".github/workflows/talos-config.yaml"
  workflow_dispatch:

concurrency:
  group: ${{ github.ref }}-${{ github.workflow }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  check:
    name: Talos config checks
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7

      - name: Install tools
        run: |
          sudo apt-get update -qq
          sudo apt-get install -y -qq gettext-base
          version="$(yq '.vars.TALOS_VERSION' .taskfiles/talos/Taskfile.yaml)"
          curl -fsSL -o talosctl "https://github.com/siderolabs/talos/releases/download/${version}/talosctl-linux-amd64"
          sudo install -m 0755 talosctl /usr/local/bin/talosctl
          talosctl version --client --short

      - name: Patch conventions
        run: provision/talos/scripts/check-patches.sh

      - name: Config map is up to date
        run: provision/talos/scripts/config-map.sh --check

      - name: Tests
        run: provision/talos/tests/run.sh
```

- [ ] **Step 3: Document it**

In `provision/talos/README.md`, insert this section directly before `## Secrets`:

```markdown
## Checks

`task talos:check` runs, without secrets or a cluster, the patch convention check (`scripts/check-patches.sh`), the
config map freshness check and the shell tests (`tests/run.sh`). The same three run in CI
(`.github/workflows/talos-config.yaml`) on pull requests that touch `provision/talos/**`.
```

- [ ] **Step 4: Verify, including that the checks can fail**

```bash
task talos:check                                              # Expected: check-patches: ok / config-map: up to date / every test file "0 failed"
yamllint -c .github/linters/.yamllint.yaml .github/workflows/talos-config.yaml
prettier --ignore-unknown --config .github/linters/.prettierrc.yaml --check provision/talos/README.md

# negative 1: stale config map must fail
sed -i '0,/live/s//lively/' docs/src/talos/config-map.md
provision/talos/scripts/config-map.sh --check; echo "exit=$?"  # Expected: a diff, "stale", exit=1
git checkout docs/src/talos/config-map.md

# negative 2: a file without a header must fail
printf 'machine:\n  time:\n    disabled: false\n' > provision/talos/patches/all/99-no-header.yaml
provision/talos/scripts/check-patches.sh; echo "exit=$?"       # Expected: "missing or empty '# What:' header line" ..., exit=1
rm provision/talos/patches/all/99-no-header.yaml
```

- [ ] **Step 5: Commit, push, open PR C**

```bash
git add .github/workflows/talos-config.yaml .taskfiles/talos/Taskfile.yaml provision/talos/README.md
git commit -m "feat(talos): offline check task and CI workflow for the patch conventions and the config map"
git push -u origin HEAD
gh pr create --title "feat(talos): explain, config map, diff and CI checks for the patch layout" --body "$(cat <<BODY
Phase 1b of docs/superpowers/specs/2026-10-05-talos-config-layout-design.md.

- task talos:explain: what is configured per node, from the patch headers
- task talos:config-map: generated docs/src/talos/config-map.md (CI fails when stale)
- task talos:diff: repo vs the live nodes and the running version, secrets masked
- task talos:check and a CI workflow: patch conventions, config map freshness, shell tests

Current task talos:diff output (read-only; nv1's stored install image tag lags, a known item):

$(task talos:diff 2>&1 | tail -25)
BODY
)"
```

---

## Task 11: First deprecated-field migration, `machine.sysctls` to `SysctlConfig` (PR D)

Start after PR C is merged: `git fetch origin && git switch -c feat/talos-sysctlconfig origin/main`.

This is the worked example of the Phase 1c process. Talos documents that `SysctlConfig` merges with the legacy
`machine.sysctls` (the new document wins), so the two can coexist, and the document uses a `params:` map.

**Files:**

- Modify: `provision/talos/patches/controlplane/70-sysctls.yaml`, `provision/talos/patches/worker/20-sysctls.yaml`
- Modify: `docs/src/talos/config-map.md` (regenerated), `.plans/TODO.md`

**Interfaces:**

- Consumes: `task talos:generate`, `task talos:diff`, `task talos:apply`, `task talos:check`.
- Produces: the same kernel parameters on all nodes, expressed as `SysctlConfig` documents; the legacy `machine.sysctls` is gone from the rendered configs.

- [ ] **Step 1: Convert the two files**

`provision/talos/patches/controlplane/70-sysctls.yaml` (replace the whole file):

```yaml
# What:   inotify limits, 64 MiB socket buffers and 1024 hugepages
# Why:    Controllers and exporters hold many inotify watches; large socket buffers for network throughput;
#         hugepages for workloads that request them
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: SysctlConfig
params:
  fs.inotify.max_user_instances: "8192"
  fs.inotify.max_user_watches: "1048576"
  net.core.rmem_max: "67108864"
  net.core.wmem_max: "67108864"
  vm.nr_hugepages: "1024"
```

`provision/talos/patches/worker/20-sysctls.yaml` (replace the whole file):

```yaml
# What:   BPF JIT hardening
# Why:    Hardening setting carried over from the original worker template; not set on control planes
# Nodes:  workers
# Apply:  live
apiVersion: v1alpha1
kind: SysctlConfig
params:
  net.core.bpf_jit_harden: "1"
```

- [ ] **Step 2: Render, validate, and read the diff**

```bash
provision/talos/scripts/check-patches.sh                     # Expected: check-patches: ok
task talos:generate
talosctl validate --config provision/talos/clusterconfig/home-mc1.yaml --mode metal   # Expected: ... is valid for metal mode
talosctl validate --config provision/talos/clusterconfig/home-nv1.yaml --mode metal
out="$(mktemp -d)"
task talos:diff -- mc1 nv1 | tee "$out/diff.txt"
```

Expected for mc1: the live side (`-`) has the `sysctls:` block under `machine:` with the five values, the repo side (`+`) has a `- apiVersion: v1alpha1 / kind: SysctlConfig / params:` document with the same five values, and nothing else differs. nv1 shows the same shape for `net.core.bpf_jit_harden: "1"`, plus the known install-image tag line. Anything else in the diff: stop and investigate.

- [ ] **Step 3: Regenerate the config map, run the checks, commit**

```bash
task talos:config-map
task talos:check
```

In `.plans/TODO.md`, in the entry "Migrate deprecated v1alpha1 Talos config fields", at the start of the **Tier 1** bullet add: "Done: `machine.sysctls` -> `SysctlConfig` (PR for Task 11 of the layout plan)." and remove `machine.sysctls` -> `SysctlConfig`; from the list in that bullet.

```bash
git add -A
git commit -m "feat(talos): sysctls as SysctlConfig documents"
git push -u origin HEAD
gh pr create --title "feat(talos): migrate machine.sysctls to SysctlConfig" --body "$(cat <<BODY
First deprecated-field migration (Phase 1c): machine.sysctls becomes SysctlConfig documents. The values are unchanged; Talos merges the document with the legacy field and the document wins.

task talos:diff (live vs repo, secrets masked):

$(cat "$out/diff.txt")

Applied to the nodes one at a time after merge, each live (no reboot).
BODY
)"
rm -rf "$out"
```

- [ ] **Step 4: Apply, one node at a time, only with the user's go-ahead**

This changes node configuration, so stop and ask the user to confirm before the first apply, and again before each following node. For each node in the order mc1, mc2, mc3, nv1:

```bash
task talos:apply N=mc1                      # runs the cluster health gate first, then applies without reboot
talosctl read /proc/sys/fs/inotify/max_user_instances -n 192.168.48.2     # Expected: 8192 (workers: read net/core/bpf_jit_harden, Expected: 1)
task talos:diff -- mc1                      # Expected: mc1: no differences, running v1.14.2
```

Each sysctl is `live`: no reboot, no cordon. Continue with mc2 (`.3`), mc3 (`.4`) and nv1 (`.5`) only after the previous node's diff is clean and the cluster gate is green. nv1 will keep showing its known install-image tag lag until its config is applied; applying it here also brings the stored tag to `v1.14.0`.

---

## Self-Review

**Spec coverage** (spec section to task):

| Spec | Task |
|---|---|
| 1. Layout (layers, merge order, one document per file, deprecated fields as documents) | 3, 11 |
| 1. Base from `gen config`, contract pin | 1 (`TALOS_CONTRACT` in lib.sh), 4, 6 |
| 2. Secrets (Bitwarden env only, `.yaml.tpl` + allowlist, bundle in a temp file) | 1 (`TPL_VARS`), 2 (checks), 4 (render, unset variables, temp cleanup) |
| 3. Render pipeline | 4, 6 |
| 4. Parity gate (old vs new, new vs live, redaction, switch PR applies nothing) | 5, 6 |
| 5. Readability: headers | 2, 3 |
| 5. `task talos:explain` | 7 |
| 5. `task talos:diff` | 9 |
| 5. Generated config map and its CI freshness check | 8, 10 |
| 5. Pipeline README | 6 (written), 7 to 10 (extended) |
| 6. Sub-phases 1a, 1b, 1c | PR A (Tasks 1 to 5), PR B (6), PR C (7 to 10), PR D (11) |
| Phase 2 (tuppr) | Not in this plan: its own spec and plan, as the spec says |

Not covered here, by design: migrating the other deprecated fields (tiers in `.plans/TODO.md`), automatic config apply, nv1's boot-entry problem.

**Placeholder scan:** none left. Every code step contains the full code, and every PR description is built from the masked command output saved by the step before it.

**Type and name consistency:** `patch_files`, `patch_dirs`, `header_value`, `touches`, `expected_version`, `node_field`, `node_names`, `TPL_VARS`, `TALOS_CONTRACT` are defined in Task 1 and used with the same names in Tasks 2, 4, 7, 8 and 9; script names and task names (`talos:parity`, `talos:explain`, `talos:config-map`, `talos:diff`, `talos:check`) match everywhere they appear.

**Review Focus coverage:** items 1 and 5 have tests in Task 4; item 3 in Task 2; items 2 and 4 are verified by commands in Task 6 Step 7.
