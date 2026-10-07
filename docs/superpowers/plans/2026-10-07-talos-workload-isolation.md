# Talos Workload Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable Talos workload isolation (`SecurityProfileConfig` `workloadIsolation: true`) on mc3, then mc2 and mc1, with nv1 pinned to `false` until nv1 has been upgraded to v1.14.2 or later (its own task, the installer now exists).

**Architecture:** One patch file `65-security-profile.yaml` per layer: a pilot node patch on mc3 first, then consolidated into `patches/all/` with an explicit `false` override for nv1. A read-only script `scripts/isolation-check.sh` proves per node that the container plane really runs in the sandbox namespace (PID namespace depth from `/proc/<pid>/status`) and that the node is healthy. The rollout itself (apply, drain, reboot, uncordon, soak) is a gated manual procedure; the user confirms every step that changes the cluster.

**Tech Stack:** Talos 1.14.2 config documents, bash, yq, `talosctl`, kubectl, the shell tests under `provision/talos/tests/`, Prometheus instant queries.

**Spec:** `docs/superpowers/specs/2026-10-07-talos-workload-isolation-design.md`

## Global Constraints

- `TALOS_CONTRACT` stays `v1.13`. No secret, CA or key is touched, and no secret value is written to any tracked file (gitleaks blocks the commit).
- Every patch file starts with the header lines `# What:`, `# Why:`, `# Nodes:`, `# Apply:`; `# Nodes:` must equal the layer (`all nodes`, `control plane`, `workers` or the node name); `# Apply:` is `live`, `install-only` or `reboot`, optionally followed by `(reason)`. `scripts/check-patches.sh` enforces it. One YAML document per file.
- **Never apply config, drain, reboot or create/delete anything in the cluster without the user's explicit confirmation** for that step (CLAUDE.md hard rule). `talosctl reboot` is blocked for Claude by the permission settings: ask the user to run it with `!`.
- Read-only cluster access (`kubectl get`, `talosctl get/read/services/processes/logs/etcd status`) is free. The cluster is only reachable from the home network; if `kubectl get nodes` fails with a DNS or timeout error, stop and tell the user.
- One node at a time. Ceph must be exactly `HEALTH_OK` before each node's drain and after each node's uncordon, and the node's health gate (the `talosctl health` command of the internal `node_health` task, see Task 3 Step 6; `task talos:node_health` itself cannot be invoked) must pass before the next node.
- Never push to `main`; branch prefixes `feat/`, `fix/`, `chore/`, `docs/`; open the PR right after pushing. Run `task talos:check` before each commit that touches `provision/talos/`.
- Do not write the private cluster domain literally anywhere (comments, docs, memory, plan): the NFS server name is read from the live PV at run time.
- Memory edits go to `.claude/memory/` and are committed on the branch being worked on (CLAUDE.md "Memory").
- `git commit` can be blocked once by a hook that reformats a file; if `git log` does not show the commit, `git add -A` and commit again.
- Rollback, any node: set that node's `workloadIsolation` to `false` (or remove the file while it is the only patch), `task talos:apply N=<node>`, reboot. If a node cannot reach a healthy state after its reboot, stop the rollout and report; do not continue to the next node.

## Review Focus

- **nv1 ends up `true` by accident** (a consolidation mistake, or the v1.14 contract bump): tests in Task 4 assert nv1 is `false` on the pinned base and on a v1.14-contract base.
- **A node renders zero or two `SecurityProfileConfig` documents** (a stale mc3 file after consolidation): Task 1 and Task 4 tests count the documents per node.
- **The check passes although the reboot was skipped** (config says `true`, the processes still run on the host): `isolation-check.sh` decides on the PID namespace depth, not on the config alone; Task 2 has the test with config `true` and depth 1.
- **The check passes with `sandboxd` or Ceph unhealthy**: Task 2 tests a stopped `sandboxd`, a Ceph warning and a NotReady node.
- **Volumes or mounts break only on the isolated node** (RBD attach, NFS, node-exporter metrics): Task 3 runs pinned test pods for RBD and NFS and compares node-exporter series with the baseline.

---

## File Structure

| File                                                                                                        | Responsibility                                                          |
| ----------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `provision/talos/patches/node/mc3/65-security-profile.yaml`                                                 | Phase 1: the pilot document, mc3 only (removed in Task 4)               |
| `provision/talos/patches/all/65-security-profile.yaml`                                                      | Phase 2: the document for every node (`true`)                           |
| `provision/talos/patches/node/nv1/65-security-profile.yaml`                                                 | Phase 2: explicit `false` for nv1 (removed in the later nv1 phase)      |
| `provision/talos/scripts/isolation-check.sh`                                                                | Read-only per-node proof that isolation is on or off, plus basic health |
| `provision/talos/tests/test_isolation_check.sh`                                                             | Tests for the script with stubbed `talosctl` and `kubectl`              |
| `provision/talos/tests/test_render.sh`                                                                      | Render tests per phase and the contract-bump guard                      |
| `provision/talos/README.md`, `.claude/skills/talos-config-editing/SKILL.md`, `docs/src/talos/config-map.md` | Documentation (the config map is generated)                             |
| `.plans/TODO.md`, `.claude/memory/reference_talos_workload_isolation.md`, `.claude/memory/MEMORY.md`        | Tracking                                                                |

---

### Task 1: Phase 1 pilot patch for mc3, render tests, docs (PR 1)

**Files:**

- Create: `provision/talos/patches/node/mc3/65-security-profile.yaml`
- Modify: `provision/talos/tests/test_render.sh` (append before the final `finish`)
- Modify: `provision/talos/README.md` (new section before `## Checks`)
- Modify: `.claude/skills/talos-config-editing/SKILL.md` (one bullet)
- Regenerate: `docs/src/talos/config-map.md`

**Interfaces:**

