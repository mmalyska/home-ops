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
mkfix; mkdir -p "$TMP/p/node/ghost"; sed 's/^# Nodes:.*/# Nodes:  ghost/' "$TMP/p/node/mc1/10-net.yaml.tpl" > "$TMP/p/node/ghost/10-net.yaml.tpl"
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
mkfix; sed -i 's/\${TALHELPER_CLUSTERDOMAIN}/$TALHELPER_CLUSTERDOMAIN/' "$TMP/p/node/mc1/10-net.yaml.tpl"
assert_fails "a variable without braces in a .tpl file fails" check

echo "-- layout"
mkfix; mkdir -p "$TMP/p/all/sub"; cp "$TMP/p/all/10-time.yaml" "$TMP/p/all/sub/20-time.yaml"
assert_fails "a file nested deeper than its layer fails (it would never be rendered)" check
finish
