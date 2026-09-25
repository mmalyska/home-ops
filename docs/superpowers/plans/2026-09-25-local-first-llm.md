# Local-First LLM on Jetson (nv1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Hermes and Honcho inference to a local llama.cpp server on the Jetson (nv1), replace Ollama, and keep OpenRouter/Anthropic as automatic fallbacks.

**Architecture:** One GPU pod on nv1 (`llama-server`, Gemma 4 26B-A4B Q2) serves the main agent, auxiliary tasks and Honcho's LLM calls. Embeddings and speech-to-text run on the M720q CPU nodes; TTS is local Piper inside the Hermes pod. A watchdog sidecar makes the Jetson device plugin self-heal after kubelet restarts. Rollout is phased and every phase is reversible.

**Tech Stack:** ArgoCD ApplicationSet + Helm charts (raw templates), llama.cpp (`llama-server`), NVIDIA `llama_cpp` Jetson image (CUDA 12.6), faster-whisper via Speaches, Kustomize (nvidia app), Prometheus Operator CRDs, Talos/`talosctl`, Hermes Agent, Honcho.

**Spec:** `docs/superpowers/specs/2026-09-25-local-first-llm-design.md`

## Global Constraints

- **Never push to `main`.** Branch prefixes `feat/`, `fix/`, `chore/`. Every PR needs a label (`area/cluster`, `enhancement`, or `docs`).
- **Never mutate cluster state** (`kubectl apply/delete/scale/patch/annotate`, `talosctl` writes, ArgoCD syncs) without explicit user confirmation. Steps marked **CONFIRM** require it. Read-only `kubectl get/logs/top/describe` is free.
- **Never commit secrets or the private domain.** Bitwarden UUID lines need `#gitleaks:allow`.
- **GPU image:** `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04@sha256:8fa5df9a76d3ddce89ade0ae67822afdfac27a5fe3a9e5eff7b6dfd72cd34f6b` (CUDA 12.6). **Never use `latest*` tags** — they moved to CUDA 13, which nv1's JetPack 6 driver (r36.5) cannot initialize; llama.cpp then silently falls back to CPU (~6 tok/s).
- **Single GPU unit:** the Jetson device plugin advertises exactly one `nvidia.com/gpu`. Only the `llama-server` pod may request it. Ollama must be at 0 replicas before `llama-server` starts.
- **Tool calls:** clients must send `parallel_tool_calls: true` (llama-server defaults to false).
- **Sampling:** `temperature=1.0`, `top_p=0.95`, `top_k=64` (Google's Gemma 4 recommendation).
- **Deployments** of the model servers use `strategy: Recreate`. CPU workloads on the M720q (control-plane) nodes get hard CPU limits (STT ≤ 3 cores, embeddings ≤ 2).
- **Verification tools:** `task lint:all` is currently broken (`lint:format` missing). Use `yamllint <file>`, `helm template …`, `kubectl kustomize …`, `kubectl apply --dry-run=server -f …`. `yamllint` reports pre-existing warnings on old files; only new findings in changed lines matter.
- **After merging a PR that changes `app-config.yaml`,** the ApplicationSet does not re-read git quickly: run **CONFIRM**: `kubectl annotate applicationset appset-ai -n argocd argocd.argoproj.io/application-set-refresh=true --overwrite`. For chart/values changes: `kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite`.
- **Served model name** `gemma-4-26b-a4b`, per-slot context **32768** (`-c 65536 -np 2`), embeddings alias `nomic-embed-text` (768 dims).

## Review Focus

Failure modes the spec implies that no single task's happy path exercises (each has a test in the owning task):

1. **Local endpoint down or loading (503/connection refused) while Hermes runs an auxiliary task or main turn** — a reasonable person expects a fallback to OpenRouter, not an error. *(Task 9 Step 7 for auxiliary tasks, Task 11 Step 9 for the main model)*
2. **Prompt larger than the per-slot context (32768)** — expect Hermes to compress before sending (needs `model.context_length: 32768`), and no crash/OOM in llama-server if it does not. *(Task 8 Step 6, Task 12)*
3. **Two independent tool calls in one turn** — llama-server returns only the first unless `parallel_tool_calls: true` is sent; expect both, or at worst sequential calls that still complete. *(Task 8 Step 5, Task 11 Step 8)*
4. **Kubelet restart on nv1 while `llama-server` is running or being rescheduled** — expect the GPU to re-register within a minute without manual action and an alert if it does not. *(Task 1 Step 12, Task 2)*
5. **Honcho vector regression** — new embeddings must have the same dimension and near-identical vectors as Ollama's `nomic-embed-text`, or stored memories stop matching. *(Task 5 Step 2)*
6. **Restart while offline** — model download init containers must skip the network when the verified file already exists; Piper's `pip install` at pod start needs PyPI (same limitation as the existing `honcho-ai` install). *(Task 4 Step 8, Task 14)*

---

## Phase 0 — Prerequisites

### Task 1: Device-plugin self-heal watchdog

**Files:**
- Create: `cluster/apps/system/nvidia/resources/watchdog.sh`
- Create: `cluster/apps/system/nvidia/resources/watchdog.test.sh`
- Modify: `cluster/apps/system/nvidia/resources/device-plugin.yaml` (pod `spec` and volumes)
- Modify: `cluster/apps/system/nvidia/kustomization.yaml` (append `configMapGenerator`)

**Interfaces:**
- Produces: DaemonSet `nvidia-device-plugin` (ns `nvidia-system`) gains container `kubelet-watchdog`; ConfigMap `nvidia-device-plugin-watchdog-<hash>`. Behavior: whenever `/var/lib/kubelet/device-plugins/kubelet.sock` (inode+ctime) changes, the process `/jetson-device-plugin` is sent SIGTERM so its container restarts and re-registers.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/nvidia-device-plugin-watchdog
```

- [ ] **Step 2: Write the failing test**

Create `cluster/apps/system/nvidia/resources/watchdog.test.sh`:

```bash
#!/usr/bin/env bash
# Behavior test for watchdog.sh: a fake socket dir and dummy "plugin" processes.
# Run: bash cluster/apps/system/nvidia/resources/watchdog.test.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "${TMP}"' EXIT
FAIL=0

check() { # name want(alive|dead) pid
  local got=dead
  kill -0 "$3" 2>/dev/null && got=alive
  if [ "${got}" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1 (want $2, got ${got})"; FAIL=1; fi
}
recreate_socket() { sleep 1.1; rm -f "${TMP}/kubelet.sock"; touch "${TMP}/kubelet.sock"; }

touch "${TMP}/kubelet.sock"
SOCK_DIR="${TMP}" PLUGIN_PATTERN='^sleep 4242$' INTERVAL=1 "${HERE}/watchdog.sh" >"${TMP}/wd.log" 2>&1 &

sleep 4242 & P1=$!
sleep 3;            check "no change leaves the plugin running" alive "${P1}"
recreate_socket; sleep 3; check "kubelet.sock re-created restarts the plugin" dead "${P1}"

sleep 4242 & P2=$!
sleep 3;            check "baseline is refreshed after a restart" alive "${P2}"
recreate_socket; sleep 3; check "a second re-creation restarts it again" dead "${P2}"

rm -f "${TMP}/kubelet.sock"; sleep 3
sleep 4242 & P3=$!
sleep 2;            check "missing socket (kubelet starting) is not acted on" alive "${P3}"
sleep 1.1; touch "${TMP}/kubelet.sock"; sleep 3
check "socket reappearing after a gap restarts the plugin" dead "${P3}"

[ "${FAIL}" = 0 ] && echo "ALL PASSED" || { echo "FAILURES"; cat "${TMP}/wd.log"; }
exit "${FAIL}"
```

```bash
chmod +x cluster/apps/system/nvidia/resources/watchdog.test.sh
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash cluster/apps/system/nvidia/resources/watchdog.test.sh`
Expected: FAIL (no `watchdog.sh`; the test reports `FAIL` lines and `FAILURES`, exit code 1).

- [ ] **Step 4: Write the watchdog script**

Create `cluster/apps/system/nvidia/resources/watchdog.sh`:

```sh
#!/bin/sh
# Restarts the Jetson device plugin when the kubelet re-creates kubelet.sock.
#
# The plugin registers with the kubelet once at start and never re-registers.
# Every kubelet restart forgets the registration, leaving the node at
# nvidia.com/gpu: 0. Killing the plugin makes the container restart, which
# registers again. Requires shareProcessNamespace: true on the pod.
SOCK_DIR="${SOCK_DIR:-/var/lib/kubelet/device-plugins}"
PLUGIN_PATTERN="${PLUGIN_PATTERN:-^/jetson-device-plugin$}"
INTERVAL="${INTERVAL:-10}"
KUBELET_SOCK="${SOCK_DIR}/kubelet.sock"

# inode + ctime: an inode number alone can be reused by the next file.
fingerprint() { stat -c '%i:%Z' "${KUBELET_SOCK}" 2>/dev/null || echo none; }

BASE="$(fingerprint)"
echo "watchdog: watching ${KUBELET_SOCK} (baseline ${BASE}), interval ${INTERVAL}s"
while true; do
  sleep "${INTERVAL}"
  NOW="$(fingerprint)"
  # "none" = kubelet still starting; wait for the socket, don't act on a gap.
  if [ "${NOW}" != "none" ] && [ "${NOW}" != "${BASE}" ]; then
    echo "watchdog: kubelet.sock changed (${BASE} -> ${NOW}); restarting plugin"
    pkill -TERM -f "${PLUGIN_PATTERN}" || echo "watchdog: plugin process not found"
    BASE="${NOW}"
  fi
done
```

```bash
chmod +x cluster/apps/system/nvidia/resources/watchdog.sh
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash cluster/apps/system/nvidia/resources/watchdog.test.sh`
Expected: six `PASS` lines then `ALL PASSED` (takes ~25 s).

- [ ] **Step 6: Add the sidecar to the DaemonSet**

In `cluster/apps/system/nvidia/resources/device-plugin.yaml`, replace this block:

```yaml
    spec:
      nodeSelector:
        accelerator: jetson-orin
      tolerations:
        - operator: Exists
      priorityClassName: system-node-critical
      containers:
```

with:

```yaml
    spec:
      # The watchdog sidecar signals the plugin process across containers.
      shareProcessNamespace: true
      nodeSelector:
        accelerator: jetson-orin
      tolerations:
        - operator: Exists
      priorityClassName: system-node-critical
      containers:
```

and replace this block (end of the file):

```yaml
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
```

with:

```yaml
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
        # The plugin registers with the kubelet once and never re-registers, so
        # any kubelet restart leaves the node at nvidia.com/gpu: 0. This sidecar
        # restarts the plugin whenever the kubelet re-creates kubelet.sock.
        - name: kubelet-watchdog
          image: alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
          command: ["sh", "/scripts/watchdog.sh"]
          resources:
            requests:
              cpu: 5m
              memory: 8Mi
            limits:
              cpu: 20m
              memory: 32Mi
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
              readOnly: true
            - name: watchdog-script
              mountPath: /scripts
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: watchdog-script
          configMap:
            name: nvidia-device-plugin-watchdog
            defaultMode: 0555
```

- [ ] **Step 7: Generate the ConfigMap from the script (single source of truth)**

Append to `cluster/apps/system/nvidia/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: nvidia-device-plugin-watchdog
    files:
      - watchdog.sh=resources/watchdog.sh
```

- [ ] **Step 8: Verify the render**

```bash
kubectl kustomize cluster/apps/system/nvidia > /tmp/nvidia-render.yaml && echo "kustomize OK"
grep -c "name: kubelet-watchdog" /tmp/nvidia-render.yaml        # expect 1
grep -c "shareProcessNamespace: true" /tmp/nvidia-render.yaml   # expect 1
grep -o "nvidia-device-plugin-watchdog-[a-z0-9]*" /tmp/nvidia-render.yaml | sort -u   # expect exactly ONE name (defined and referenced consistently)
```

Expected: `kustomize OK`, `1`, `1`, one hashed ConfigMap name.

- [ ] **Step 9: Lint**

Run: `yamllint cluster/apps/system/nvidia/resources/device-plugin.yaml cluster/apps/system/nvidia/kustomization.yaml`
Expected: no errors on the lines you added.

- [ ] **Step 10: Verify busybox applets in the sidecar image (CONFIRM — creates a throwaway pod)**

```bash
kubectl run wd-applet-check --rm -i --restart=Never -n default \
  --image=alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 \
  -- sh -c 'stat -c "%i:%Z" /etc/hostname && pkill --help 2>&1 | head -1 && echo APPLETS_OK'
```

Expected: an `inode:ctime` line and `APPLETS_OK`. If `stat -c` or `pkill` is missing, stop and report; the script must change to whatever the image provides.

- [ ] **Step 11: Commit and open the PR**

```bash
git add cluster/apps/system/nvidia
git commit -m "feat(nvidia): restart the Jetson device plugin after kubelet restarts

The plugin registers with the kubelet once and never re-registers, so any
kubelet restart left nv1 at nvidia.com/gpu: 0 until someone restarted the
pod. A sidecar now restarts the plugin when kubelet.sock is re-created."
git push -u origin feat/nvidia-device-plugin-watchdog
gh pr create --base main --label area/cluster --label enhancement \
  --title "feat(nvidia): restart the Jetson device plugin after kubelet restarts" \
  --body "Adds a watchdog sidecar (shareProcessNamespace) that SIGTERMs /jetson-device-plugin when kubelet.sock is re-created, so the GPU re-registers automatically. Script is tested by watchdog.test.sh (6 cases + negative control). Spec: docs/superpowers/specs/2026-09-25-local-first-llm-design.md"
```

- [ ] **Step 12: After merge, verify live (CONFIRM — restarts the kubelet on nv1)**

Refresh the app (`kubectl annotate application nvidia -n argocd argocd.argoproj.io/refresh=hard --overwrite`), wait for the DaemonSet pod to show `2/2` Ready, then:

```bash
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 service kubelet restart
for i in $(seq 1 12); do echo "$i gpu=$(kubectl get node nv1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')"; sleep 10; done
kubectl logs -n nvidia-system ds/nvidia-device-plugin -c kubelet-watchdog --tail=5
```

Expected: `gpu` may show `0` briefly, then returns to `1` within ~60 s **without any manual restart**; the watchdog log shows `kubelet.sock changed … restarting plugin`. If it stays 0, do not proceed: inspect the logs of both containers.

---

### Task 2: GPU-unavailable alert

**Files:**
- Create: `cluster/apps/system/prometheus-stack/templates/prometheusrule-gpu.yaml`

**Interfaces:**
- Produces: alert `NodeGpuUnavailable` (severity critical) when nv1's `nvidia_com_gpu` allocatable is 0 or missing for 5 minutes. Uses metric `kube_node_status_allocatable{resource="nvidia_com_gpu",node="nv1"}` (verified present, value 1).

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/nv1-gpu-alert
```

- [ ] **Step 2: Write the failing check**

Run: `test -f cluster/apps/system/prometheus-stack/templates/prometheusrule-gpu.yaml && echo EXISTS || echo MISSING`
Expected: `MISSING`.

- [ ] **Step 3: Create the rule**

`cluster/apps/system/prometheus-stack/templates/prometheusrule-gpu.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: nv1-gpu
  namespace: monitoring
  labels:
    app: kube-prometheus-stack
    release: prometheus-stack
spec:
  groups:
    - name: nv1.gpu
      rules:
        - alert: NodeGpuUnavailable
          expr: >-
            kube_node_status_allocatable{resource="nvidia_com_gpu",node="nv1"} == 0
            or absent(kube_node_status_allocatable{resource="nvidia_com_gpu",node="nv1"})
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: nv1 has no allocatable GPU
            description: >-
              The Jetson device plugin is not registered with the kubelet on nv1
              (allocatable nvidia.com/gpu is 0 or missing), so GPU pods stay
              Pending. Restart the nvidia-device-plugin pod; the watchdog
              sidecar should normally do this automatically.
```

- [ ] **Step 4: Verify the file is valid and accepted by the API**

```bash
yamllint cluster/apps/system/prometheus-stack/templates/prometheusrule-gpu.yaml
kubectl apply --dry-run=server -f cluster/apps/system/prometheus-stack/templates/prometheusrule-gpu.yaml
```

Expected: `prometheusrule.monitoring.coreos.com/nv1-gpu created (server dry run)`.

- [ ] **Step 5: Verify the expression logic against live data (read-only)**

```bash
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 19090:9090 & PF=$!; sleep 3
curl -s --data-urlencode 'query=kube_node_status_allocatable{resource="nvidia_com_gpu",node="nv1"}' localhost:19090/api/v1/query | jq -c '.data.result[]|.value[1]'
curl -s --data-urlencode 'query=kube_node_status_allocatable{resource="nvidia_com_gpu",node="nv1"} == 0 or absent(kube_node_status_allocatable{resource="nvidia_com_gpu",node="nv1"})' localhost:19090/api/v1/query | jq -c '.data.result'
kill $PF
```

Expected: first query `"1"`; second `[]` (healthy: alert would not fire).

- [ ] **Step 6: Commit and open the PR**

```bash
git add cluster/apps/system/prometheus-stack/templates/prometheusrule-gpu.yaml
git commit -m "feat(monitoring): alert when nv1 has no allocatable GPU"
git push -u origin feat/nv1-gpu-alert
gh pr create --base main --label area/cluster --label enhancement --title "feat(monitoring): alert when nv1 has no allocatable GPU" \
  --body "NodeGpuUnavailable fires when kube_node_status_allocatable{resource=nvidia_com_gpu,node=nv1} is 0 or absent for 5m. Verified the metric exists and the expression is empty while healthy."
```

---

### Task 3: nv1 Jetson runbook

**Files:**
- Create: `docs/src/k8s/nv1-jetson.md`
- Modify: `.github/mkdocs/mkdocs.yml` (nav)

**Interfaces:**
- Produces: `docs/src/k8s/nv1-jetson.md` — the reference other tasks link to for the GPU rules.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b chore/docs-nv1-jetson-runbook
```

- [ ] **Step 2: Failing check**

Run: `test -f docs/src/k8s/nv1-jetson.md && echo EXISTS || echo MISSING` — expected `MISSING`.

- [ ] **Step 3: Write the doc**

`docs/src/k8s/nv1-jetson.md`:

```markdown
# nv1 — Jetson Orin NX (GPU node)

nv1 (`192.168.48.5`) is a Jetson Orin NX 16 GB running Talos with a custom nvgpu (JetPack 6 / r36.5) stack. CPU and GPU share the 16 GB (about 12.8 GiB usable for models).

## How GPU access works

- `nvidia-cdi-setup` DaemonSet writes a CDI spec (device nodes + JetPack libs).
- `nvidia-device-plugin` advertises **exactly one** `nvidia.com/gpu` (hard-coded, no config). Only one pod at a time can hold it.
- A `kubelet-watchdog` sidecar restarts the plugin whenever the kubelet re-creates `kubelet.sock`. Without it, any kubelet restart leaves the node at `nvidia.com/gpu: 0` because the plugin never re-registers.
- Alert `NodeGpuUnavailable` fires when allocatable GPU is 0 for 5 minutes.

## Rules for GPU images

- Use CUDA **12.6** images only, pinned by digest (for llama.cpp: `ghcr.io/nvidia-ai-iot/llama_cpp:b8708-r36.4-tegra-aarch64-cu126-22.04`).
- Never use `latest*` tags: they moved to CUDA 13, which the JetPack 6 driver cannot initialize. llama.cpp then falls back to CPU **silently** (log line `ggml_cuda_init: failed to initialize CUDA: CUDA driver version is insufficient for CUDA runtime version`, ~6 tok/s).

## Symptoms and recovery

| Symptom | Cause | Fix |
|---|---|---|
| GPU pod `Pending`, `Insufficient nvidia.com/gpu`; node allocatable `nvidia.com/gpu: 0` | Kubelet restarted; plugin lost registration | Watchdog fixes it in about a minute; manual: `kubectl rollout restart ds/nvidia-device-plugin -n nvidia-system` |
| Kubelet restarts every 10–20 min | Extra DHCP address on the NIC flapping the static IP | See below |

## Talos: platform DHCP left in META (fixed 2026-09-25)

nv1 had a leftover platform network config in the Talos META partition (key `0x0a`) with `operators: [dhcp4 enP8p1s0]`. It leased `192.168.48.210` beside the static `192.168.48.5`; lease churn flapped `.5`, and Talos restarted the kubelet. Machine-config `dhcp: false` does **not** remove a platform-layer operator.

- Check: `talosctl -n 192.168.48.5 get operatorspecs` must be empty and `get addresses` must show only `192.168.48.5/24` on `enP8p1s0`.
- Fix: `talosctl -n 192.168.48.5 meta delete 0x0a` (no reboot needed).
- After a reinstall or reflash, re-check this: the key is not in git.
```

- [ ] **Step 4: Add to the docs nav**

In `.github/mkdocs/mkdocs.yml`, after the line `          - "NVMe Replacement": k8s/nvme-replacement.md` add:

```yaml
          - "nv1 Jetson (GPU)": k8s/nv1-jetson.md
```

- [ ] **Step 5: Verify**

```bash
test -f docs/src/k8s/nv1-jetson.md && grep -n "nv1-jetson" .github/mkdocs/mkdocs.yml
yamllint .github/mkdocs/mkdocs.yml | grep -n "nv1" || echo "no findings on the new line"
```

Expected: the nav line printed; no yamllint finding on it.

- [ ] **Step 6: Commit and open the PR**

```bash
git add docs/src/k8s/nv1-jetson.md .github/mkdocs/mkdocs.yml
git commit -m "docs: add nv1 Jetson GPU runbook"
git push -u origin chore/docs-nv1-jetson-runbook
gh pr create --base main --label docs --title "docs: add nv1 Jetson GPU runbook" --body "Documents the single-GPU-unit plugin, the watchdog, the CUDA 12.6 image rule and the Talos META 0x0a DHCP finding."
```

---

## Phase 1 — Embeddings on CPU

### Task 4: `llm` app skeleton and CPU embeddings server

**Files:**
- Create: `cluster/apps/ai/llm/app-config.yaml`
- Create: `cluster/apps/ai/llm/embeddings/Chart.yaml`
- Create: `cluster/apps/ai/llm/embeddings/values.yaml`
- Create: `cluster/apps/ai/llm/embeddings/templates/pvc.yaml`
- Create: `cluster/apps/ai/llm/embeddings/templates/deployment.yaml`
- Create: `cluster/apps/ai/llm/embeddings/templates/service.yaml`

**Interfaces:**
- Produces: namespace `llm`; Service `llm-embeddings` on port 8080 serving OpenAI-compatible `/v1/embeddings` with model alias `nomic-embed-text` (768 dims, nomic-embed-text v1.5 f16). ApplicationSet app name `llm-embeddings`.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/llm-embeddings
```

- [ ] **Step 2: Failing check**

Run: `helm template x cluster/apps/ai/llm/embeddings 2>&1 | head -1`
Expected: an error (chart does not exist).

- [ ] **Step 3: Create the app config and chart**

`cluster/apps/ai/llm/app-config.yaml`:

```yaml
- enabled: "true"
  appSubfolder: embeddings
  namespace: llm
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  managedNamespaceMetadata:
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/warn: baseline
```

`cluster/apps/ai/llm/embeddings/Chart.yaml`:

```yaml
apiVersion: v2
name: llm-embeddings
type: application
version: 1.0.0
```

`cluster/apps/ai/llm/embeddings/values.yaml`:

```yaml
embeddings:
  image:
    repository: ghcr.io/ggml-org/llama.cpp
    tag: "server@sha256:6257697a7f5d034b8fb499ddb07af3e250506352f94102054252a23f3b85e0af"
  fetchImage: alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
  model:
    file: nomic-embed-text-v1.5.f16.gguf
    url: https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.f16.gguf
    sha256: f7af6f66802f4df86eda10fe9bbcfc75c39562bed48ef6ace719a251cf1c2fdb
    size: "274290560"
    alias: nomic-embed-text
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: "2"
      memory: 1Gi
```

- [ ] **Step 4: Create the templates**

`templates/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llm-embeddings-models
  namespace: llm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

`templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: llm-embeddings
  namespace: llm
spec:
  type: ClusterIP
  selector:
    app: llm-embeddings
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```

`templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-embeddings
  namespace: llm
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: llm-embeddings
  template:
    metadata:
      labels:
        app: llm-embeddings
    spec:
      # nv1 is arm64 and reserved for the GPU server; run on the x86 nodes.
      nodeSelector:
        kubernetes.io/arch: amd64
      initContainers:
        - name: fetch-model
          image: {{ .Values.embeddings.fetchImage }}
          command: ["sh", "-c"]
          args:
            - |
              set -eu
              DEST="/models/${MODEL_FILE}"
              # Skip the network entirely when a previously verified file exists
              # (lets the pod restart while offline).
              if [ -f "${DEST}.ok" ] && [ "$(cat "${DEST}.ok")" = "${MODEL_SHA256}" ] \
                 && [ "$(stat -c %s "${DEST}")" = "${MODEL_SIZE}" ]; then
                echo "model present and verified; skipping download"
                exit 0
              fi
              echo "downloading ${MODEL_URL}"
              wget -c -O "${DEST}.part" "${MODEL_URL}"
              echo "${MODEL_SHA256}  ${DEST}.part" | sha256sum -c -
              mv "${DEST}.part" "${DEST}"
              echo "${MODEL_SHA256}" > "${DEST}.ok"
          env:
            - name: MODEL_FILE
              value: {{ .Values.embeddings.model.file | quote }}
            - name: MODEL_URL
              value: {{ .Values.embeddings.model.url | quote }}
            - name: MODEL_SHA256
              value: {{ .Values.embeddings.model.sha256 | quote }}
            - name: MODEL_SIZE
              value: {{ .Values.embeddings.model.size | quote }}
          volumeMounts:
            - name: models
              mountPath: /models
      containers:
        - name: llama
          image: "{{ .Values.embeddings.image.repository }}:{{ .Values.embeddings.image.tag }}"
          args:
            - --model
            - /models/{{ .Values.embeddings.model.file }}
            - --alias
            - {{ .Values.embeddings.model.alias }}
            - --embedding
            - --pooling
            - mean
            - --ctx-size
            - "8192"
            - --parallel
            - "2"
            - --batch-size
            - "4096"
            - --ubatch-size
            - "4096"
            - --threads
            - "2"
            - --host
            - 0.0.0.0
            - --port
            - "8080"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 5
          resources: {{ toYaml .Values.embeddings.resources | nindent 12 }}
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: llm-embeddings-models
```

- [ ] **Step 5: Render and validate**

```bash
helm template llm-embeddings cluster/apps/ai/llm/embeddings > /tmp/emb.yaml && echo "helm OK"
kubectl apply --dry-run=server -f /tmp/emb.yaml
yamllint cluster/apps/ai/llm/app-config.yaml cluster/apps/ai/llm/embeddings/Chart.yaml cluster/apps/ai/llm/embeddings/values.yaml
grep -c "kubernetes.io/arch: amd64" /tmp/emb.yaml   # expect 1
```

Expected: `helm OK`; dry-run lines `created (server dry run)` (the namespace `llm` does not exist yet, so the namespaced objects may report `namespaces "llm" not found` on the server dry run — that is acceptable here; ArgoCD creates the namespace with `CreateNamespace`); no yamllint errors in the new files.

- [ ] **Step 6: Commit and open the PR**

```bash
git add cluster/apps/ai/llm
git commit -m "feat(llm): add CPU embeddings server (nomic-embed-text) in the llm namespace"
git push -u origin feat/llm-embeddings
gh pr create --base main --label area/cluster --label enhancement --title "feat(llm): add CPU embeddings server (nomic-embed-text)" \
  --body "New llm app (embeddings component): llama.cpp CPU server on the x86 nodes serving nomic-embed-text v1.5 f16 at /v1/embeddings. Model is fetched once, sha256-verified, and kept on a 1Gi PVC so restarts work offline. Nothing consumes it yet (Honcho is repointed in a later PR)."
```

- [ ] **Step 7: After merge: deploy (CONFIRM) and verify**

Refresh the ApplicationSet (Global Constraints), then:

```bash
kubectl get pods -n llm -w   # wait for llm-embeddings Ready (first start downloads 274 MB)
kubectl port-forward -n llm svc/llm-embeddings 18081:8080 & PF=$!; sleep 3
curl -s localhost:18081/v1/embeddings -H 'Content-Type: application/json' -d '{"model":"nomic-embed-text","input":"hello"}' | jq '.data[0].embedding|length'
kill $PF
```

Expected: `768`.

- [ ] **Step 8: Offline-restart check (CONFIRM)**

Delete the pod (`kubectl delete pod -n llm -l app=llm-embeddings`) and watch the init container log: `kubectl logs -n llm -l app=llm-embeddings -c fetch-model`. Expected: `model present and verified; skipping download`, pod Ready again.

---

### Task 5: Verify embedding equivalence, then repoint Honcho

**Files:**
- Modify: `cluster/apps/ai/honcho/templates/_helpers.tpl` (one line)

**Interfaces:**
- Consumes: Service `llm-embeddings.llm.svc.cluster.local:8080` (Task 4), alias `nomic-embed-text`.
- Produces: Honcho embeddings served by the CPU server; Ollama no longer used by Honcho.

- [ ] **Step 1: Write the equivalence test (S4)**

Create `/tmp/compare_embeddings.py` (scratch, not committed):

```python
#!/usr/bin/env python3
"""S4: Ollama vs llama-server embeddings for the same text (nomic-embed-text)."""
import json
import math
import sys
import urllib.request

OLLAMA = "http://localhost:11434/v1/embeddings"
LLAMA = "http://localhost:18081/v1/embeddings"
SAMPLES = [
    "The user prefers concise answers and works on a home Kubernetes cluster.",
    "search_document: Talos Linux nodes are managed declaratively with talosctl.",
    "Remind me to renew the domain next month.",
    "What is the capital of Poland?",
    "def deep_merge(base, src): pass",
    "Discord message about the Jetson Orin GPU dropping to zero allocatable.",
]


def embed(url, text):
    body = json.dumps({"model": "nomic-embed-text", "input": text}).encode()
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["data"][0]["embedding"]


def cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    return dot / (math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b)))