- Produces: the layer file name `65-security-profile.yaml` in `patches/all/`, `patches/node/mc3/` and `patches/node/nv1/` (used by Task 4's guard through `patch_files`).

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull && git checkout -b feat/talos-workload-isolation-pilot
```

- [ ] **Step 2: Write the failing test**

Insert before the last line (`finish`) of `provision/talos/tests/test_render.sh`:

```bash
echo "-- workload isolation (phase 1: pilot on mc3 only)"
for n in mc1 mc2 mc3 nv1; do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
done
assert_eq "1|true" "$(yq 'select(.kind == "SecurityProfileConfig") | .kind' "$TMP/mc3.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "SecurityProfileConfig") | .workloadIsolation | tostring' "$TMP/mc3.yaml")" "mc3 has exactly one SecurityProfileConfig with workloadIsolation true"
assert_ok "mc3 output is a valid metal config" talosctl validate --config "$TMP/mc3.yaml" --mode metal
for n in mc1 mc2 nv1; do
  assert_eq "0" "$(yq 'select(.kind == "SecurityProfileConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')" "$n has no SecurityProfileConfig yet (isolation is off there)"
done
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd provision/talos && bash tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: `FAIL mc3 has exactly one SecurityProfileConfig with workloadIsolation true` and a non-zero failure count.

- [ ] **Step 4: Create the pilot patch**

`provision/talos/patches/node/mc3/65-security-profile.yaml`:

```yaml
# What:   Workload isolation on mc3: CRI, the kubelet and all pods run in the sandboxd PID and mount namespace, apart from machined (PID 1)
# Why:    Pilot of the cluster-wide rollout, see docs/superpowers/specs/2026-10-07-talos-workload-isolation-design.md.
#         sandboxd reads the setting only when it starts, so the node needs a reboot after the apply. Phase 2 moves this
#         document to patches/all/65-security-profile.yaml and deletes this file
# Nodes:  mc3
# Apply:  reboot (sandboxd reads workloadIsolation only when the service starts)
apiVersion: v1alpha1
kind: SecurityProfileConfig
workloadIsolation: true
```

- [ ] **Step 5: Run the tests**

Run: `cd provision/talos && scripts/check-patches.sh && bash tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: `check-patches: ok`, and `0 failed`.

- [ ] **Step 6: Regenerate the config map**

Run: `cd /workspaces/home-ops && task talos:config-map && git diff --stat docs/src/talos/config-map.md`
Expected: one new row for `patches/node/mc3/65-security-profile.yaml` with `SecurityProfileConfig`, apply `reboot`.

- [ ] **Step 7: README section**

Insert before the line `## Checks` in `provision/talos/README.md`:

```markdown
## Workload isolation

`SecurityProfileConfig` with `workloadIsolation: true` runs CRI containerd, the kubelet and every pod in their own PID and
mount namespace, anchored by the `sandboxd` service, instead of sharing the namespaces of `machined` (PID 1). It is rolled
out node by node (spec `docs/superpowers/specs/2026-10-07-talos-workload-isolation-design.md`, plan
`docs/superpowers/plans/2026-10-07-talos-workload-isolation.md`). Current state: pilot on mc3 only
(`patches/node/mc3/65-security-profile.yaml`); the other nodes have no document, so isolation is off there.

- **A reboot is needed.** `sandboxd` reads the setting only when it starts, so apply, cordon, drain, reboot, uncordon, in
  both directions. Rollback is the same with `workloadIsolation: false`.
- **The v1.14 contract bump would turn it on.** `talosctl gen config` emits the document with `true` only for the v1.14
  contract. Until phase 2 adds the all-layer document and the nv1 `false` override, do not bump `TALOS_CONTRACT`: mc1,
  mc2 and nv1 have no document and would get the base's `true`. Phase 2 makes the setting explicit for every node, after
  which the bump changes nothing.
- **nv1 stays off** until it has soaked on v1.14.2 (it was upgraded on 2026-10-07): v1.14.0 had a boot bug with
  isolation (CRI restart-loops for 1-3 minutes on every boot, siderolabs/talos#14374), and the GPU stack must be
  verified on the new version first.
- **Check a node:** `scripts/isolation-check.sh <node> [on|off]` is read-only. It checks the PID namespace of containerd
  and the kubelet (`NSpid` in `/proc/<pid>/status` has two values inside the sandbox), the live config, the Talos
  services, node readiness, Ceph and etcd. A config that says `true` without a reboot fails it.
```

- [ ] **Step 8: Skill bullet**

In `.claude/skills/talos-config-editing/SKILL.md`, insert this bullet before the line starting `- A new document can also remove things Talos adds implicitly`:

```markdown
- `SecurityProfileConfig` (`workloadIsolation`) is read only when the `sandboxd` service starts, so a change needs a node reboot (`Apply: reboot`). The v1.14 contract base carries it with `true`, the pinned v1.13 base does not: keep the setting explicit per node (see the README section "Workload isolation") so a contract bump cannot flip it.
```

- [ ] **Step 9: Verify and commit**

Run: `cd /workspaces/home-ops && task talos:check 2>&1 | tail -3`
Expected: `0 failed`, the config-map check passes.

```bash
git add -A && git commit -m "feat(talos): pilot workload isolation on mc3 (SecurityProfileConfig)" && git push -u origin HEAD && gh pr create --fill --base main
```

---

### Task 2: `isolation-check.sh` and its tests (same PR 1)

**Files:**

- Create: `provision/talos/scripts/isolation-check.sh`
- Create: `provision/talos/tests/test_isolation_check.sh`

**Interfaces:**

- Consumes: `node_field` from `scripts/lib.sh` (`node_field <node> ip`).
- Produces: `scripts/isolation-check.sh <node> [on|off]`; exit 0 when every check passes, 1 when any fails, 2 on a usage error or an unknown node. Prints `  ok   <name>` or `  FAIL <name>` per check. Used by Tasks 3 and 5.

- [ ] **Step 1: Write the failing test**