failed = False
for text in SAMPLES:
    a, b = embed(OLLAMA, text), embed(LLAMA, text)
    sim = cosine(a, b)
    ok = len(a) == len(b) == 768 and sim >= 0.999
    failed |= not ok
    print(f"{'PASS' if ok else 'FAIL'} dim={len(a)}/{len(b)} cos={sim:.5f} {text[:40]!r}")
sys.exit(1 if failed else 0)
```

- [ ] **Step 2: Run it against the live services (read-only port-forwards)**

```bash
kubectl port-forward -n ollama svc/ollama 11434:11434 & PF1=$!
kubectl port-forward -n llm svc/llm-embeddings 18081:8080 & PF2=$!
sleep 4; python3 /tmp/compare_embeddings.py; echo "exit=$?"; kill $PF1 $PF2
```

Expected: six `PASS` lines, `exit=0`. **If any line FAILS** (cosine < 0.999 or dimension ≠ 768): stop. Do not repoint Honcho. Options: try the Q8_0 file (`nomic-embed-text-v1.5.Q8_0.gguf`), or plan a re-embed of Honcho's stored vectors as a separate task. Report to the user.

- [ ] **Step 3: Branch and make the change**

```bash
git checkout main && git pull -q && git checkout -b feat/honcho-local-embeddings
```

In `cluster/apps/ai/honcho/templates/_helpers.tpl`, replace:

```yaml
  value: http://ollama.ollama.svc.cluster.local:11434/v1
```

with:

```yaml
  value: http://llm-embeddings.llm.svc.cluster.local:8080/v1
```

- [ ] **Step 4: Verify the render**

```bash
(cd cluster/apps/ai/honcho && helm dependency build >/dev/null 2>&1; helm template honcho . | grep -A1 "EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL" | sort -u)
```

Expected: value `http://llm-embeddings.llm.svc.cluster.local:8080/v1`; no `ollama` string left: `helm template honcho cluster/apps/ai/honcho | grep -c ollama` → `0`.

- [ ] **Step 5: Commit and open the PR**

```bash
git add cluster/apps/ai/honcho/templates/_helpers.tpl
git commit -m "feat(honcho): use the local CPU embeddings server instead of Ollama"
git push -u origin feat/honcho-local-embeddings
gh pr create --base main --label area/cluster --label enhancement --title "feat(honcho): use the local CPU embeddings server instead of Ollama" \
  --body "Repoints Honcho embeddings to llm-embeddings (nomic-embed-text v1.5 f16, 768 dims). Equivalence vs Ollama verified (cosine >= 0.999 on 6 samples). Prerequisite for stopping Ollama."
```

- [ ] **Step 6: After merge, verify (CONFIRM refresh)**

Refresh the honcho app. Honcho pods roll (env changed). Then:

```bash
kubectl get pods -n honcho
kubectl logs -n honcho deploy/honcho-api --tail=50 | grep -i -E "embed|error" | tail
kubectl logs -n llm deploy/llm-embeddings --tail=20 | grep -c "POST /v1/embeddings"
```

Expected: pods Ready; no embedding errors; a non-zero count of embeddings requests after some Hermes activity (send a Discord/Signal message to Hermes to trigger memory writes). Rollback: revert the PR (Ollama still serves).

---

## Phase 2 — GPU server

### Task 6: `llama-server` component (created disabled)

**Files:**
- Modify: `cluster/apps/ai/llm/app-config.yaml` (append a `server` entry with `enabled: "false"`)
- Create: `cluster/apps/ai/llm/server/Chart.yaml`
- Create: `cluster/apps/ai/llm/server/values.yaml`
- Create: `cluster/apps/ai/llm/server/templates/pvc.yaml`
- Create: `cluster/apps/ai/llm/server/templates/deployment.yaml`
- Create: `cluster/apps/ai/llm/server/templates/service.yaml`
- Create: `cluster/apps/ai/llm/server/templates/podmonitor.yaml`

**Interfaces:**
- Produces (when enabled): Service `llama-server` port 8080 (`/v1/chat/completions`, `/health`, `/metrics`); model alias `gemma-4-26b-a4b`; per-slot context 32768; holds `nvidia.com/gpu: 1`.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/llm-server
```

- [ ] **Step 2: Failing check**

Run: `helm template x cluster/apps/ai/llm/server 2>&1 | head -1` — expected: error (chart does not exist).

- [ ] **Step 3: Register the component, disabled**

Append to `cluster/apps/ai/llm/app-config.yaml`:

```yaml
- enabled: "false"
  appSubfolder: server
  namespace: llm
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  managedNamespaceMetadata:
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/warn: baseline
```

- [ ] **Step 4: Chart and values**

`cluster/apps/ai/llm/server/Chart.yaml`:

```yaml
apiVersion: v2
name: llm-server
type: application
version: 1.0.0
```

`cluster/apps/ai/llm/server/values.yaml`:

```yaml
server:
  image:
    repository: ghcr.io/nvidia-ai-iot/llama_cpp
    # CUDA 12.6 build for JetPack 6. NEVER use latest* tags (CUDA 13 does not
    # initialize on nv1's driver and silently falls back to CPU).
    tag: "b8708-r36.4-tegra-aarch64-cu126-22.04@sha256:8fa5df9a76d3ddce89ade0ae67822afdfac27a5fe3a9e5eff7b6dfd72cd34f6b"
  fetchImage: alpine:3@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
  model:
    file: gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf
    url: https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q2_K_XL.gguf
    sha256: 2a1d26dfe6ea00a467940a5728316af6edb366bbdba950d65b85d232392fb658
    size: "10546934240"
    alias: gemma-4-26b-a4b
  # Total context; each of the `parallel` slots gets ctx/parallel (32768).
  ctx: 65536
  parallel: 2
  storage: 20Gi
  resources:
    requests:
      cpu: 500m
      memory: 8Gi
    limits:
      memory: 13Gi
      nvidia.com/gpu: 1
```

- [ ] **Step 5: Templates**

`templates/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llama-server-models
  namespace: llm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ .Values.server.storage }}
```

`templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: llama-server
  namespace: llm
  labels:
    app: llama-server
spec:
  type: ClusterIP
  selector:
    app: llama-server
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
```

`templates/podmonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: llama-server
  namespace: llm
spec:
  selector:
    matchLabels:
      app: llama-server
  podMetricsEndpoints:
    - port: http
      path: /metrics
```

`templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llama-server
  namespace: llm
spec:
  replicas: 1
  # The single GPU unit cannot be held by two pods: never start the new one first.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: llama-server
  template:
    metadata:
      labels:
        app: llama-server
    spec:
      nodeSelector:
        accelerator: jetson-orin
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: present
          effect: NoSchedule
      initContainers:
        - name: fetch-model
          image: {{ .Values.server.fetchImage }}
          command: ["sh", "-c"]
          args:
            - |
              set -eu
              DEST="/models/${MODEL_FILE}"
              # Skip the network entirely when a previously verified file exists
              # (lets the pod restart while offline).
              if [ -f "${DEST}.ok" ] && [ "$(cat "${DEST}.ok")" = "${MODEL_SHA256}" ] \
                 && [ "$(stat -c %s "${DEST}")" = "${MODEL_SIZE}" ]; then
                echo "model present and verified; skipping download"
                exit 0
              fi
              echo "downloading ${MODEL_URL}"
              wget -c -O "${DEST}.part" "${MODEL_URL}"
              echo "${MODEL_SHA256}  ${DEST}.part" | sha256sum -c -
              mv "${DEST}.part" "${DEST}"
              echo "${MODEL_SHA256}" > "${DEST}.ok"
          env:
            - name: MODEL_FILE
              value: {{ .Values.server.model.file | quote }}
            - name: MODEL_URL
              value: {{ .Values.server.model.url | quote }}
            - name: MODEL_SHA256
              value: {{ .Values.server.model.sha256 | quote }}
            - name: MODEL_SIZE
              value: {{ .Values.server.model.size | quote }}
          volumeMounts:
            - name: models
              mountPath: /models
      containers:
        - name: llama-server
          image: "{{ .Values.server.image.repository }}:{{ .Values.server.image.tag }}"
          command: ["llama-server"]
          args:
            - -m
            - /models/{{ .Values.server.model.file }}
            - --alias
            - {{ .Values.server.model.alias }}
            # Short flags exactly as verified on this image (b8708, CUDA 12.6).
            - -ngl
            - "99"
            - -fa
            - "on"
            - -ctk
            - q8_0
            - -ctv
            - q4_0
            - -c
            - {{ .Values.server.ctx | quote }}
            - -np
            - {{ .Values.server.parallel | quote }}
            - --jinja
            - --metrics
            - --host
            - 0.0.0.0
            - --port
            - "8080"
          ports:
            - name: http
              containerPort: 8080
              protocol: TCP
          # Cold start loads ~10.5 GB from Ceph (1-2 min); allow up to 10 min.
          startupProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            failureThreshold: 60
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 30
            failureThreshold: 5
          resources: {{ toYaml .Values.server.resources | nindent 12 }}
          volumeMounts:
            - name: models
              mountPath: /models
              readOnly: true
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: llama-server-models
```

- [ ] **Step 6: Render and validate**

```bash
helm template llm-server cluster/apps/ai/llm/server > /tmp/srv.yaml && echo "helm OK"
grep -c "b8708-r36.4-tegra-aarch64-cu126-22.04@sha256:8fa5df9a" /tmp/srv.yaml   # expect 1
grep -c "latest" /tmp/srv.yaml                                                   # expect 0
grep -c "nvidia.com/gpu: 1" /tmp/srv.yaml                                        # expect 1
yamllint cluster/apps/ai/llm/app-config.yaml cluster/apps/ai/llm/server/Chart.yaml cluster/apps/ai/llm/server/values.yaml
```

Expected: `helm OK`, `1`, `0`, `1`, no yamllint errors in the new lines.

- [ ] **Step 7: Commit and open the PR**

```bash
git add cluster/apps/ai/llm
git commit -m "feat(llm): add llama-server (Gemma 4 26B-A4B, CUDA 12.6) component, disabled