`provision/talos/tests/test_isolation_check.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/isolation-check.sh with stubbed talosctl and kubectl
source "$(dirname "$0")/lib.sh"
SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Canned answers, selected by STUB_* variables (defaults describe a healthy isolated node)
cat > "$TMP/bin/talosctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *" processes")
    echo "NODE PID STATE THREADS CPU-TIME VIRTMEM RESMEM ARGS"
    echo "192.168.48.4 135 S 12 1.0 1.5GB 70MB /sbin/sandboxd"
    echo "192.168.48.4 148 S 12 1.0 1.5GB 70MB /bin/containerd --address /system/run/containerd/containerd.sock --state /system/run/containerd --root /system"
    echo "192.168.48.4 48397 S 20 1.0 1.6GB 216MB /bin/containerd --address /run/containerd/containerd.sock --config /etc/cri/containerd.toml"
    echo "192.168.48.4 552 S 105 1.0 5.6GB 230MB /usr/local/bin/kubelet --config=/etc/kubernetes/kubelet.yaml"
    ;;
  *"read /proc/"*)
    # per PID: 148 is the system containerd (always host namespace), 552 the kubelet, anything else the CRI containerd
    args="$*"; pid="${args##*/proc/}"; pid="${pid%%/*}"
    case "$pid" in
      148) v=1 ;;
      552) v="${STUB_NSPID_KUBELET:-${STUB_NSPID:-2}}" ;;
      *) v="${STUB_NSPID:-2}" ;;
    esac
    if [ "$v" = "2" ]; then printf 'Name:\tx\nNSpid:\t%s\t12\n' "$pid"; else printf 'Name:\tx\nNSpid:\t%s\n' "$pid"; fi
    ;;
  *" services")
    echo "NODE SERVICE STATE HEALTH LAST-CHANGE LAST-EVENT"
    echo "192.168.48.4 cri Running OK 1h ok"
    echo "192.168.48.4 kubelet Running OK 1h ok"
    echo "192.168.48.4 sandboxd ${STUB_SANDBOXD:-Running} OK 1h ok"
    ;;
  *"get machineconfig"*)
    echo "spec: |"
    echo "  version: v1alpha1"
    echo "  machine: {}"
    case "${STUB_CONFIG:-true}" in
      none) ;;
      *) printf '  ---\n  apiVersion: v1alpha1\n  kind: SecurityProfileConfig\n  workloadIsolation: %s\n' "${STUB_CONFIG:-true}" ;;
    esac
    ;;
  *"etcd status") exit "${STUB_ETCD_RC:-0}" ;;
esac
SH
cat > "$TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get node"*) printf '%s' "${STUB_READY:-True}" ;;
  *"get cephcluster"*) printf '%s' "${STUB_CEPH:-HEALTH_OK}" ;;
esac
SH
chmod +x "$TMP/bin/talosctl" "$TMP/bin/kubectl"
cat > "$TMP/run.sh" <<SH
#!/usr/bin/env bash
PATH="$TMP/bin:\$PATH" exec "$SCRIPTS/isolation-check.sh" "\$@"
SH
chmod +x "$TMP/run.sh"
run() { "$TMP/run.sh" "$@"; }

echo "-- a healthy isolated node"
assert_ok "an isolated node passes the check for on" run mc3 on
assert_ok "on is the default expectation" run mc3
out="$(run mc3 on 2>&1)"
assert_contains "$out" "containerd runs in the sandbox PID namespace" "reports the containerd namespace"
assert_contains "$out" "kubelet runs in the sandbox PID namespace" "reports the kubelet namespace"

echo "-- an isolated node checked for off, and the reverse"
assert_fails "isolated processes fail the check for off" env STUB_CONFIG=false "$TMP/run.sh" mc3 off
assert_fails "host processes fail the check for on" env STUB_NSPID=1 "$TMP/run.sh" mc3 on
assert_ok "a node with no document and host processes passes the check for off" env STUB_NSPID=1 STUB_CONFIG=none "$TMP/run.sh" mc3 off
assert_ok "a node with workloadIsolation false and host processes passes the check for off" env STUB_NSPID=1 STUB_CONFIG=false "$TMP/run.sh" mc3 off

echo "-- the kubelet alone in the wrong namespace (the CRI containerd is told apart from the system one)"
out="$(env STUB_NSPID=2 STUB_NSPID_KUBELET=1 "$TMP/run.sh" mc3 on 2>&1 || true)"
assert_contains "$out" "FAIL kubelet runs in the sandbox PID namespace" "a kubelet on the host fails the check for on"
assert_not_contains "$out" "FAIL containerd runs in the sandbox PID namespace" "the CRI containerd is still seen as isolated"
out="$(env STUB_NSPID=1 STUB_NSPID_KUBELET=2 "$TMP/run.sh" mc3 off 2>&1 || true)"
assert_contains "$out" "FAIL kubelet runs in the host PID namespace" "an isolated kubelet fails the check for off"

echo "-- the apply without a reboot (config true, processes still on the host)"
out="$(env STUB_NSPID=1 STUB_CONFIG=true "$TMP/run.sh" mc3 on 2>&1 || true)"
assert_contains "$out" "FAIL containerd runs in the sandbox PID namespace" "the namespace check fails although the config says true"
assert_fails "the apply without a reboot fails the check for on" env STUB_NSPID=1 STUB_CONFIG=true "$TMP/run.sh" mc3 on

echo "-- health"
assert_fails "a stopped sandboxd fails the check for on" env STUB_SANDBOXD=Finished "$TMP/run.sh" mc3 on
assert_fails "a Ceph warning fails the check" env STUB_CEPH=HEALTH_WARN "$TMP/run.sh" mc3 on
assert_fails "a NotReady node fails the check" env STUB_READY=False "$TMP/run.sh" mc3 on
assert_fails "an etcd error on a control plane fails the check" env STUB_ETCD_RC=1 "$TMP/run.sh" mc3 on

echo "-- usage"
assert_fails "an unknown node fails" run nope on
assert_fails "no node fails" run
assert_fails "an unknown expectation fails" run mc3 maybe
finish
```

- [ ] **Step 2: Run it to see it fail**

Run: `cd provision/talos && bash tests/test_isolation_check.sh 2>&1 | tail -5`
Expected: failures such as `command failed` (the script does not exist yet).

- [ ] **Step 3: Write the script**

`provision/talos/scripts/isolation-check.sh`:

```bash
#!/usr/bin/env bash
# isolation-check.sh <node> [on|off]
# Read-only checks that a node runs (on, the default) or does not run (off) its container plane in the sandboxd
# namespace, plus basic health: Talos services, node readiness, Ceph, and etcd on a control plane. Exit 1 when any
# check fails, 2 on a usage error. The namespace is read from /proc/<pid>/status: NSpid lists one PID on the host
# namespace and two inside the sandbox, so a config that says true but was never rebooted still fails.
# Needs yq, talosctl (TALOSCONFIG defaults to clusterconfig/talosconfig) and kubectl on a reachable cluster.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export TALOSCONFIG="${TALOSCONFIG:-$TALOS_DIR/clusterconfig/talosconfig}"

node="${1:-}"; expect="${2:-on}"
[ -n "$node" ] || { echo "usage: isolation-check.sh <node> [on|off]" >&2; exit 2; }
[[ "$expect" == on || "$expect" == off ]] || { echo "expectation must be on or off, got '$expect'" >&2; exit 2; }
ip="$(node_field "$node" ip)"
[ -n "$ip" ] || { echo "unknown node: $node" >&2; exit 2; }
type="$(node_field "$node" type)"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

# pid_of <pattern>: PID of the first process whose command line matches
pid_of() { talosctl -n "$ip" processes 2>/dev/null | awk -v pat="$1" '$0 ~ pat { print $2; exit }'; }

# depth_of <pid>: number of PID namespaces the process is in, 1 on the host namespace and 2 inside the sandbox
depth_of() { talosctl -n "$ip" read "/proc/$1/status" 2>/dev/null | awk '/^NSpid:/ { print NF - 1; found = 1 } END { if (!found) print 0 }'; }

want_depth=1; [ "$expect" = on ] && want_depth=2
for proc in "containerd:/bin/containerd --address /run/containerd/containerd.sock" "kubelet:/usr/local/bin/kubelet --"; do
  name="${proc%%:*}"; pattern="${proc#*:}"
  pid="$(pid_of "$pattern")"
  if [ -z "$pid" ]; then bad "$name process not found"; continue; fi
  depth="$(depth_of "$pid")"
  if [ "$depth" = "$want_depth" ]; then
    if [ "$expect" = on ]; then ok "$name runs in the sandbox PID namespace (pid $pid)"; else ok "$name runs in the host PID namespace (pid $pid)"; fi
  elif [ "$expect" = on ]; then bad "$name runs in the sandbox PID namespace (pid $pid has $depth namespace(s), expected 2)"
  else bad "$name runs in the host PID namespace (pid $pid has $depth namespace(s), expected 1)"
  fi
done

# live config: workloadIsolation must be true for on; absent or false for off
live="$(talosctl -n "$ip" get machineconfig v1alpha1 -o yaml 2>/dev/null | yq '.spec' | yq -N 'select(.kind == "SecurityProfileConfig") | .workloadIsolation')"
if [ "$expect" = on ]; then
  [ "$live" = "true" ] && ok "live config has workloadIsolation true" || bad "live config has workloadIsolation true (got '${live:-absent}')"
else
  { [ -z "$live" ] || [ "$live" = "false" ]; } && ok "live config has no isolation (${live:-absent})" || bad "live config has no isolation (got '$live')"
fi

# Talos services: cri and kubelet always, sandboxd when isolation is expected
svc_ok() { talosctl -n "$ip" services 2>/dev/null | awk -v s="$1" '$2 == s && $3 == "Running" && $4 == "OK" { found = 1 } END { exit !found }'; }
for svc in cri kubelet; do
  svc_ok "$svc" && ok "service $svc is Running and OK" || bad "service $svc is Running and OK"
done
if [ "$expect" = on ]; then
  svc_ok sandboxd && ok "service sandboxd is Running and OK" || bad "service sandboxd is Running and OK"
fi

ready="$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
[ "$ready" = "True" ] && ok "node $node is Ready" || bad "node $node is Ready (got '${ready:-unknown}')"

ceph="$(kubectl -n rook-ceph get cephcluster -o jsonpath='{.items[0].status.ceph.health}' 2>/dev/null)"
[ "$ceph" = "HEALTH_OK" ] && ok "Ceph is HEALTH_OK" || bad "Ceph is HEALTH_OK (got '${ceph:-unknown}')"

if [ "$type" = controlplane ]; then
  talosctl -n "$ip" etcd status >/dev/null 2>&1 && ok "etcd status answers" || bad "etcd status answers"
fi

[ "$fails" -eq 0 ] || { echo "isolation-check: $fails check(s) failed" >&2; exit 1; }
echo "isolation-check: $node ok ($expect)"
```

Then `chmod +x provision/talos/scripts/isolation-check.sh`.

- [ ] **Step 4: Run the tests**

Run: `cd provision/talos && bash tests/test_isolation_check.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: `0 failed`. If a stub scenario fails, fix the script, not the assertion.

- [ ] **Step 5: Run against the live cluster (read-only), only when `kubectl get nodes` works**

Run: `cd /workspaces/home-ops && provision/talos/scripts/isolation-check.sh mc3 off; provision/talos/scripts/isolation-check.sh mc1 off`
Expected: every line `ok`, `isolation-check: mc3 ok (off)`. (Before the rollout all nodes are off, and `sandboxd` is only required for `on`.) If the real output format differs from the stubs (column positions in `talosctl processes` or `services`), fix the script and the stub together.
Checked on 2026-10-07 against the live cluster: `mc3 off`, `mc1 off` and `nv1 off` pass, and `mc3 on` fails exactly the two namespace lines and the live-config line (isolation is not enabled yet), so the parsing matches the real `talosctl` output.

- [ ] **Step 6: Full check and commit (on the Task 1 branch)**

Run: `cd /workspaces/home-ops && task talos:check 2>&1 | tail -3`
Expected: `0 failed`.

```bash
git add -A && git commit -m "feat(talos): isolation-check.sh, a read-only proof that a node runs isolated or not" && git push
```

---

### Task 3: Phase 0 and phase 1 rollout on mc3 (gated, manual)

**Files:** none in the repo (the baseline files live in the scratchpad directory; the Task 4 PR records the result).

**Interfaces:**

- Consumes: `scripts/isolation-check.sh <node> [on|off]` (Task 2), `task talos:apply N=<node>`, the `talosctl health` command from Step 6 below, the merged PR 1.
- Produces: a go/no-go decision from the user for Task 4.

Every step that changes the cluster waits for the user's explicit yes. Set these in each shell:

```bash
cd /workspaces/home-ops
export TALOSCONFIG=$PWD/provision/talos/clusterconfig/talosconfig
S=$HOME/isolation-baseline; mkdir -p $S/isolation   # a devcontainer rebuild loses this directory: copy the baseline summary into the PR 1 description (step 1)
NODE=mc3; IP=192.168.48.4
pq() { curl -s 'http://localhost:9090/api/v1/query' --data-urlencode "query=$1" | jq -r '.data.result[] | [(.metric | to_entries | map("\(.key)=\(.value)") | sort | join(",")), .value[1]] | @tsv' | sort; }
```

- [ ] **Step 1: Phase 0 baseline (read-only)**

```bash
kubectl get nodes -o wide
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status | head -12     # HEALTH_OK required
provision/talos/scripts/isolation-check.sh $NODE off | tee $S/isolation/$NODE-check-before.txt
kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running") | .metadata.namespace' | sort | uniq -c > $S/isolation/running-per-ns-before.txt
kubectl get pods -A --field-selector spec.nodeName=$NODE --no-headers | awk '{print $1"/"$2" "$4}' | sort > $S/isolation/$NODE-pods-before.txt
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 3
I="192.168.48.4(:.*)?"
pq "up{job=\"node-exporter\",instance=~\"$I\"}" > $S/isolation/$NODE-prom-up-before.txt
pq "count by (mountpoint,device,fstype)(node_filesystem_size_bytes{job=\"node-exporter\",instance=~\"$I\",fstype!~\"tmpfs|rootfs|overlay|squashfs|fuse.*\"})" > $S/isolation/$NODE-prom-fs-before.txt
pq "count by (device)(node_disk_io_time_seconds_total{job=\"node-exporter\",instance=~\"$I\",device!~\"rbd.*|dm-.*|loop.*\"})" > $S/isolation/$NODE-prom-disks-before.txt
pkill -f "port-forward svc/prometheus-stack-kube-prom-prometheus"
wc -l $S/isolation/*
```

Copy the contents of the three `*-prom-*-before.txt` files and `running-per-ns-before.txt` into a comment on PR 1 (no secrets in them) so the comparison survives a devcontainer rebuild during the 48 hour soak.

Expected: the check prints `isolation-check: mc3 ok (off)`; Ceph `HEALTH_OK`; `prom-up` has one line with value `1`; `prom-fs` lists the real mount points (`/var` on `nvme0n1p4` among them); `prom-disks` lists `nvme0n1` and `sda`. If a Prometheus file is empty, the label selector is wrong: run `pq 'up{job="node-exporter"}'` and fix `$I`, then redo. Do not continue with empty baselines.

- [ ] **Step 2: Wait for PR 1 to be merged, then re-render and diff (read-only)**

```bash
git checkout main && git pull
task talos:generate && task talos:diff -- mc3
```

Expected: the diff for mc3 shows only the new `SecurityProfileConfig` document with `workloadIsolation: true`; nothing else differs. If anything else differs, stop and report it.

- [ ] **Step 3: Apply to mc3 (live, no reboot) — ask the user first**

```bash
task talos:apply N=mc3
talosctl -n $IP get machineconfig v1alpha1 -o yaml | yq '.spec' | yq -N 'select(.kind == "SecurityProfileConfig")'
provision/talos/scripts/isolation-check.sh $NODE on || true
```

Expected: the document is printed with `workloadIsolation: true`. The check for `on` **fails** at this point on the two namespace lines (the processes still run on the host until the reboot); that failure is the proof the check works. Everything else is `ok`.

- [ ] **Step 4: Cordon and drain mc3 — ask the user first**

```bash
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=10m
```

Expected: the drain finishes. A drain stuck on a CNPG primary means a replica is unhealthy: fix the replica first, do not force the drain. Ceph must still be `HEALTH_OK` (`kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status`).

- [ ] **Step 5: The user reboots mc3**

Ask the user to run: `! TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig talosctl reboot --nodes 192.168.48.4 --wait`. Wait until `kubectl get node mc3` shows Ready.

- [ ] **Step 6: Uncordon and gate**

```bash
kubectl uncordon $NODE
talosctl --nodes $IP health --control-plane-nodes 192.168.48.2,192.168.48.3,192.168.48.4 --worker-nodes 192.168.48.5 --wait-timeout=4m --server=false   # what the internal node_health task runs for a control plane
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status | head -12
provision/talos/scripts/isolation-check.sh $NODE on | tee $S/isolation/$NODE-check-after.txt
talosctl -n $IP logs sandboxd | tail -5
kubectl -n kube-system get pods -o wide --field-selector spec.nodeName=$NODE | grep -E 'cilium|multus'
```

Expected: the health command exits 0; the cilium agent, cilium-envoy and multus pods on mc3 are `Running` and ready; Ceph returns to `HEALTH_OK` (the CephCluster status lags the real health by about a minute); `isolation-check: mc3 ok (on)` with both namespace lines `ok`; `sandboxd` logs `started as PID 1 of the sandbox namespace`. If any of this fails: roll back (Global Constraints) and stop.

If only the Ceph line of `isolation-check` fails right after the uncordon, wait a minute and rerun it: the check reads the `CephCluster` status, which lags the real health (`ceph health` says `HEALTH_OK` first).

- [ ] **Step 7: Active checks with test pods pinned to mc3 — ask the user first (creates and deletes a namespace, a PVC and two pods)**

```bash
export NODE NFS_SERVER="$(kubectl get pv bookorbit-ebooks-pv -o jsonpath='{.spec.nfs.server}')" NFS_PATH="$(kubectl get pv bookorbit-ebooks-pv -o jsonpath='{.spec.nfs.path}')"
envsubst '${NODE} ${NFS_SERVER} ${NFS_PATH}' <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: isolation-check
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rbd-probe
  namespace: isolation-check
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ceph-block
  resources:
    requests:
      storage: 100Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: rbd-probe
  namespace: isolation-check
spec:
  nodeName: ${NODE}
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: busybox:1.38@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
      command: ["sh", "-c", "echo ok > /data/probe && grep -q ok /data/probe && echo RBD-OK"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: data, mountPath: /data}]
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: rbd-probe}
---
apiVersion: v1
kind: Pod
metadata:
  name: nfs-probe
  namespace: isolation-check
spec:
  nodeName: ${NODE}
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: {type: RuntimeDefault}
  containers:
    - name: probe
      image: busybox:1.38@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e
      command: ["sh", "-c", "grep -q ' /mnt nfs' /proc/mounts && echo NFS-OK"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
      volumeMounts: [{name: share, mountPath: /mnt, readOnly: true}]
  volumes:
    - name: share
      nfs: {server: "${NFS_SERVER}", path: "${NFS_PATH}", readOnly: true}
YAML
kubectl -n isolation-check wait --for=jsonpath='{.status.phase}'=Succeeded pod/rbd-probe pod/nfs-probe --timeout=5m
kubectl -n isolation-check get pods -o wide
```

The image digest must be the multi-arch index (`fd7dc986…`). The `365a051f…` digest that the nvidia pods use is busybox's arm64-only child manifest and fails with `exec format error` on the amd64 control planes (found 2026-10-07). A PodSecurity `restricted` warning about the NFS volume is expected (the namespace enforces `baseline`).

Expected: both pods `Succeeded` on mc3 (the RBD volume attached and was written, the in-tree NFS volume was mounted by the kubelet inside the sandbox). On failure keep the pods for diagnosis, `kubectl -n isolation-check describe pod <name>`, and treat it as a failed gate. Clean up once the user agrees: `kubectl delete namespace isolation-check` (this also deletes the PVC and its RBD image).

- [ ] **Step 7b: Red test, the isolation boundary — ask the user first (creates and deletes two privileged `hostPID` pods in `kube-system`, read-only commands)**

Run the same probe on the node just isolated (`$NODE`) and on a control that still runs without isolation (mc1 while it is still off; after that nv1). The control proves the probe can see `machined` at all, so the isolated result cannot pass vacuously.

```bash
IMG='busybox:1.38@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e'
for N in <control node> $NODE; do export NODE=$N IMG; envsubst '${NODE} ${IMG}' <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: isolation-probe-${NODE}
  namespace: kube-system
spec:
  nodeName: ${NODE}
  restartPolicy: Never
  hostPID: true
  tolerations:
    - operator: Exists
  containers:
    - name: probe
      image: ${IMG}
      securityContext:
        privileged: true
      command:
        - sh
        - -c
        - |
          echo "pid1 comm      : $(cat /proc/1/comm)"
          echo "pid1 cmdline   : $(tr '\0' ' ' < /proc/1/cmdline | cut -c1-60)"
          echo "pid1 pidns     : $(readlink /proc/1/ns/pid)   (own: $(readlink /proc/self/ns/pid))"
          echo "processes seen : $(ls -d /proc/[0-9]* | wc -l)"
          for n in init apid etcd sandboxd containerd kubelet; do
            echo "visible $n$(printf '%*s' $((11 - ${#n})) '')  : $(grep -l -x -s "$n" /proc/[0-9]*/comm | wc -l)"
          done
          echo "pid1 fds read  : $(ls /proc/1/fd 2>/dev/null | wc -l)"
          echo "pid1 mounts    : $(wc -l < /proc/1/mountinfo)"
          echo DONE