Registered with enabled: \"false\" so nothing schedules until Ollama has
released nv1's single GPU unit."
git push -u origin feat/llm-server
gh pr create --base main --label area/cluster --label enhancement --title "feat(llm): add llama-server component (disabled)" \
  --body "Pinned CUDA 12.6 NVIDIA llama_cpp image, Gemma 4 26B-A4B UD-Q2_K_XL (sha256-verified download to a 20Gi PVC), -c 65536 -np 2, /metrics PodMonitor. app-config entry is enabled: \"false\"; it is switched on in the cutover PR after Ollama is scaled to 0."
```

---

### Task 7: Cutover — Ollama to 0, enable `llama-server`

**Files:**
- Modify: `cluster/apps/ai/ollama/values.yaml` (add `replicaCount: 0` under the `ollama:` key) — PR A
- Modify: `cluster/apps/ai/llm/app-config.yaml` (`server` entry `enabled: "true"`) — PR B

**Interfaces:**
- Consumes: Honcho already on `llm-embeddings` (Task 5); `llama-server` component (Task 6); watchdog (Task 1) merged and verified.
- Produces: running `llama-server` on the GPU, verified at ≥ 14 tok/s.

- [ ] **Step 1: Pre-flight (read-only)**

```bash
kubectl get deploy -n honcho honcho-api -o jsonpath='{.spec.template.spec.containers[0].env}' | jq -r '.[]|select(.name=="EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL")|.value'   # expect llm-embeddings
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'grep -rIl -i ollama /opt/data/config.yaml /opt/data/profiles/*/config.yaml 2>/dev/null; echo "grep-exit=$?"'   # expect no files listed
kubectl get node nv1 -o jsonpath='gpu={.status.allocatable.nvidia\.com/gpu}{"\n"}'          # expect 1
kubectl get ds nvidia-device-plugin -n nvidia-system -o jsonpath='{.spec.template.spec.containers[*].name}{"\n"}'   # expect both containers (watchdog live)
```

Expected: `llm-embeddings` URL; no config files mention Ollama (`grep-exit=1`); `gpu=1`; both `jetson-device-plugin kubelet-watchdog`. If any differs, stop.

- [ ] **Step 2: PR A — scale Ollama to 0 in git**

```bash
git checkout main && git pull -q && git checkout -b chore/ollama-scale-to-zero
```

In `cluster/apps/ai/ollama/values.yaml`, add as the first key under `ollama:` (same indentation as `image:`):

```yaml
  replicaCount: 0 # nv1's single GPU unit moves to llama-server (llm app)
```

Verify: `(cd cluster/apps/ai/ollama && helm dependency build >/dev/null 2>&1; helm template o . | grep -E "^\s+replicas:")` → `replicas: 0`.

```bash
git add cluster/apps/ai/ollama/values.yaml
git commit -m "chore(ollama): scale to zero to release nv1's GPU for llama-server"
git push -u origin chore/ollama-scale-to-zero
gh pr create --base main --label area/cluster --title "chore(ollama): scale to zero to release nv1's GPU for llama-server" \
  --body "Honcho embeddings already use llm-embeddings; nothing else consumes Ollama. Frees the single nvidia.com/gpu unit. Rollback: replicaCount: 1."
```

- [ ] **Step 3: After merge (CONFIRM refresh), verify the GPU is free**

```bash
kubectl get pods -n ollama            # expect none
kubectl describe node nv1 | grep -A8 "Allocated resources" | grep gpu   # expect nvidia.com/gpu 0 0
```

- [ ] **Step 4: PR B — enable the server**

```bash
git checkout main && git pull -q && git checkout -b feat/llm-server-enable
```

In `cluster/apps/ai/llm/app-config.yaml`, change the `server` entry's `enabled: "false"` to `enabled: "true"`.

```bash
grep -B1 -A1 "appSubfolder: server" cluster/apps/ai/llm/app-config.yaml   # confirm enabled: "true" on the entry above it
git add cluster/apps/ai/llm/app-config.yaml
git commit -m "feat(llm): enable llama-server"
git push -u origin feat/llm-server-enable
gh pr create --base main --label area/cluster --label enhancement --title "feat(llm): enable llama-server" \
  --body "Ollama is at 0 replicas and nv1's GPU is free. Rollback: enabled: \"false\" here and replicaCount: 1 in ollama."
```

- [ ] **Step 5: After merge (CONFIRM refresh), verify the server**

```bash
kubectl get pods -n llm -w        # llama-server: init downloads 10.5 GB the first time, then loads (startupProbe allows 10 min)
kubectl logs -n llm deploy/llama-server | grep -E "ggml_cuda_init|Device 0|CUDA0 model buffer|KV buffer|listening"
kubectl top pod -n llm -l app=llama-server
```

Expected: `ggml_cuda_init: found 1 CUDA devices`, `Device 0: Orin, compute capability 8.7`, a `CUDA0 model buffer`, `listening on http://0.0.0.0:8080`; pod memory below 13 Gi. **If the log says `failed to initialize CUDA`** the image is wrong — stop and check the tag/digest. **If the pod is OOMKilled or memory is at the limit**, reduce `server.ctx` to `49152`, then `32768`, and re-verify (update Hermes `context_length` in Task 12 to `ctx/parallel`).

- [ ] **Step 6: Speed and tool-call check**

```bash
kubectl port-forward -n llm svc/llama-server 18080:8080 & PF=$!; sleep 3
curl -s localhost:18080/v1/models | jq -r '.data[0].id'
curl -s localhost:18080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"gemma-4-26b-a4b","messages":[{"role":"user","content":"Write a detailed explanation of how Kubernetes scheduling works."}],"temperature":1.0,"top_p":0.95,"top_k":64,"max_tokens":300}' | jq '{decode_tps:.timings.predicted_per_second, prefill_tps:.timings.prompt_per_second, tokens:.usage.completion_tokens}'
kill $PF
```

Expected: model id `gemma-4-26b-a4b`; `decode_tps` ≥ 14. Below ~8 means CPU fallback: check the `ggml_cuda_init` log line.

---

### Task 8: Server alerts and validation spikes S1, S2 (plus S5-lite)

**Files:**
- Create: `cluster/apps/ai/llm/server/templates/prometheusrule.yaml`
- Create (scratch, not committed): `/tmp/aux_quality.py`, `/tmp/concurrency_probe.py`

**Interfaces:**
- Consumes: running `llama-server` (Task 7), metrics `llamacpp:predicted_tokens_seconds`, `llamacpp:prompt_tokens_seconds`.
- Produces: alerts `LlamaServerUnavailable`, `LlamaServerSlow`; go/no-go results for S1, S2 that gate Tasks 9–12.

- [ ] **Step 1: Confirm the metric names against the live server (read-only)**

```bash
kubectl port-forward -n llm svc/llama-server 18080:8080 & PF=$!; sleep 3
curl -s localhost:18080/metrics | grep -E "^llamacpp:(predicted_tokens_seconds|prompt_tokens_seconds|requests_processing) "
kill $PF
```

Expected: three lines. If a name differs, use the exact name printed in the rule below.

- [ ] **Step 2: Branch and write the rule**

```bash
git checkout main && git pull -q && git checkout -b feat/llm-server-alerts
```

`cluster/apps/ai/llm/server/templates/prometheusrule.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: llama-server
  namespace: llm
  labels:
    app: kube-prometheus-stack
    release: prometheus-stack
spec:
  groups:
    - name: llama-server
      rules:
        - alert: LlamaServerUnavailable
          expr: kube_deployment_status_replicas_available{namespace="llm",deployment="llama-server"} < 1
          for: 10m
          labels:
            severity: critical
          annotations:
            summary: llama-server has no available replica
            description: >-
              Hermes and Honcho fall back to the cloud providers while this is
              down. Check GPU registration (NodeGpuUnavailable), the model PVC
              and the pod logs.
        - alert: LlamaServerSlow
          expr: llamacpp:predicted_tokens_seconds > 0 and llamacpp:predicted_tokens_seconds < 8
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: llama-server generation is below 8 tok/s
            description: >-
              A healthy GPU run is 14-16 tok/s; about 6 tok/s means CPU
              fallback (usually a CUDA 13 image or a lost GPU). Check the
              startup log for ggml_cuda_init errors.
```

- [ ] **Step 3: Validate**

```bash
helm template llm-server cluster/apps/ai/llm/server > /tmp/srv.yaml && kubectl apply --dry-run=server -f /tmp/srv.yaml 2>&1 | grep -i -E "prometheusrule|error"
```

Expected: `prometheusrule.monitoring.coreos.com/llama-server created (server dry run)`.

- [ ] **Step 4: Commit and open the PR**

```bash
git add cluster/apps/ai/llm/server/templates/prometheusrule.yaml
git commit -m "feat(llm): alert on llama-server unavailable or running on CPU"
git push -u origin feat/llm-server-alerts
gh pr create --base main --label area/cluster --label enhancement --title "feat(llm): alert on llama-server unavailable or running on CPU" \
  --body "LlamaServerUnavailable (no replica for 10m) and LlamaServerSlow (<8 tok/s for 10m, the CPU-fallback signature). Metric names verified against the live /metrics."
```

- [ ] **Step 5: S5-lite — parallel tool calls and Hermes-relevant tool shape**

```bash
kubectl port-forward -n llm svc/llama-server 18080:8080 & PF=$!; sleep 3
cat > /tmp/tool_par.json <<'EOF'
{"model":"gemma-4-26b-a4b","temperature":1.0,"top_p":0.95,"top_k":64,"max_tokens":400,"parallel_tool_calls":true,
 "messages":[{"role":"user","content":"Check the pods in namespace ollama, and also tell me the weather in Warsaw."}],
 "tools":[
  {"type":"function","function":{"name":"kubectl_get","description":"Run kubectl get for a resource","parameters":{"type":"object","properties":{"resource":{"type":"string"},"namespace":{"type":"string"}},"required":["resource"]}}},
  {"type":"function","function":{"name":"get_weather","description":"Get current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}
EOF
for n in 1 2 3 4 5; do curl -s localhost:18080/v1/chat/completions -d @/tmp/tool_par.json | jq -c '[.choices[0].message.tool_calls[]?.function.name]'; done
kill $PF
```

Expected: at least 3 of 5 lines contain both `kubectl_get` and `get_weather` (measured earlier: 2/3). Record the ratio in the PR discussion; it is the baseline for Task 11's canary.

- [ ] **Step 6: S2 — concurrency and over-context behavior**

Create `/tmp/concurrency_probe.py`:

```python
#!/usr/bin/env python3
"""S2: an interactive request must stay responsive while a long generation runs."""
import json
import threading
import time
import urllib.request

URL = "http://localhost:18080/v1/chat/completions"
MODEL = "gemma-4-26b-a4b"
results = {}


def call(name, prompt, max_tokens):
    body = json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                       "temperature": 1.0, "top_p": 0.95, "top_k": 64, "max_tokens": max_tokens}).encode()
    req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            data = json.load(r)
        dt = time.time() - t0
        n = data["usage"]["completion_tokens"]
        results[name] = {"seconds": round(dt, 1), "tokens": n, "tps": round(n / dt, 1)}
    except Exception as exc:  # noqa: BLE001 - report any failure as a result
        results[name] = {"error": str(exc)}


a = threading.Thread(target=call, args=("background_long", "Write a very long story about a lighthouse.", 500))
b = threading.Thread(target=lambda: (time.sleep(5), call("interactive_short", "Say hello in one sentence.", 32)))
a.start(); b.start(); a.join(); b.join()
print(json.dumps(results, indent=2))
ok = all("error" not in v for v in results.values()) and results["interactive_short"]["seconds"] <= 20
print("PASS" if ok else "FAIL")
raise SystemExit(0 if ok else 1)
```

Run:

```bash
kubectl port-forward -n llm svc/llama-server 18080:8080 & PF=$!; sleep 3
python3 /tmp/concurrency_probe.py; echo "exit=$?"
kubectl top pod -n llm -l app=llama-server
kill $PF
```

Expected: `PASS` (interactive request ≤ 20 s while the long one runs), no errors, pod memory below 13 Gi. If it fails, try `-np 1` with the full context (`server.parallel: 1`) and document that queueing is accepted.

Over-context check (Review Focus 2): send a prompt that exceeds a slot's 32768 tokens and confirm a clean error, not a crash:

```bash
kubectl port-forward -n llm svc/llama-server 18080:8080 & PF=$!; sleep 3
python3 - <<'EOF'
import json, urllib.request, urllib.error
prompt = "lorem ipsum dolor sit amet " * 9000   # ~45k tokens
body = json.dumps({"model":"gemma-4-26b-a4b","messages":[{"role":"user","content":prompt}],"max_tokens":8}).encode()
req = urllib.request.Request("http://localhost:18080/v1/chat/completions", data=body, headers={"Content-Type":"application/json"})
try:
    urllib.request.urlopen(req, timeout=300); print("UNEXPECTED: accepted")
except urllib.error.HTTPError as e:
    print("HTTP", e.code, e.read()[:160])
EOF
kill $PF; kubectl get pods -n llm -l app=llama-server
```

Expected: `HTTP 400` (or similar) mentioning context size, and the pod still `Running 1/1` with 0 restarts.

- [ ] **Step 7: S1 — quality of the local model on auxiliary-style prompts**

Create `/tmp/aux_quality.py`:

```python
#!/usr/bin/env python3
"""S1: objective checks of the local model on Hermes-style auxiliary tasks (3 samples each)."""
import json
import urllib.request

URL = "http://localhost:18080/v1/chat/completions"
MODEL = "gemma-4-26b-a4b"


def chat(system, user, max_tokens=400):
    body = {"model": MODEL, "temperature": 1.0, "top_p": 0.95, "top_k": 64, "max_tokens": max_tokens,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)["choices"][0]["message"]["content"].strip()


TRANSCRIPT = "\n".join(
    f"user: turn {i}: we discussed the kubelet restarting on nv1 because of a DHCP lease and the GPU plugin not re-registering.\n"
    f"assistant: noted, root cause is the extra DHCP address; fix is deleting META key 0x0a."
    for i in range(1, 16))

CASES = [
    ("title", "Write a concise title (at most 8 words, no quotes, no trailing period) for this conversation.",
     "user: my GPU pod is pending on the jetson node\nassistant: the device plugin lost registration after a kubelet restart",
     lambda o: 0 < len(o.split()) <= 8 and '"' not in o),
    ("approval-safe", "Classify the shell command as SAFE or DANGEROUS. Answer with exactly one word.",
     "ls -la /tmp", lambda o: o.strip(" .").upper() == "SAFE"),
    ("approval-danger", "Classify the shell command as SAFE or DANGEROUS. Answer with exactly one word.",
     "rm -rf / --no-preserve-root", lambda o: o.strip(" .").upper() == "DANGEROUS"),
    ("compression", "Summarize the conversation in under 60 words, keeping the root cause and the fix.",
     TRANSCRIPT, lambda o: len(o.split()) < 80 and "DHCP" in o),
    ("json", 'Return ONLY a JSON object {"task": string, "priority": "low"|"medium"|"high"} for this request.',
     "Please renew the TLS certificate before Friday, it is urgent.",
     lambda o: (lambda d: d.get("priority") in ("low", "medium", "high") and "task" in d)(
         json.loads(o.strip().removeprefix("```json").removesuffix("```").strip()))),
]

total = passed = 0
for name, system, user, check in CASES:
    for i in range(3):
        total += 1
        try:
            out = chat(system, user)
            ok = bool(check(out))
        except Exception as exc:  # noqa: BLE001 - a crash is a failed sample
            out, ok = f"<error {exc}>", False
        passed += ok
        print(f"{'PASS' if ok else 'FAIL'} {name}#{i + 1}: {out[:90]!r}")
rate = passed / total
print(f"{passed}/{total} = {rate:.0%}")
raise SystemExit(0 if rate >= 0.9 else 1)
```

Run:

```bash
kubectl port-forward -n llm svc/llama-server 18080:8080 & PF=$!; sleep 3
python3 /tmp/aux_quality.py; echo "exit=$?"
kill $PF
```

Expected: ≥ 90% (14 of 15) pass, exit 0. **If lower:** do not move approval/compression to the local model in Task 9; move only `title_generation`, `profile_describer`, `curator`, `triage_specifier` (low-stakes) and keep the others on OpenRouter. Record the results in the Task 9 PR description.

---

## Phase 3 — Hermes and Honcho on the local model

### Task 9: Hermes auxiliary tasks to the local model

**Files:**
- Modify: `cluster/apps/ai/hermes-agent/values.yaml` (`hermes.config.auxiliary`)

**Interfaces:**
- Consumes: `llama-server` (Task 7), S1 result (Task 8 Step 7).
- Produces: eight auxiliary tasks (`web_extract`, `compression`, `approval`, `title_generation`, `triage_specifier`, `kanban_decomposer`, `profile_describer`, `curator`) on `provider: custom` → `http://llama-server.llm.svc.cluster.local:8080/v1`; `vision`, `skills_hub`, `mcp` unchanged.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/hermes-local-aux
```

- [ ] **Step 2: Failing check**

Run: `grep -c "provider: custom" cluster/apps/ai/hermes-agent/values.yaml` — expected `0`.

- [ ] **Step 3: Apply the edit (scripted, idempotent)**

If S1 was below 90%, edit `LOCAL_TASKS` below to keep only `title_generation`, `profile_describer`, `curator`, `triage_specifier`.

```bash
python3 - <<'EOF'
p = 'cluster/apps/ai/hermes-agent/values.yaml'
s = open(p).read()
start = s.index('    auxiliary:\n')
end = s.index('#    mcp_servers:')
LOCAL_TASKS = ['web_extract', 'compression', 'approval', 'title_generation',
               'triage_specifier', 'kanban_decomposer', 'profile_describer', 'curator']
KEEP = {'vision': ('openrouter', 'google/gemini-2.5-flash-lite'),
        'skills_hub': ('auto', ''), 'mcp': ('auto', ''),
        'web_extract': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'compression': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'approval': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'title_generation': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'triage_specifier': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'kanban_decomposer': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'profile_describer': ('openrouter', 'deepseek/deepseek-v4-flash'),
        'curator': ('openrouter', 'deepseek/deepseek-v4-flash')}
order = ['vision', 'web_extract', 'compression', 'skills_hub', 'approval', 'mcp', 'title_generation',
         'triage_specifier', 'kanban_decomposer', 'profile_describer', 'curator']
blk = '    auxiliary:\n'
for t in order:
    blk += f'      {t}:\n'
    if t in LOCAL_TASKS:
        blk += ('        provider: custom\n        model: gemma-4-26b-a4b\n'
                '        base_url: http://llama-server.llm.svc.cluster.local:8080/v1\n        api_key: local\n')
    else:
        prov, model = KEEP[t]
        blk += f'        provider: {prov}\n        model: "{model}"\n'
open(p, 'w').write(s[:start] + blk + s[end:])
EOF
```

- [ ] **Step 4: Verify the render**

```bash
grep -c "provider: custom" cluster/apps/ai/hermes-agent/values.yaml     # expect 8 (or 4 if S1 gate applied)
helm template hermes cluster/apps/ai/hermes-agent > /tmp/hermes.yaml && echo "helm OK"
python3 - <<'EOF'
import re, yaml
docs = [d for d in yaml.safe_load_all(open('/tmp/hermes.yaml')) if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'hermes-agent-config']
cfg = yaml.safe_load(docs[0]['data']['config.yaml'])
for k, v in cfg['auxiliary'].items():
    print(f"{k:20s} {v['provider']:11s} {v['model']}")
assert cfg['auxiliary']['vision']['provider'] == 'openrouter'
EOF
yamllint cluster/apps/ai/hermes-agent/values.yaml
```

Expected: `helm OK`; the listed providers match the plan; `vision` still `openrouter`; no new yamllint errors.

- [ ] **Step 5: Commit and open the PR**

Set `S1_RESULT` to the summary line `aux_quality.py` printed in Task 8 Step 7 (for example `14/15 = 93%`):

```bash
S1_RESULT="14/15 = 93%"   # <- use the real value from your run
git add cluster/apps/ai/hermes-agent/values.yaml
git commit -m "feat(hermes): run auxiliary tasks on the local llama-server"
git push -u origin feat/hermes-local-aux
gh pr create --base main --label area/cluster --label enhancement --title "feat(hermes): run auxiliary tasks on the local llama-server" \
  --body "Auxiliary tasks (web_extract, compression, approval, title_generation, triage_specifier, kanban_decomposer, profile_describer, curator) now use provider: custom -> llama-server (gemma-4-26b-a4b). vision, skills_hub and mcp are unchanged. S1 quality result: ${S1_RESULT}."
```

- [ ] **Step 6: After merge (CONFIRM refresh; the Hermes pod restarts, ~1 min downtime), verify local serving**

```bash
kubectl rollout status deploy/hermes-agent -n hermes-agent --timeout=300s
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"; hermes -Q chat -q "Reply with the single word: ready"'
kubectl logs -n llm deploy/llama-server --tail=40 | grep -c "POST /v1/chat/completions"
```

Expected: the reply is `ready`; the llama-server log shows chat-completion requests (title generation and other aux calls after a new session).

- [ ] **Step 7: Fallback behavior when the local endpoint is down (Review Focus 1) — CONFIRM**

This temporarily breaks the local endpoint for one profile inside the pod (reverted by pod restart or by the last command):

```bash
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"; \
  hermes -p researcher config set auxiliary.title_generation.base_url http://127.0.0.1:9/v1 && \
  hermes -p researcher -Q chat -q "Say hi"; echo "exit=$?"; \
  hermes -p researcher config set auxiliary.title_generation.base_url http://llama-server.llm.svc.cluster.local:8080/v1'
kubectl logs -n hermes-agent deploy/hermes-agent -c hermes-agent --tail=40 | grep -i -E "title|fallback|connection|refused" | tail
```

Expected outcome A: the chat succeeds and the log shows a fallback/retry for the title task → auxiliary calls are covered by the cloud fallback. **Outcome B:** the title task errors and there is no fallback → for that class of task an outage of llama-server means degraded behavior. In that case revert `approval` and `compression` (the ones on the critical path) to `openrouter` in this PR, keep only low-stakes tasks local, and note it in the PR. Record which outcome occurred.

---

### Task 10: Honcho LLM calls to the local model

**Files:**
- Modify: `cluster/apps/ai/honcho/templates/_helpers.tpl`

**Interfaces:**
- Consumes: `llama-server`. Produces: Honcho deriver, summary and dialectic minimal/low/medium **primary** models on the local server; `FALLBACK__*` entries (27 lines) untouched so OpenRouter remains the fallback; dialectic `high`/`max` and `DREAM_*` stay on the cloud (they need stronger reasoning).

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/honcho-local-llm
```

- [ ] **Step 2: Failing check**

Run: `grep -c "llama-server" cluster/apps/ai/honcho/templates/_helpers.tpl` — expected `0`.

- [ ] **Step 3: Apply the scripted edit**

```bash
python3 - <<'EOF'
import re
p = 'cluster/apps/ai/honcho/templates/_helpers.tpl'
src = open(p).read()
LOCAL_URL = 'http://llama-server.llm.svc.cluster.local:8080/v1'
LOCAL_MODEL = 'gemma-4-26b-a4b'
pat = re.compile(r'^(DERIVER_MODEL_CONFIG|SUMMARY_MODEL_CONFIG|DIALECTIC_LEVELS__(?:minimal|low|medium)__MODEL_CONFIG)__(MODEL|OVERRIDES__BASE_URL)$')
lines = src.split('\n'); out = []; changed = []; i = 0
while i < len(lines):
    m = re.match(r'^- name: (\S+)$', lines[i])
    if m and pat.match(m.group(1)) and i + 1 < len(lines) and lines[i + 1].startswith('  value: '):
        kind = pat.match(m.group(1)).group(2)
        out += [lines[i], '  value: ' + (LOCAL_MODEL if kind == 'MODEL' else LOCAL_URL)]
        changed.append(m.group(1)); i += 2; continue
    out.append(lines[i]); i += 1
open(p, 'w').write('\n'.join(out))
print(len(changed), 'variables changed')
EOF
```

Expected output: `10 variables changed`.

- [ ] **Step 4: Verify**

```bash
git diff --stat cluster/apps/ai/honcho/templates/_helpers.tpl        # 10 lines changed each side
grep -c "FALLBACK" cluster/apps/ai/honcho/templates/_helpers.tpl     # expect 27 (unchanged)
grep -c "llama-server.llm.svc" cluster/apps/ai/honcho/templates/_helpers.tpl   # expect 5
grep -c "openrouter.ai" cluster/apps/ai/honcho/templates/_helpers.tpl          # expect 13
(cd cluster/apps/ai/honcho && helm dependency build >/dev/null 2>&1; helm template honcho . >/dev/null && echo "helm OK")
```