YAML
done
for N in <control node> $NODE; do kubectl -n kube-system wait --for=jsonpath='{.status.phase}'=Succeeded pod/isolation-probe-$N --timeout=3m; echo "######## $N"; kubectl -n kube-system logs isolation-probe-$N; done
kubectl -n kube-system delete pod isolation-probe-<control node> isolation-probe-$NODE
```

Expected (measured on 2026-10-07, mc1 as the control and mc3 isolated; counts vary with the workload, the pattern is what matters):

| Line                                    | Control (isolation off) | Isolated node                                  |
| --------------------------------------- | ----------------------- | ---------------------------------------------- |
| `pid1 comm`                             | `init` (machined)       | `sandboxd`                                     |
| `visible init`, `visible apid`          | 1, 1                    | **0, 0**                                       |
| `visible etcd` (control planes)         | 1                       | 1 (etcd runs inside the sandbox, see the spec) |
| `visible containerd`, `visible kubelet` | present                 | present                                        |
| `pid1 fds read`                         | hundreds (209)          | a handful (13, sandboxd's own)                 |
| `processes seen`                        | all of the host (615)   | the sandbox only (86)                          |

The step passes only when the control shows `init` and `apid` visible **and** the isolated node shows both at 0 with `pid1 comm` = `sandboxd`. If the control does not see `machined`, the probe is broken and says nothing about isolation.

- [ ] **Step 8: Compare with the baseline (read-only)**

```bash
kubectl get pods -A -o json | jq -r '.items[] | select(.status.phase=="Running") | .metadata.namespace' | sort | uniq -c > $S/isolation/running-per-ns-after.txt
diff $S/isolation/running-per-ns-before.txt $S/isolation/running-per-ns-after.txt && echo "same running pods per namespace"
kubectl get pods -A --no-headers | awk '$4 !~ /Running|Completed|Succeeded/ {print}' | head
kubectl -n monitoring port-forward svc/prometheus-stack-kube-prom-prometheus 9090:9090 >/dev/null 2>&1 &
sleep 3
pq "up{job=\"node-exporter\",instance=~\"$I\"}" > $S/isolation/$NODE-prom-up-after.txt
pq "count by (mountpoint,device,fstype)(node_filesystem_size_bytes{job=\"node-exporter\",instance=~\"$I\",fstype!~\"tmpfs|rootfs|overlay|squashfs|fuse.*\"})" > $S/isolation/$NODE-prom-fs-after.txt
pq "count by (device)(node_disk_io_time_seconds_total{job=\"node-exporter\",instance=~\"$I\",device!~\"rbd.*|dm-.*|loop.*\"})" > $S/isolation/$NODE-prom-disks-after.txt
pkill -f "port-forward svc/prometheus-stack-kube-prom-prometheus"
for k in up fs disks; do echo "== $k"; diff $S/isolation/$NODE-prom-$k-before.txt $S/isolation/$NODE-prom-$k-after.txt && echo same; done
```

Expected: running pods per namespace identical (the drain moved pods and the uncordon let them come back, give it a few minutes); no pod in a bad state; the three Prometheus comparisons `same`. A difference in `fs` or `disks` is the node-exporter effect the spec names: record exactly what changed and let the user decide (it is not automatically a failure). Also open Alertmanager and confirm no new alert fired for mc3.

- [ ] **Step 9: Soak (about 48 hours), then the gate**

Wait about 48 hours. After the nights in between, check that the scheduled jobs ran on schedule: the CNPG backups (`kubectl get backups.postgresql.cnpg.io -A --sort-by=.metadata.creationTimestamp | tail`, schedules 00:00-00:55), the volsync syncs (anytype 02:00-03:00, the `*/6h` ones: `kubectl get replicationsources -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,LAST:.status.lastSyncTime`), `talos-backup` (hourly: `kubectl -n talos-backup get jobs`), and re-run `provision/talos/scripts/isolation-check.sh mc3 on`. Report to the user and ask for the go. **Task 4 starts only after an explicit go.**

---

### Task 4: Phase 2 repo change: consolidate, nv1 false, guard (PR 2)

**Files:**

- Create: `provision/talos/patches/all/65-security-profile.yaml`
- Create: `provision/talos/patches/node/nv1/65-security-profile.yaml`
- Delete: `provision/talos/patches/node/mc3/65-security-profile.yaml`
- Modify: `provision/talos/tests/test_render.sh` (replace the phase 1 section)
- Modify: `provision/talos/README.md` (the "Workload isolation" section)
- Regenerate: `docs/src/talos/config-map.md`

**Interfaces:**

- Consumes: `patch_files <node>` and `node_names` and `node_field` from `scripts/lib.sh`; the file name `65-security-profile.yaml` (Task 1).

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull && git checkout -b feat/talos-workload-isolation-rollout
```

- [ ] **Step 2: Write the failing tests**

In `provision/talos/tests/test_render.sh` replace the whole `-- workload isolation (phase 1: pilot on mc3 only)` section (added in Task 1) with:

```bash
echo "-- workload isolation (on for the control planes, explicitly off on nv1)"
source "$SCRIPTS/lib.sh"
for n in mc1 mc2 mc3 nv1; do
  [ -f "$TMP/$n.yaml" ] || render "$n" >/dev/null 2>&1
  want=true; [ "$n" = nv1 ] && want=false
  assert_eq "1|$want" "$(yq 'select(.kind == "SecurityProfileConfig") | .kind' "$TMP/$n.yaml" | wc -l | tr -d ' ')|$(yq 'select(.kind == "SecurityProfileConfig") | .workloadIsolation | tostring' "$TMP/$n.yaml")" "$n has exactly one SecurityProfileConfig with workloadIsolation $want"
  assert_ok "$n output is a valid metal config" talosctl validate --config "$TMP/$n.yaml" --mode metal
done

echo "-- workload isolation survives the v1.14 contract bump"
# The v1.14 base already carries the document with true. The layer files for each node, applied over that base in
# merge order, must give true on the control planes and false on nv1.
gen14="$TMP/gen14"
talosctl gen config isolation-guard https://192.0.2.1:6443 --talos-version v1.14 -o "$gen14" >/dev/null 2>&1
assert_eq "1" "$(yq 'select(.kind == "SecurityProfileConfig") | .kind' "$gen14/worker.yaml" | wc -l | tr -d ' ')" "the v1.14 contract base carries a SecurityProfileConfig (the premise of this guard)"
for n in mc1 mc2 mc3 nv1; do
  cur="$gen14/$(node_field "$n" type).yaml"; i=0
  while IFS= read -r f; do
    i=$((i + 1)); talosctl machineconfig patch "$cur" --patch "@$f" -o "$TMP/g14-$n-$i.yaml" >/dev/null 2>&1; cur="$TMP/g14-$n-$i.yaml"
  done < <(patch_files "$n" | grep '/65-security-profile.yaml$')
  want=true; [ "$n" = nv1 ] && want=false
  assert_eq "$want" "$(yq 'select(.kind == "SecurityProfileConfig") | .workloadIsolation | tostring' "$cur")" "$n keeps workloadIsolation $want on a v1.14-contract base (the contract bump cannot flip it)"
done
```

- [ ] **Step 3: Run it to see it fail**

Run: `cd provision/talos && bash tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: failures for mc1, mc2 (no document), nv1 (no document), and the guard lines. (mc3 still has its pilot file.)

- [ ] **Step 4: Move the files**

```bash
cd /workspaces/home-ops/provision/talos/patches
git rm node/mc3/65-security-profile.yaml
cat > all/65-security-profile.yaml <<'YAML'
# What:   Workload isolation: CRI, the kubelet and all pods run in the sandboxd PID and mount namespace, apart from machined (PID 1)
# Why:    Separates the container plane from machined and its file descriptors, see
#         docs/superpowers/specs/2026-10-07-talos-workload-isolation-design.md. sandboxd reads the setting only when it
#         starts, so a node needs a reboot after the apply. The setting is explicit for every node because the v1.14
#         contract base turns it on by itself; nv1 overrides it with false (node/nv1/65-security-profile.yaml)
# Nodes:  all nodes
# Apply:  reboot (sandboxd reads workloadIsolation only when the service starts)
apiVersion: v1alpha1
kind: SecurityProfileConfig
workloadIsolation: true
YAML
cat > node/nv1/65-security-profile.yaml <<'YAML'
# What:   Workload isolation stays off on nv1: CRI, the kubelet and all pods keep sharing machined's namespaces
# Why:    nv1 runs Talos v1.14.0, where isolation has a boot bug (CRI restart-loops for 1-3 minutes on every boot,
#         siderolabs/talos#14374, fixed in v1.14.2), and nv1 has not been upgraded to v1.14.2 yet. Explicit false rather
#         than no file: the v1.14 contract base would turn it on. Delete this file when nv1 runs v1.14.2 or later
# Nodes:  nv1
# Apply:  live (it only restates the current state; the later change that enables isolation needs a reboot)
apiVersion: v1alpha1
kind: SecurityProfileConfig
workloadIsolation: false
YAML
cd .. && scripts/check-patches.sh
```

Expected: `check-patches: ok`.

- [ ] **Step 5: Run the tests**

Run: `cd provision/talos && bash tests/test_render.sh 2>&1 | grep -E "FAIL|tests,"`
Expected: `0 failed`, including the guard lines for all four nodes.

- [ ] **Step 6: README section**

In `provision/talos/README.md` replace the sentence `Current state: pilot on mc3 only` through the end of that sentence (`so isolation is off there.`) with:

```markdown
Current state: on for mc1-mc3 once each has been rebooted (`patches/all/65-security-profile.yaml`), explicitly off on nv1
(`patches/node/nv1/65-security-profile.yaml`).
```

Also replace the second and third sentences of the `**The v1.14 contract bump would turn it on.**` bullet (`Until phase 2 ... would get the base's `true`. Phase 2 makes the setting explicit ... changes nothing.`) with: `The repo therefore carries the setting explicitly for every node (the all-layer document and the nv1 `false` override), so the bump changes nothing.`