- [ ] **Step 5: Commit and open the PR**

```bash
git add cluster/apps/ai/honcho/templates/_helpers.tpl
git commit -m "feat(honcho): run deriver, summary and low-tier dialectic on the local model"
git push -u origin feat/honcho-local-llm
gh pr create --base main --label area/cluster --label enhancement --title "feat(honcho): run deriver, summary and low-tier dialectic on the local model" \
  --body "Primary models for DERIVER, SUMMARY and DIALECTIC minimal/low/medium now use llama-server (gemma-4-26b-a4b). All FALLBACK__* entries still point at OpenRouter. dialectic high/max and DREAM_* stay on the cloud."
```

- [ ] **Step 6: After merge (CONFIRM refresh), verify**

```bash
kubectl rollout status deploy/honcho-api deploy/honcho-deriver -n honcho --timeout=300s
kubectl logs -n honcho deploy/honcho-deriver --tail=80 | grep -i -E "error|traceback|fallback" | tail
kubectl logs -n llm deploy/llama-server --tail=60 | grep -c "POST /v1/chat/completions"
```

Expected: rollouts complete; no errors in the deriver; llama-server serving requests after Hermes activity generates memory writes. If the deriver logs repeated fallbacks/timeouts, the local queue is saturated: consider `-np 1`/smaller batches or moving the deriver back to the cloud in a follow-up.

---

### Task 11: Per-profile config overlays and the `researcher` canary

**Files:**
- Create: `cluster/apps/ai/hermes-agent/templates/profile-overlays-configmap.yaml`
- Modify: `cluster/apps/ai/hermes-agent/templates/deployment.yaml` (init container, volume, checksum annotation)
- Modify: `cluster/apps/ai/hermes-agent/values.yaml` (`hermes.profileOverlays`)

**Interfaces:**
- Produces: values key `hermes.profileOverlays.<profile>` (a mapping deep-merged into `/opt/data/profiles/<profile>/config.yaml` on every pod start by the `profile-config-seeder` init container; lists are replaced wholesale). Missing profile directories are skipped (profiles are created imperatively).

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/hermes-profile-overlays
```

- [ ] **Step 2: Write and run the seeder test first**

Create `/tmp/seed_profiles.py` (this exact script becomes the init container body in Step 4):

```python
import os
import sys

import yaml

# Deep-merges per-profile overlays (ConfigMap files named <profile>.yaml) into
# <HERMES_HOME>/profiles/<profile>/config.yaml. Profiles are created
# imperatively inside the pod, so a missing profile directory is skipped.
overlay_dir = os.environ.get('OVERLAY_DIR', '/profile-overlays')
hermes_home = os.environ.get('HERMES_HOME', '/opt/data')
profiles_dir = os.path.join(hermes_home, 'profiles')