Update the `**nv1 stays off**` bullet only when nv1 is enabled (phase 3).

- [ ] **Step 7: Regenerate, check, commit**

```bash
cd /workspaces/home-ops && task talos:config-map && task talos:check 2>&1 | tail -3
git add -A && git commit -m "feat(talos): workload isolation for every node, nv1 explicitly off" && git push -u origin HEAD && gh pr create --fill --base main
```

Expected: `0 failed`.

---

### Task 5: Phase 2 rollout: nv1 apply, mc2, mc1 (gated, manual)

**Files:** none.

**Interfaces:**

- Consumes: the merged PR 2 (Task 4), `scripts/isolation-check.sh`, the Task 3 procedure (steps 4-8) with a different node.

Same shell variables as Task 3 (`pq`, `$S`); per node set `NODE`/`IP`/`I` as below. All cluster-changing steps need the user's yes.

- [ ] **Step 1: Re-render and diff (read-only)**

```bash
git checkout main && git pull && task talos:generate && task talos:diff -- mc3 mc2 mc1 nv1
```

Expected: mc3 shows no differences (its rendered config is unchanged by the consolidation). mc2 and mc1 show only the new `SecurityProfileConfig` with `true`. nv1 shows only the new `SecurityProfileConfig` with `false`. Anything else: stop and report.

- [ ] **Step 2: Apply the nv1 document (live, no reboot, changes nothing at runtime) — ask the user first**

```bash
task talos:apply N=nv1 && task talos:diff -- nv1
provision/talos/scripts/isolation-check.sh nv1 off
```

Expected: the diff for nv1 is clean; the check passes for `off` (nv1 runs host namespaces and has no `sandboxd`, which `off` does not require).

- [ ] **Step 3: mc2**

Repeat Task 3 steps 1 (baseline, with `NODE=mc2 IP=192.168.48.3 I="192.168.48.3(:.*)?"`), 3 (apply), 4 (cordon and drain), 5 (the user reboots mc2), 6 (uncordon and gate, check `on`), 7 (test pods with `NODE=mc2`; mc2 also runs the jellyfin and nextcloud NFS workloads, so check they are Running after the pods return), 7b (red test, mc1 is the isolation-off control) and 8 (compare). The soak is the next morning's check of `isolation-check.sh mc2 on` and Alertmanager, not 48 hours. Ceph must be `HEALTH_OK` before starting mc1.

- [ ] **Step 4: mc1**

Same as Step 3 with `NODE=mc1 IP=192.168.48.2 I="192.168.48.2(:.*)?"`. mc1 last: it is the first endpoint in the talosconfig. In Step 7b use nv1 as the isolation-off control, since mc2 and mc3 are isolated by then.

- [ ] **Step 5: Final state check (read-only)**

```bash
for n in mc1 mc2 mc3; do provision/talos/scripts/isolation-check.sh $n on || echo "FAILED: $n"; done
provision/talos/scripts/isolation-check.sh nv1 off
task talos:diff
```

Expected: all four pass; `task talos:diff` shows no differences on any node. Report to the user.

---

### Task 6: Close-out and the conditional nv1 phase

**Files:**

- Modify: `.plans/TODO.md`
- Modify: `.claude/memory/reference_talos_workload_isolation.md`, `.claude/memory/MEMORY.md`
- Modify: `docs/superpowers/specs/2026-10-07-talos-workload-isolation-design.md` (status line)

- [ ] **Step 1: Branch and update the tracking**

```bash
git checkout main && git pull && git checkout -b docs/talos-workload-isolation-done
```

In `.plans/TODO.md`, replace the whole `SecurityProfileConfig` `workloadIsolation: true` bullet under the migration entry (and its `Plan if wanted` sub-bullet) with:

```markdown
    - `SecurityProfileConfig` `workloadIsolation`: **on for mc1-mc3 since the day of the last reboot (write the actual date)** (spec and plan `docs/superpowers/specs|plans/2026-10-07-talos-workload-isolation*`); nv1 is explicitly `false`. **Still to do, phase 3 (conditional, not time-boxed):** enable on nv1 once nv1 has been upgraded to v1.14.2 or later (installer `ghcr.io/mmalyska/custom-installer:v1.14.2-6.18.54-nvgpu5.13.0-drm-noshim` exists; the upgrade is its own TODO entry, README procedure including the UKI workaround) and has soaked; then delete `patches/node/nv1/65-security-profile.yaml`, apply, cordon, drain, reboot, uncordon, and run `scripts/isolation-check.sh nv1 on` plus `nvidia.com/gpu` allocatable, the CDI spec in `/var/run/cdi`, the `fw-fresh` firmware and `llama-server` on the GPU. The contract bump to v1.14 is safe for this setting (guarded by a render test).
```

- [ ] **Step 2: Memory**

Rewrite the body of `.claude/memory/reference_talos_workload_isolation.md` (keep the frontmatter, change `description` to `"Talos workload isolation (sandboxd) is on for mc1-mc3, explicitly off on nv1 until nv1 is upgraded to v1.14.2 or later; switching needs a reboot"`) so it says: on for mc1-mc3 (patches/all/65), nv1 false (patches/node/nv1/65) and why, the contract bump is guarded by a render test, `scripts/isolation-check.sh <node> [on|off]` proves it per node (NSpid depth), reboot needed both ways, and the recorded verification results from Tasks 3 and 5 (what changed in node-exporter series, if anything). Update its line in `.claude/memory/MEMORY.md` the same way (one line, no content beyond the hook).

- [ ] **Step 3: Spec status, commit, PR**

Add as the first line under the spec title: `**Status:** phases 1 and 2 done (write the actual date); phase 3 (nv1) waits for the nv1 upgrade to v1.14.2 or later, tracked in .plans/TODO.md.` Then:

```bash
git add -A && git commit -m "docs(talos): workload isolation is rolled out on the control planes, nv1 tracked" && git push -u origin HEAD && gh pr create --fill --base main
```

- [ ] **Step 4: Move the plan to done when phase 3 is done**

When nv1 is enabled, move this plan and its spec under the archive convention the repo uses for finished plans, and remove the TODO bullet. Until then both stay in `docs/superpowers/`.