def deep_merge(base, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v


for fname in sorted(os.listdir(overlay_dir)):
    if not fname.endswith('.yaml'):
        continue
    profile = fname[:-len('.yaml')]
    target = os.path.join(profiles_dir, profile, 'config.yaml')
    if not os.path.isfile(target):
        print(f'skip {profile}: {target} not found', file=sys.stderr)
        continue
    with open(os.path.join(overlay_dir, fname)) as f:
        overrides = yaml.safe_load(f) or {}
    with open(target) as f:
        config = yaml.safe_load(f) or {}
    deep_merge(config, overrides)
    with open(target, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    print(f'merged overlay into {target}')
```

Test it in a throwaway venv (no cluster involved):

```bash
T=$(mktemp -d) && python3 -m venv $T/venv && $T/venv/bin/pip install -q pyyaml
mkdir -p $T/home/profiles/researcher $T/home/profiles/devops $T/overlays
printf 'model:\n  provider: openrouter\n  default: deepseek/deepseek-v4-pro\ntoolsets: [terminal, file, web]\ntts:\n  provider: edge\n  edge: {voice: en-US-AriaNeural}\n' > $T/home/profiles/researcher/config.yaml
cp $T/home/profiles/researcher/config.yaml $T/home/profiles/devops/config.yaml
printf 'model:\n  provider: custom\n  default: gemma-4-26b-a4b\n' > $T/overlays/researcher.yaml
printf 'model: {provider: custom}\n' > $T/overlays/mobile-dev.yaml
HERMES_HOME=$T/home OVERLAY_DIR=$T/overlays $T/venv/bin/python /tmp/seed_profiles.py
grep -E "provider|default" $T/home/profiles/researcher/config.yaml; grep -c "openrouter" $T/home/profiles/devops/config.yaml
cp $T/home/profiles/researcher/config.yaml $T/after1.yaml
HERMES_HOME=$T/home OVERLAY_DIR=$T/overlays $T/venv/bin/python /tmp/seed_profiles.py >/dev/null 2>&1; diff $T/after1.yaml $T/home/profiles/researcher/config.yaml && echo IDEMPOTENT
```

Expected: `skip mobile-dev … not found` (stderr), `merged overlay into …researcher/config.yaml`; researcher shows `provider: custom` and `default: gemma-4-26b-a4b` while `toolsets` and `tts.edge` are preserved; devops still contains `openrouter` (count 1); `IDEMPOTENT`.

- [ ] **Step 3: Add the overlay ConfigMap template**

`cluster/apps/ai/hermes-agent/templates/profile-overlays-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-profile-overlays
  namespace: hermes-agent
data:
{{- range $name, $overlay := .Values.hermes.profileOverlays }}
  {{ $name }}.yaml: |
{{ $overlay | toYaml | indent 4 }}
{{- end }}
```

- [ ] **Step 4: Wire the init container, volume and checksum into the deployment**

In `cluster/apps/ai/hermes-agent/templates/deployment.yaml`:

(a) In `spec.template.metadata.annotations`, after the existing `checksum/config` entry add:

```yaml
        checksum/profile-overlays:
          {{include (print $.Template.BasePath "/profile-overlays-configmap.yaml") . | sha256sum}}
```

(b) In `initContainers`, immediately **after** the `honcho-seeder` container block (and before `containers:`), add:

```yaml
        - name: profile-config-seeder
          image: "{{ .Values.hermes.image.repository }}:{{ .Values.hermes.image.tag }}"
          command:
            - python3
            - -c
            - |
              import os
              import sys

              import yaml

              # Deep-merges per-profile overlays (ConfigMap files named <profile>.yaml) into
              # <HERMES_HOME>/profiles/<profile>/config.yaml. Profiles are created
              # imperatively inside the pod, so a missing profile directory is skipped.
              overlay_dir = os.environ.get('OVERLAY_DIR', '/profile-overlays')
              hermes_home = os.environ.get('HERMES_HOME', '/opt/data')
              profiles_dir = os.path.join(hermes_home, 'profiles')


              def deep_merge(base, src):
                  for k, v in src.items():
                      if isinstance(v, dict) and isinstance(base.get(k), dict):
                          deep_merge(base[k], v)
                      else:
                          base[k] = v


              for fname in sorted(os.listdir(overlay_dir)):
                  if not fname.endswith('.yaml'):
                      continue
                  profile = fname[:-len('.yaml')]
                  target = os.path.join(profiles_dir, profile, 'config.yaml')
                  if not os.path.isfile(target):
                      print(f'skip {profile}: {target} not found', file=sys.stderr)
                      continue
                  with open(os.path.join(overlay_dir, fname)) as f:
                      overrides = yaml.safe_load(f) or {}
                  with open(target) as f:
                      config = yaml.safe_load(f) or {}
                  deep_merge(config, overrides)
                  with open(target, 'w') as f:
                      yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
                  print(f'merged overlay into {target}')
          env:
            - name: HERMES_HOME
              value: /opt/data
          volumeMounts:
            - name: data
              mountPath: /opt/data
            - name: profile-overlays
              mountPath: /profile-overlays
```

(c) In `volumes`, after the `honcho-config` volume add:

```yaml
        - name: profile-overlays
          configMap:
            name: hermes-agent-profile-overlays
```

- [ ] **Step 5: Add the canary overlay in values**

In `cluster/apps/ai/hermes-agent/values.yaml`, add under `hermes:` (sibling of `config:`), after the whole `config:` block and before the `signalCli:` top-level key:

```yaml
  # Per-profile config overlays deep-merged into /opt/data/profiles/<name>/config.yaml
  # on every pod start (lists are replaced). Profiles themselves are created
  # imperatively; overlays for profiles that do not exist yet are skipped.
  profileOverlays:
    researcher:
      model:
        provider: custom
        default: gemma-4-26b-a4b
        base_url: http://llama-server.llm.svc.cluster.local:8080/v1
        api_key: local
        context_length: 32768
      fallback_providers:
        - provider: openrouter
          model: deepseek/deepseek-v4-pro
        - provider: anthropic
          model: claude-sonnet-4-6
```

- [ ] **Step 6: Render and validate**

```bash
helm template hermes cluster/apps/ai/hermes-agent > /tmp/hermes.yaml && echo "helm OK"
python3 - <<'EOF'
import yaml
docs = list(yaml.safe_load_all(open('/tmp/hermes.yaml')))
cm = [d for d in docs if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'hermes-agent-profile-overlays'][0]
print(list(cm['data'].keys()))
print(yaml.safe_load(cm['data']['researcher.yaml'])['model']['context_length'])
dep = [d for d in docs if d and d.get('kind') == 'Deployment' and d['metadata']['name'] == 'hermes-agent'][0]
names = [c['name'] for c in dep['spec']['template']['spec']['initContainers']]
print(names); assert names.index('profile-config-seeder') > names.index('honcho-seeder')
EOF
yamllint cluster/apps/ai/hermes-agent/values.yaml
```

Expected: `helm OK`; `['researcher.yaml']`; `32768`; init container order ends with `honcho-seeder`, `profile-config-seeder`.

- [ ] **Step 7: Commit, open the PR**

```bash
git add cluster/apps/ai/hermes-agent
git commit -m "feat(hermes): seed per-profile config overlays; canary researcher on the local model"
git push -u origin feat/hermes-profile-overlays
gh pr create --base main --label area/cluster --label enhancement --title "feat(hermes): per-profile config overlays; canary researcher on the local model" \
  --body "Profiles keep their own config.yaml on the PVC and were unreachable from values.yaml. New profile-config-seeder init container deep-merges hermes.profileOverlays.<name> on every start (idempotent, skips missing profiles). researcher is the canary: model -> llama-server, context_length 32768 (= ctx/np), cloud fallback chain openrouter deepseek-v4-pro -> anthropic. Seeder logic tested locally (merge, preserve, skip, idempotent)."
```

- [ ] **Step 8: After merge (CONFIRM refresh), verify the canary end to end**

```bash
kubectl rollout status deploy/hermes-agent -n hermes-agent --timeout=300s
kubectl logs -n hermes-agent deploy/hermes-agent -c profile-config-seeder
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- grep -A6 "^model:" /opt/data/profiles/researcher/config.yaml
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"; hermes -p researcher -Q chat -q "Use the terminal tool to run: uname -a, and the file tool to read /etc/hostname. Report both results."'
kubectl logs -n llm deploy/llama-server --tail=80 | grep -E "tool|POST /v1/chat/completions" | tail -5
```

Expected: `merged overlay into /opt/data/profiles/researcher/config.yaml`; researcher config shows `provider: custom`; the one-shot run completes with both tool results (Review Focus 3: note whether both tool calls happened in one turn or sequentially — both are acceptable if the task completes); llama-server shows the requests.

- [ ] **Step 9: Main-model fallback when the local endpoint is down (Review Focus 1) — CONFIRM**

This temporarily points the researcher profile at a dead endpoint (reverted in the same command):

```bash
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"; \
  hermes -p researcher config set model.base_url http://127.0.0.1:9/v1 && \
  hermes -p researcher -Q chat -q "Reply with the single word: fallback"; echo "exit=$?"; \
  hermes -p researcher config set model.base_url http://llama-server.llm.svc.cluster.local:8080/v1'
kubectl logs -n hermes-agent deploy/hermes-agent -c hermes-agent --tail=60 | grep -i -E "fallback|openrouter|connection|refused" | tail
```

Expected: the reply arrives (`fallback`) and the log shows the switch to the OpenRouter fallback provider. If the run errors instead of falling back, stop: the local-first design's resilience claim does not hold for the main model, and Task 12 must not proceed until the cause is understood (check `fallback_providers` was merged into the researcher config: `grep -A4 fallback_providers /opt/data/profiles/researcher/config.yaml`).

Then **observe for at least 24 hours of normal researcher use** before Task 12. Rollback: remove the `researcher` overlay (the next pod start does **not** revert an already-merged file; also run `hermes -p researcher config set model.provider openrouter` and `… model.default deepseek/deepseek-v4-pro` — overlays only ever add keys).

---

### Task 12: Roll the local model out to the remaining profiles and the default profile

**Files:**
- Modify: `cluster/apps/ai/hermes-agent/values.yaml`

**Interfaces:**
- Consumes: successful canary (Task 11 + 24 h). Produces: all six worker profiles and the default profile on the local model with the cloud fallback chain.

- [ ] **Step 1: Gate check (CONFIRM with the user that the canary is acceptable)**

Ask the user; do not proceed on assumption. Also read the researcher's llama-server error rate: `kubectl logs -n llm deploy/llama-server --since=24h | grep -c -i -E "error|failed"`.

- [ ] **Step 2: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/hermes-local-main-model
```

- [ ] **Step 3: Failing check**

Run: `python3 -c "import yaml;d=yaml.safe_load(open('cluster/apps/ai/hermes-agent/values.yaml'));print(sorted(d['hermes']['profileOverlays']))"` — expected `['researcher']`.

- [ ] **Step 4: Extend the overlays and set the default profile**

Replace the `profileOverlays:` block from Task 11 with this (YAML anchors keep it DRY):

```yaml
  profileOverlays:
    researcher: &localMainModel
      model:
        provider: custom
        default: gemma-4-26b-a4b
        base_url: http://llama-server.llm.svc.cluster.local:8080/v1
        api_key: local
        context_length: 32768
      fallback_providers:
        - provider: openrouter
          model: deepseek/deepseek-v4-pro
        - provider: anthropic
          model: claude-sonnet-4-6
    devops: *localMainModel
    dotnet-dev: *localMainModel
    mobile-dev: *localMainModel
    node-dev: *localMainModel
    orchestrator: *localMainModel
```

And in `hermes.config` (the default profile) replace:

```yaml
    model:
      provider: openrouter
      default: "deepseek/deepseek-v4-pro"
```

with:

```yaml
    model:
      provider: custom
      default: gemma-4-26b-a4b
      base_url: http://llama-server.llm.svc.cluster.local:8080/v1
      api_key: local
      context_length: 32768
```

and replace the default `fallback_providers:` list:

```yaml
    fallback_providers:
      - provider: openrouter
        model: "deepseek/deepseek-v4-flash"
      - provider: anthropic
        model: claude-sonnet-4-6
```

with:

```yaml
    fallback_providers:
      - provider: openrouter
        model: "deepseek/deepseek-v4-pro"
      - provider: anthropic
        model: claude-sonnet-4-6
```

- [ ] **Step 5: Verify**

```bash
helm template hermes cluster/apps/ai/hermes-agent > /tmp/hermes.yaml && echo "helm OK"
python3 - <<'EOF'
import yaml
docs = list(yaml.safe_load_all(open('/tmp/hermes.yaml')))
cm = [d for d in docs if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'hermes-agent-profile-overlays'][0]
print(sorted(cm['data']))
for n, t in cm['data'].items():
    m = yaml.safe_load(t)['model']; assert m['provider'] == 'custom' and m['context_length'] == 32768, n
main = [d for d in docs if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'hermes-agent-config'][0]
c = yaml.safe_load(main['data']['config.yaml'])
print(c['model']['provider'], c['fallback_providers'][0]['model'])
EOF
```

Expected: six profile keys; `custom deepseek/deepseek-v4-pro`.

- [ ] **Step 6: Commit and open the PR**

```bash
git add cluster/apps/ai/hermes-agent/values.yaml
git commit -m "feat(hermes): local-first main model for all profiles with cloud fallback"
git push -u origin feat/hermes-local-main-model
gh pr create --base main --label area/cluster --label enhancement --title "feat(hermes): local-first main model for all profiles with cloud fallback" \
  --body "After the researcher canary: devops, dotnet-dev, mobile-dev, node-dev, orchestrator and the default profile use llama-server (gemma-4-26b-a4b, context_length 32768). Fallback chain: OpenRouter deepseek-v4-pro -> Anthropic. Rollback: revert this PR and run 'hermes -p <name> config set model.provider openrouter' (overlays only add keys)."
```

- [ ] **Step 7: After merge (CONFIRM refresh), verify**

```bash
kubectl rollout status deploy/hermes-agent -n hermes-agent --timeout=300s
for p in devops dotnet-dev mobile-dev node-dev orchestrator; do echo -n "$p: "; kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- grep -m1 "provider:" /opt/data/profiles/$p/config.yaml; done
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- grep -A5 "^model:" /opt/data/config.yaml
```

Expected: every profile shows `provider: custom`. Send a Discord/Signal message to the default profile and confirm it is answered and llama-server logged the request.

---

## Phase 4 — Speech

### Task 13: CPU speech-to-text server and Hermes STT wiring

**Files:**
- Modify: `cluster/apps/ai/llm/app-config.yaml` (append `stt` entry)
- Create: `cluster/apps/ai/llm/stt/Chart.yaml`, `values.yaml`, `templates/pvc.yaml`, `templates/deployment.yaml`, `templates/service.yaml`, `templates/prometheusrule.yaml`
- Modify (second PR, after S3 passes): `cluster/apps/ai/hermes-agent/values.yaml` (`hermes.config.stt`)

**Interfaces:**
- Produces: Service `speaches` on port 8000 (`/v1/audio/transcriptions`, OpenAI-compatible), model id `deepdml/faster-whisper-large-v3-turbo-ct2` (or the fallback `Systran/faster-whisper-small`), ≤ 3 CPU cores, on x86 nodes.

- [ ] **Step 1: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/llm-stt
```

- [ ] **Step 2: Failing check**

Run: `helm template x cluster/apps/ai/llm/stt 2>&1 | head -1` — expected: error.

- [ ] **Step 3: Register and create the chart**

Append to `cluster/apps/ai/llm/app-config.yaml`:

```yaml
- enabled: "true"
  appSubfolder: stt
  namespace: llm
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  managedNamespaceMetadata:
    labels:
      pod-security.kubernetes.io/enforce: baseline
      pod-security.kubernetes.io/warn: baseline
```

`cluster/apps/ai/llm/stt/Chart.yaml`:

```yaml
apiVersion: v2
name: llm-stt
type: application
version: 1.0.0
```

`cluster/apps/ai/llm/stt/values.yaml`:

```yaml
stt:
  image:
    repository: ghcr.io/speaches-ai/speaches
    tag: "0.9.0-rc.3-cpu@sha256:2163775b6df5e451a71200e8f675fed68dbd8ab184fc604453d549e486f22fd2"
  storage: 10Gi
  resources:
    requests:
      cpu: 500m
      memory: 1Gi
    limits:
      cpu: "3"
      memory: 4Gi
```

`templates/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: speaches-models
  namespace: llm
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: {{ .Values.stt.storage }}
```

`templates/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: speaches
  namespace: llm
spec:
  type: ClusterIP
  selector:
    app: speaches
  ports:
    - name: http
      port: 8000
      targetPort: http
      protocol: TCP
```

`templates/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: speaches
  namespace: llm
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: speaches
  template:
    metadata:
      labels:
        app: speaches
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
      containers:
        - name: speaches
          image: "{{ .Values.stt.image.repository }}:{{ .Values.stt.image.tag }}"
          ports:
            - name: http
              containerPort: 8000
              protocol: TCP
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 6
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 30
            failureThreshold: 5
          resources: {{ toYaml .Values.stt.resources | nindent 12 }}
          volumeMounts:
            - name: models
              mountPath: /home/ubuntu/.cache/huggingface/hub
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: speaches-models
```

`templates/prometheusrule.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: speaches
  namespace: llm
  labels:
    app: kube-prometheus-stack
    release: prometheus-stack
spec:
  groups:
    - name: speaches
      rules:
        - alert: SpeachesUnavailable
          expr: kube_deployment_status_replicas_available{namespace="llm",deployment="speaches"} < 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: Speech-to-text server has no available replica
            description: Voice-note transcription fails until the speaches deployment is back.
```

- [ ] **Step 4: Validate, commit, open the PR**

```bash
helm template llm-stt cluster/apps/ai/llm/stt > /tmp/stt.yaml && echo "helm OK"
grep -c "cpu: \"3\"" /tmp/stt.yaml    # expect 1 (hard CPU limit)
yamllint cluster/apps/ai/llm/app-config.yaml cluster/apps/ai/llm/stt/Chart.yaml cluster/apps/ai/llm/stt/values.yaml
git add cluster/apps/ai/llm
git commit -m "feat(llm): add CPU speech-to-text server (Speaches / faster-whisper)"
git push -u origin feat/llm-stt
gh pr create --base main --label area/cluster --label enhancement --title "feat(llm): add CPU speech-to-text server (Speaches)" \
  --body "OpenAI-compatible /v1/audio/transcriptions on the x86 nodes, 3-core hard limit, HF model cache on a 10Gi PVC. Nothing consumes it yet; Hermes is wired after the S3 speed test."
```

- [ ] **Step 5: After merge (CONFIRM refresh), download the model and run S3 (CPU speed)**

```bash
kubectl port-forward -n llm svc/speaches 18000:8000 & PF=$!; sleep 4
curl -s -X POST localhost:18000/v1/models/deepdml/faster-whisper-large-v3-turbo-ct2 | head -c 300; echo
curl -sL -o /tmp/jfk.flac https://github.com/SYSTRAN/faster-whisper/raw/master/tests/data/jfk.flac
for i in 1 2 3; do /usr/bin/time -f "wall=%es" curl -s -F file=@/tmp/jfk.flac -F model=deepdml/faster-whisper-large-v3-turbo-ct2 localhost:18000/v1/audio/transcriptions | head -c 200; echo; done
kill $PF
kubectl top pod -n llm -l app=speaches
```

The clip is 11 s. Compute real-time factor = wall/11.
Expected: transcript begins with "And so my fellow Americans…"; **wall ≤ 11 s (RTF ≤ 1.0)** on runs 2–3 (run 1 loads the model). **If RTF > 1.0:** repeat with `Systran/faster-whisper-small` (`POST /v1/models/Systran/faster-whisper-small`, `-F model=Systran/faster-whisper-small`) and use it as the model id below. Check etcd health afterward: `talosctl -n 192.168.48.2 etcd status` shows the same leader and no growing DB size or errors.

Persistence check (the cache path is the Speaches image's default HF hub directory): restart the pod (`kubectl delete pod -n llm -l app=speaches`, **CONFIRM**) and confirm the model survived: `kubectl port-forward -n llm svc/speaches 18000:8000 & sleep 4; curl -s localhost:18000/v1/models | jq -r '.data[].id'`. Expected: the model id is still listed without a new download. If not, find the real cache path with `kubectl exec -n llm deploy/speaches -- sh -c 'echo $HF_HOME; ls -d /home/*/.cache/huggingface/hub'` and correct the `mountPath` in `templates/deployment.yaml`.

- [ ] **Step 6: Wire Hermes STT (second PR)**

```bash
git checkout main && git pull -q && git checkout -b feat/hermes-local-stt
```

In `cluster/apps/ai/hermes-agent/values.yaml`, add to `hermes.config` (next to `memory:`; use the model id that passed S3):

```yaml
    stt:
      provider: openai
      openai:
        model: deepdml/faster-whisper-large-v3-turbo-ct2
        base_url: http://speaches.llm.svc.cluster.local:8000/v1
        api_key: local
```

Verify: `helm template hermes cluster/apps/ai/hermes-agent | grep -B1 -A5 "base_url: http://speaches"`.

Set `S3_RTF` to the real-time factor you measured in Step 5 (wall seconds / 11):

```bash
S3_RTF="0.6"   # <- use the real value from your run
git add cluster/apps/ai/hermes-agent/values.yaml
git commit -m "feat(hermes): transcribe voice notes on the local Speaches server"
git push -u origin feat/hermes-local-stt
gh pr create --base main --label area/cluster --label enhancement --title "feat(hermes): transcribe voice notes on the local Speaches server" \
  --body "stt.provider openai with base_url/api_key overridden to the in-cluster Speaches service (config keys read from tools/transcription_cloud.py). S3 real-time factor: ${S3_RTF}. Rollback: provider: local."
```

- [ ] **Step 7: After merge (CONFIRM refresh), verify with a real voice note**

Send a Signal voice note to Hermes; expected: it is transcribed and answered; `kubectl logs -n llm deploy/speaches --tail=20` shows a `POST /v1/audio/transcriptions`. Note the failure mode: if Speaches is down, transcription of voice notes fails (no automatic fallback was verified); the `SpeachesUnavailable` alert covers it.

---

### Task 14: Local text-to-speech (Piper)

**Files:**
- Modify: `cluster/apps/ai/hermes-agent/templates/deployment.yaml` (`postStart` command)
- Modify: `cluster/apps/ai/hermes-agent/values.yaml` (default `tts`, and `tts` on every overlay)

**Interfaces:**
- Consumes: `hermes.profileOverlays` (Task 11/12). Produces: `tts.provider: piper` (voice `en_US-lessac-medium`) on the default profile and all six worker profiles; voices cached under `<HERMES_HOME>/cache/piper-voices/` on the PVC.

- [ ] **Step 1: Confirm the current state (read-only)**

```bash
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"; python3 -c "import piper" 2>&1 | tail -1; grep -A1 "^tts:" /opt/data/config.yaml | head -2'
```

Expected: `ModuleNotFoundError: No module named 'piper'` and `provider: edge` (the failing baseline: piper missing, TTS is cloud).

- [ ] **Step 2: Branch**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q && git checkout -b feat/hermes-local-tts
```

- [ ] **Step 3: Install `piper-tts` at start (same pattern as `honcho-ai`)**

In `cluster/apps/ai/hermes-agent/templates/deployment.yaml`, in the `postStart` exec command, replace:

```yaml
                  - "VIRTUAL_ENV=/opt/hermes/.venv uv pip install honcho-ai"
```

with:

```yaml
                  - "VIRTUAL_ENV=/opt/hermes/.venv uv pip install honcho-ai piper-tts"
```

- [ ] **Step 4: Set the provider everywhere**

In `values.yaml` `hermes.config` add (next to `memory:`):

```yaml
    tts:
      provider: piper
      piper:
        voice: en_US-lessac-medium
```

and add a `tts` key to the shared overlay so every worker profile gets it. In `profileOverlays.researcher` (the anchored `&localMainModel` mapping), append:

```yaml
      tts:
        provider: piper
        piper:
          voice: en_US-lessac-medium
```

(All other profiles reference the same anchor, so they inherit it.)

- [ ] **Step 5: Verify the render**

```bash
helm template hermes cluster/apps/ai/hermes-agent > /tmp/hermes.yaml && echo "helm OK"
grep -c "honcho-ai piper-tts" /tmp/hermes.yaml     # expect 1
python3 - <<'EOF'
import yaml
docs = list(yaml.safe_load_all(open('/tmp/hermes.yaml')))
cm = [d for d in docs if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'hermes-agent-profile-overlays'][0]
for n, t in cm['data'].items():
    assert yaml.safe_load(t)['tts']['provider'] == 'piper', n
main = yaml.safe_load([d for d in docs if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'hermes-agent-config'][0]['data']['config.yaml'])
assert main['tts']['provider'] == 'piper'
print("all profiles and default -> piper")
EOF
```

- [ ] **Step 6: Commit and open the PR**

```bash
git add cluster/apps/ai/hermes-agent
git commit -m "feat(hermes): use local Piper TTS instead of Edge (cloud) voices"
git push -u origin feat/hermes-local-tts
gh pr create --base main --label area/cluster --label enhancement --title "feat(hermes): use local Piper TTS instead of Edge (cloud) voices" \
  --body "The active TTS provider was edge (Microsoft online voices) on the default profile and every profile. Switches to local piper (en_US-lessac-medium). piper-tts was not in the image, so it is installed at pod start like honcho-ai (needs PyPI at start, same limitation)."
```

- [ ] **Step 7: After merge (CONFIRM refresh), pre-download the voices once (needs internet), then verify**

Voices are cached per profile home; do it once so later restarts work offline:

```bash
kubectl rollout status deploy/hermes-agent -n hermes-agent --timeout=300s
for h in /opt/data /opt/data/profiles/devops /opt/data/profiles/dotnet-dev /opt/data/profiles/mobile-dev /opt/data/profiles/node-dev /opt/data/profiles/orchestrator /opt/data/profiles/researcher; do
  kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c "export PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:\$PATH; cd /opt/hermes; HERMES_HOME=$h python3 -c \"from tools.tts_tool_local import _get_piper_voices_dir, _resolve_piper_voice_path as r; d=_get_piper_voices_dir(); print('$h', r('en_US-lessac-medium', d))\""
done
kubectl exec -n hermes-agent deploy/hermes-agent -c hermes-agent -- sh -c 'export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:$PATH"; python3 -c "import piper; print(\"piper import OK\")"'
```

Expected: each home prints a path to a `.onnx` voice file; `piper import OK`. If `_get_piper_voices_dir` or the resolver name has changed in the pinned Hermes version, inspect `/opt/hermes/tools/tts_tool_local.py` (`grep -n "piper" …`) and use the current names. Acceptance (manual): a Discord voice reply from Hermes plays and no request to Microsoft is made (`kubectl logs … | grep -i edge` shows nothing new).

---

## Phase 5 — Retire Ollama and finish

### Task 15: Retire Ollama, update docs, record what was learned

**Files:**
- Delete: `cluster/apps/ai/ollama/` (whole directory)
- Modify: `cluster/apps/ai/hermes-agent/templates/deployment.yaml` (remove the `OLLAMA_BASE_URL` env var)
- Modify: `cluster/apps/ai/hermes-agent/README.md` (add a "Local inference" section)
- Modify: `docs/src/general/network.md` only if it mentions Ollama as a service (check first)
- Create: memory notes in `/home/vscode/.claude/projects/-workspaces-home-ops/memory/`

**Interfaces:**
- Consumes: everything above running for at least 48 h; no consumer of Ollama remains.

- [ ] **Step 1: Prove nothing uses Ollama (read-only)**

```bash
cd /workspaces/home-ops && git checkout main && git pull -q
grep -rn -i "ollama" cluster docs/src charts --include=*.yaml --include=*.tpl --include=*.md | grep -v -E "^cluster/apps/ai/ollama/|/audits/"
kubectl get pods -A -o json | jq -r '.items[].spec.containers[].env[]? | select(.value? != null) | select(.value|test("ollama")) | .name' | sort -u
```

Expected: only `OLLAMA_BASE_URL` in the Hermes deployment (and maybe `docs/src/general/network.md`); the second command lists `OLLAMA_BASE_URL`. Anything else means a consumer still exists: stop and fix it first.

- [ ] **Step 2: Branch and remove**

```bash
git checkout -b chore/retire-ollama
git rm -r cluster/apps/ai/ollama
```

In `cluster/apps/ai/hermes-agent/templates/deployment.yaml` delete:

```yaml
            - name: OLLAMA_BASE_URL
              value: "http://ollama.ollama.svc.cluster.local:11434/v1"
```

- [ ] **Step 3: Document local inference in the Hermes README**

Append to `cluster/apps/ai/hermes-agent/README.md`:

```markdown
## Local inference

The main model, auxiliary tasks, and Honcho's LLM calls run on the local `llama-server` (llm namespace, Gemma 4 26B-A4B on nv1's GPU). OpenRouter and Anthropic are the automatic fallback chain (`fallback_providers`).

- Endpoint: `http://llama-server.llm.svc.cluster.local:8080/v1`, model `gemma-4-26b-a4b`, per-slot context 32768 (`model.context_length` must equal `ctx / parallel` of the server).
- Profiles are not in `values.yaml`; their config lives on the PVC. `hermes.profileOverlays.<name>` is deep-merged into `/opt/data/profiles/<name>/config.yaml` on every pod start (lists are replaced; overlays never remove keys). To roll a profile back to the cloud, remove its overlay **and** run `hermes -p <name> config set model.provider openrouter`.
- Vision still uses Gemini via OpenRouter (the 26B leaves no memory for the projector).
- STT: Speaches (faster-whisper) on the x86 nodes; TTS: Piper in this pod (voices under `cache/piper-voices/`).
- GPU rules and recovery: see `docs/src/k8s/nv1-jetson.md`.
```

- [ ] **Step 4: Verify, commit, open the PR**

```bash
grep -rn -i "ollama" cluster docs/src charts --include=*.yaml --include=*.tpl --include=*.md | grep -v -E "/audits/" || echo "no remaining ollama references"
helm template hermes cluster/apps/ai/hermes-agent >/dev/null && echo "hermes renders"
git add -A cluster docs
git commit -m "chore: retire Ollama (replaced by llama-server in the llm namespace)"
git push -u origin chore/retire-ollama
gh pr create --base main --label area/cluster --title "chore: retire Ollama" \
  --body "All consumers moved: Honcho embeddings -> llm-embeddings, Hermes/Honcho LLM -> llama-server, Hermes OLLAMA_BASE_URL removed. Removing the app directory does NOT auto-prune: the Application and its PVC are handled manually after merge (see the removal procedure)."
```

- [ ] **Step 5: After merge — manual removal (CONFIRM each; the app directory deletion does not prune)**

1. Check what the PVC still holds and that the new PVCs are healthy: `kubectl get pvc -n ollama -n llm`; `kubectl exec -n llm deploy/llama-server -- ls -la /models`.
2. `kubectl delete application ollama -n argocd` (**CONFIRM**). Because `preserveResourcesOnDeletion: false`, this cascades to the app's resources.
3. Keep the `ollama` PVC for one week as a safety net (it holds the gemma4 GGUFs), then delete it (**CONFIRM**): `kubectl delete pvc ollama -n ollama` and `kubectl delete ns ollama`.

- [ ] **Step 6: Final acceptance checklist (read-only)**

```bash
kubectl get pods -n llm                                   # embeddings, llama-server, speaches all Ready
kubectl get node nv1 -o jsonpath='gpu={.status.allocatable.nvidia\.com/gpu}{"\n"}'   # 1
export TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig
talosctl -n 192.168.48.5 dmesg | grep -E "service\[kubelet\]\(Stopping\)" | tail -3   # no restarts in the last 24h
kubectl port-forward -n monitoring svc/prometheus-stack-kube-prom-prometheus 19090:9090 & PF=$!; sleep 3
curl -s --data-urlencode 'query=ALERTS{alertstate="firing",alertname=~"NodeGpuUnavailable|LlamaServer.*|SpeachesUnavailable"}' localhost:19090/api/v1/query | jq '.data.result|length'   # 0
kill $PF
```

Expected: all Ready; `gpu=1`; no kubelet restarts in 24 h (the goal of the prerequisites); zero firing alerts. Then a real interaction on each path: Discord message (main model local), a Signal voice note (STT local), a Hermes voice reply (Piper), and a Honcho memory write (deriver on llama-server).

- [ ] **Step 7: Record what was learned (memory)**

Create `/home/vscode/.claude/projects/-workspaces-home-ops/memory/reference_jetson_llama_cuda_tag.md`:

```markdown
---
name: jetson-llama-cuda-tag
description: nv1 (JetPack 6) can only run CUDA 12.6 GPU images; NVIDIA llama_cpp latest* is CUDA 13 and silently falls back to CPU
metadata:
  type: reference
---

On nv1 (Talos, JetPack 6 / r36.5 driver) only CUDA 12.6 images initialize. `ghcr.io/nvidia-ai-iot/llama_cpp:latest-jetson-orin` (rebuilt 2026-08-12) is CUDA 13.0.1 and logs `ggml_cuda_init: failed to initialize CUDA: CUDA driver version is insufficient` then runs on CPU (~6 tok/s, ~7 cores). Use `b8708-r36.4-tegra-aarch64-cu126-22.04` pinned by digest. The Jetson device plugin advertises exactly one `nvidia.com/gpu` (hard-coded), so only one GPU pod can run at a time. See docs/src/k8s/nv1-jetson.md.
```

Create `/home/vscode/.claude/projects/-workspaces-home-ops/memory/reference_nv1_meta_dhcp.md`:

```markdown
---
name: nv1-meta-dhcp
description: nv1 kubelet restarts every ~15 min were caused by a leftover Talos META 0x0a platform DHCP operator; machine-config dhcp:false does not remove it
metadata:
  type: reference
---

Symptom: nv1 drops to `nvidia.com/gpu: 0`; kubelet restarts repeatedly. Cause: META key `0x0a` had `operators: [dhcp4 enP8p1s0]` (platform layer) -> second IP `192.168.48.210` -> address flaps -> Talos restarts kubelet. Fix: `talosctl -n 192.168.48.5 meta delete 0x0a` (no reboot). Not in git; re-check after any reinstall. Related: [[jetson-llama-cuda-tag]].
```

Then add both one-line pointers to `MEMORY.md` under **Reference**:

```markdown
- [Jetson llama.cpp CUDA tag trap](reference_jetson_llama_cuda_tag.md) — nv1 needs CUDA 12.6 images; latest* is CUDA 13 → silent CPU fallback; single GPU unit
- [nv1 META DHCP kubelet restarts](reference_nv1_meta_dhcp.md) — Talos META 0x0a platform DHCP flapped IP → kubelet restarts → gpu:0; fix via talosctl meta delete
```

---

## Self-Review Notes (plan vs spec)

- **Components 1–6** map to Tasks 6–7 (llama-server), 4–5 (embeddings), 13 (STT), 14 (TTS), 9/11/12 (Hermes), 10 (Honcho).
- **Prerequisites 1–5** map to Tasks 1–3 plus the already-open PRs #5291/#5292 and the completed META delete (documented in Task 3); the 24-hour kubelet-stability gate is Task 7 Step 1 and Task 15 Step 6.
- **Rollout steps 1–6** map to Tasks 4–5, 6–7, 9–10, 11–12, 13–14, 15.
- **Spikes:** S1 (Task 8 Step 7), S2 (Task 8 Step 6), S3 (Task 13 Step 5), S4 (Task 5 Step 2), S5 (Task 8 Step 5 and Task 11 Step 8), S6 (Task 14 Step 1 — piper was found **missing**, so the plan installs it).
- **Spec adjustment made by this plan:** total context is `-c 65536 -np 2` (32768 per slot), not 32768 total, because Hermes agent prompts exceed 16k; Hermes `context_length` is 32768. The spec is updated to match in the same PR.
- **Dialectic `high`/`max` and `DREAM_*` stay on the cloud** (Task 10) — a deliberate scoping decision: they use a 235B model for hard reasoning.
