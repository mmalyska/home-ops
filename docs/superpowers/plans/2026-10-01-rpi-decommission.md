# RPi Decommission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Home Assistant, AdGuard Home (DNS + ad-blocking), MQTT, Zigbee2MQTT, the Matter server and Music Assistant in the cluster so the Raspberry Pi (`192.168.50.9`, HAOS) can be powered off.

**Architecture:** Five phases, one PR each, each leaving the RPi functional until Phase 4. MQTT (existing RabbitMQ app), Z2M, the Matter server and Music Assistant (the last two on Multus macvlan interfaces on VLAN 48, no `hostNetwork`) move first and are each proven against the RPi's still-running HA; then two AdGuard Home instances replace the RPi's AdGuard; then HA itself is restored into the cluster with a fresh Postgres recorder; then the production hostname is cut over. At that point every addon has already been running and tested in the cluster.

**Tech Stack:** ArgoCD ApplicationSets, Helm (bjw-s `app-template` 5.2.1), Kustomize, External Secrets (Bitwarden), Cilium 1.20 (L2 LB, `cni.exclusive`), Multus (thick), CloudNativePG, RabbitMQ cluster-operator, external-dns (AdGuard webhook), Talos.

**Spec:** `docs/superpowers/specs/2026-10-01-rpi-decommission-design.md`

## Global Constraints

- All edits happen in the git worktree `/workspaces/home-ops-ha-migration`, never in `/workspaces/home-ops` (another session uses it). Each phase branches off `origin/main`: `git switch -c <branch> origin/main`.
- Never push to `main`; PRs only. Branch prefixes `feat/`, `fix/`, `chore/`.
- Never commit secrets (gitleaks enforces it). Credentials live in Bitwarden and reach pods through `ExternalSecret` (`ClusterSecretStore` `bitwarden`); mark UUID lines `#gitleaks:allow #KEY_NAME`.
- Never write the private domain literally (comments, docs, memory). Use the `<secret:private-domain>` token in manifests and `<domain>` in prose.
- Hostnames in non-Secret fields need `SECRET_PROVIDER: cluster-secrets` in the app's `app-config.yaml`.
- HTTPRoutes use annotation `external-dns.alpha.kubernetes.io/controller: dns-controller`; DNSEndpoints use `internal`.
- Cilium LB pool is `192.168.48.20–50`. Allocations in this plan: `.24` AdGuard primary, `.25` AdGuard replica, `.26` MQTT. Macvlan pod block `192.168.48.60–.69` (outside the pool): `.60` Home Assistant, `.61` Matter server, `.62` Music Assistant.
- **Never mutate cluster state** (`kubectl apply/delete/patch/cp/scale`, ArgoCD sync, `talosctl apply`) without explicit user confirmation. Steps marked **[CONFIRM]** stop and ask. Read-only `kubectl get/logs/describe` and `talosctl ls/read` are free.
- Talos nodes `mc1`–`mc3` NIC is `eth0`; `nv1` (worker) is `enP8p1s0`. HA and Matter are pinned to control-plane nodes via `nodeSelector: node-role.kubernetes.io/control-plane: ""`.
- Never edit generated files in `provision/talos/clusterconfig/`; regenerate with `task talos:generate`.
- Verification before every commit: `helm dependency build && helm template <release> . -f values.yaml` (Helm apps), `kubectl kustomize .` (Kustomize apps), then `task lint:all` from the worktree root.
- Update docs (`docs/src/general/network.md`, `hardware.md`, `matter-thread.md`) and `.claude/memory/` files with each phase's durable facts.
- Steps marked **[USER]** need an action only the user can do (RPi, UniFi UI, Bitwarden). Stop and hand the exact instruction to the user; do not work around them.

## Review Focus

1. **Pod on net1 cannot reach an LB IP announced by its own node** (macvlan host isolation). In-cluster consumers of MQTT/AdGuard must use `*.svc.cluster.local`, never the LB IPs or `mqtt.<domain>`. Tasks 3.1 and 3.2 check HA's config for LB-IP/`mqtt.<domain>` references.
2. **HA behind Envoy returns 400** unless `http.use_x_forwarded_for: true` and `trusted_proxies` include the pod CIDR (`10.244.0.0/16`); the restored HAOS config trusts the old proxy only. Task 3.2 adds the check.
3. **Two Z2M, two Matter servers (same storage) or two HA instances active at once.** The SLZB socket takes one client; two controllers on one Matter fabric/storage conflict; two HAs double-fire automations. Tasks 1.3, 1.7 and 4.1 gate on the old instance being stopped first.
4. **AdGuard replica drift / stale rewrites** — `adguardhome-sync` is one-way (primary → replica); external-dns must write only to the primary, and imported manual rewrites that duplicate `DNSEndpoint`s would be deleted by `policy: sync`. Task 2.3 compares rewrites before and after.
5. **Matter fabric data missing** — Matter devices would need recommissioning. Task 1.7 checks that the backup contains the fabric files before the RPi addon is retired, and never runs two Matter servers on the same storage.
6. **Cluster DNS loop** — Talos nodes must not resolve through the in-cluster AdGuard. Task 2.1 lands first and is verified on every node.
7. **IPv6 on `net1`** — the Thread OMR route must work from `net1`. Task 1.6 verifies SLAAC, default route and reachability, with a `tuning` fallback.
8. **Music Assistant hands players the wrong stream address, or the player VLAN cannot reach `192.168.48.62`** — Task 1.8 sets the published IP, checks reachability from the player VLAN on all ports and tests real playback; SSDP-only players (DLNA, Sonos S1) are an expected gap.

---

# PHASE 0 — MQTT broker

Branch: `feat/mqtt-enable-rabbitmq`

### Task 0.1: Enable RabbitMQ MQTT with Z2M user, LB service and hostname

**Files:**
- Modify: `charts/rabbitmq-cluster/templates/rabbitmqcluster.yaml`
- Modify: `charts/rabbitmq-cluster/values.yaml`
- Modify: `cluster/apps/home-automation/rabbitmq/values.yaml`
- Modify: `cluster/apps/home-automation/rabbitmq/app-config.yaml`
- Modify: `cluster/apps/home-automation/rabbitmq/templates/external-secret.yaml`
- Create: `cluster/apps/home-automation/rabbitmq/templates/dnsendpoint.yaml`

**Interfaces:**
- Produces: MQTT at `home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local:1883` (ClusterIP, in-cluster) and `192.168.48.26:1883` / `mqtt.<domain>` (LAN); users `admin`, `home_assistant`, `zigbee2mqtt`.

- [ ] **Step 1: [USER] Create Bitwarden secrets**

Ask the user to create two Bitwarden Secrets Manager entries, `RABBITMQ_ZIGBEE2MQTT_USERNAME` and `RABBITMQ_ZIGBEE2MQTT_PASSWORD` (a long random password), and reply with both UUIDs. Do not continue until the UUIDs are provided; they replace `<UUID_Z2M_USERNAME>` and `<UUID_Z2M_PASSWORD>` below.

- [ ] **Step 2: Create the branch**

```bash
cd /workspaces/home-ops-ha-migration
git fetch origin main && git switch -c feat/mqtt-enable-rabbitmq origin/main
```

- [ ] **Step 3: Add `service` passthrough to the chart**

In `charts/rabbitmq-cluster/templates/rabbitmqcluster.yaml`, directly after the `persistence:` block (before `{{- with .Values.resources }}`), add:

```yaml
  {{- with .Values.service }}
  service:
    {{- toYaml . | nindent 4 }}
  {{- end }}
```

In `charts/rabbitmq-cluster/values.yaml` add after `image: ""`:

```yaml
service: {}
```

- [ ] **Step 4: Set service, enable the app, add the plugin env**

In `cluster/apps/home-automation/rabbitmq/values.yaml`, under `rabbitmq-cluster:` add (same level as `name:`):

```yaml
  service:
    type: LoadBalancer
    annotations:
      lbipam.cilium.io/ips: "192.168.48.26"
```

Replace `cluster/apps/home-automation/rabbitmq/app-config.yaml` with:

```yaml
- enabled: "true"
  namespace: ha-rabbitmq
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Step 5: Add the `zigbee2mqtt` user to the definitions**

In `templates/external-secret.yaml`, in `definitions.json` add a third user and permission, mirroring the existing `home_assistant` lines exactly (same password field style):

```
              {"name": "{{ `{{ .zigbee2mqtt_username }}` }}", "password": "{{ `{{ .zigbee2mqtt_password }}` }}", "tags": ""}
```
```
              {"user": "{{ `{{ .zigbee2mqtt_username }}` }}", "vhost": "/", "configure": ".*", "write": ".*", "read": ".*"}
```

Open the file first and copy the exact existing user-line shape (including the field that holds the password) so the new line matches; add commas as needed. Append to `spec.data`:

```yaml
    - secretKey: zigbee2mqtt_username
      remoteRef:
        key: "<UUID_Z2M_USERNAME>" #gitleaks:allow #RABBITMQ_ZIGBEE2MQTT_USERNAME
    - secretKey: zigbee2mqtt_password
      remoteRef:
        key: "<UUID_Z2M_PASSWORD>" #gitleaks:allow #RABBITMQ_ZIGBEE2MQTT_PASSWORD
```

- [ ] **Step 6: Publish `mqtt.<domain>`**

Create `cluster/apps/home-automation/rabbitmq/templates/dnsendpoint.yaml`:

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: mqtt-endpoint
  annotations:
    external-dns.alpha.kubernetes.io/controller: internal
spec:
  endpoints:
    - dnsName: mqtt.<secret:private-domain>
      recordType: A
      targets:
        - 192.168.48.26
```

- [ ] **Step 7: Verify the render**

```bash
cd cluster/apps/home-automation/rabbitmq
helm dependency build && helm template rabbitmq . -f values.yaml > /tmp/rmq.yaml
grep -n -A3 "kind: RabbitmqCluster" /tmp/rmq.yaml | head
grep -n -B1 -A3 "type: LoadBalancer" /tmp/rmq.yaml
grep -n "192.168.48.26" /tmp/rmq.yaml
grep -c "zigbee2mqtt_username" /tmp/rmq.yaml
```

Expected: `type: LoadBalancer` and the `lbipam.cilium.io/ips` annotation appear under the RabbitmqCluster `service:`; `192.168.48.26` appears in both the annotation and the DNSEndpoint; the zigbee2mqtt token appears (≥2).

Use the scratchpad dir instead of `/tmp` if the harness requires it.

- [ ] **Step 8: Lint and commit**

```bash
cd /workspaces/home-ops-ha-migration && task lint:all
git add charts/rabbitmq-cluster cluster/apps/home-automation/rabbitmq
git commit -m "feat(rabbitmq): enable MQTT broker with LB IP, DNS name and zigbee2mqtt user"
git push -u origin feat/mqtt-enable-rabbitmq
gh pr create --base main --title "feat(rabbitmq): enable MQTT broker for HA stack migration" --body "Phase 0 of docs/superpowers/plans/2026-10-01-rpi-decommission.md"
```

### Task 0.2: Verify the broker from the RPi **[CONFIRM before ArgoCD sync, then USER]**

- [ ] **Step 1: [CONFIRM]** After the PR merges, ask the user to confirm the ArgoCD sync of `ha-rabbitmq` (auto-sync policy applies; confirm they accept it going live).
- [ ] **Step 2: Read-only cluster check**

```bash
kubectl -n ha-rabbitmq get rabbitmqcluster,pods,svc
kubectl -n ha-rabbitmq get svc -o wide | grep 1883
```

Expected: cluster `ALLREPLICASREADY=True`, a `LoadBalancer` service with EXTERNAL-IP `192.168.48.26` exposing 1883.

- [ ] **Step 3: [USER] Connectivity test from the RPi**

Ask the user to run from the RPi's Terminal addon (use the `home_assistant` credentials from Bitwarden, not pasted here):

```bash
mosquitto_sub -h mqtt.<domain> -p 1883 -u <user> -P '<password>' -t 'test/#' -v &
mosquitto_pub -h mqtt.<domain> -p 1883 -u <user> -P '<password>' -t test/ping -m hello
```

Expected: the subscriber prints `test/ping hello`. Failure: check the firewall rule VLAN 50 → `192.168.48.26:1883` (VLANs 48/50 are one allow-all zone, so a failure points at DNS: `dig mqtt.<domain>` from the RPi).

- [ ] **Step 4:** If any device hardcodes the RPi's Mosquitto IP, ask the user to list them so Phase 1 repoints them to `mqtt.<domain>`.

---

# PHASE 1 — Zigbee2MQTT, Matter server and Music Assistant (proven against the RPi's HA)

Branch: `feat/zigbee2mqtt`

### Task 1.1: Zigbee2MQTT app (scaled to 0)

**Files:**
- Create: `cluster/apps/home-automation/zigbee2mqtt/app-config.yaml`
- Create: `cluster/apps/home-automation/zigbee2mqtt/Chart.yaml`
- Create: `cluster/apps/home-automation/zigbee2mqtt/values.yaml`
- Create: `cluster/apps/home-automation/zigbee2mqtt/templates/externalsecret.yaml`

**Interfaces:**
- Consumes: broker `home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local:1883` and the `zigbee2mqtt` user from Task 0.1.
- Produces: namespace `ha-zigbee2mqtt`, PVC mounted at `/app/data`, frontend `z2m.<domain>`.

- [ ] **Step 1: Branch and pin the image**

```bash
cd /workspaces/home-ops-ha-migration && git fetch origin main && git switch -c feat/zigbee2mqtt origin/main
docker buildx imagetools inspect koenkk/zigbee2mqtt:<TAG> | head -3
```

`<TAG>` = the Z2M version that the RPi addon runs now (**[USER]** supplies it; same major). Record `tag@sha256:digest` for `values.yaml`.

- [ ] **Step 2: Create `app-config.yaml`**

```yaml
- enabled: "true"
  namespace: ha-zigbee2mqtt
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Step 3: Create `Chart.yaml`**

```yaml
---
apiVersion: v2
name: zigbee2mqtt
type: application
version: 1.0.0
appVersion: "1.0.0"
dependencies:
  - name: app-template
    version: 5.2.1
    repository: https://bjw-s-labs.github.io/helm-charts
```

- [ ] **Step 4: Create `values.yaml`**

```yaml
app-template:
  defaultPodOptions:
    securityContext:
      runAsUser: 568
      runAsGroup: 568
      fsGroup: 568
      fsGroupChangePolicy: "OnRootMismatch"
  controllers:
    main:
      replicas: 0 # data restore first (Task 1.2); flipped to 1 in Task 1.3
      strategy: Recreate
      containers:
        main:
          image:
            repository: koenkk/zigbee2mqtt
            tag: <TAG>@sha256:<DIGEST>
          envFrom:
            - secretRef:
                name: zigbee2mqtt-secret
          env:
            TZ: Europe/Warsaw
          resources:
            requests:
              cpu: 20m
              memory: 128Mi
            limits:
              memory: 512Mi
  service:
    main:
      controller: main
      ports:
        http:
          port: 8080
  route:
    main:
      annotations:
        external-dns.alpha.kubernetes.io/controller: dns-controller
      parentRefs:
        - name: envoy-internal
          namespace: envoy-gateway
          sectionName: https
      hostnames:
        - z2m.<secret:private-domain>
      rules:
        - backendRefs:
            - identifier: main
  persistence:
    data:
      type: persistentVolumeClaim
      accessMode: ReadWriteOnce
      size: 1Gi
      globalMounts:
        - path: /app/data
```

Replace `<TAG>`/`<DIGEST>` with the values from Step 1 (timezone `Europe/Warsaw` is user-confirmed).

- [ ] **Step 5: Create `templates/externalsecret.yaml`**

Z2M reads `ZIGBEE2MQTT_CONFIG_*` env vars over the YAML; the network key stays in the restored `configuration.yaml` (never in git).

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: zigbee2mqtt-secret
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: zigbee2mqtt-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        ZIGBEE2MQTT_CONFIG_MQTT_SERVER: "mqtt://home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local:1883"
        ZIGBEE2MQTT_CONFIG_MQTT_USER: "{{ `{{ .USERNAME }}` }}"
        ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD: "{{ `{{ .PASSWORD }}` }}"
  data:
    - secretKey: USERNAME
      remoteRef:
        key: "<UUID_Z2M_USERNAME>" #gitleaks:allow #RABBITMQ_ZIGBEE2MQTT_USERNAME
    - secretKey: PASSWORD
      remoteRef:
        key: "<UUID_Z2M_PASSWORD>" #gitleaks:allow #RABBITMQ_ZIGBEE2MQTT_PASSWORD
```

Use the UUIDs from Task 0.1 Step 1.

- [ ] **Step 6: Verify render, lint, commit, PR**

```bash
cd cluster/apps/home-automation/zigbee2mqtt
helm dependency build && helm template zigbee2mqtt . -f values.yaml | grep -n -E "kind: (StatefulSet|Deployment)|replicas: 0|port: 8080|z2m\.|/app/data|zigbee2mqtt-secret"
cd /workspaces/home-ops-ha-migration && task lint:all
git add cluster/apps/home-automation/zigbee2mqtt
git commit -m "feat(zigbee2mqtt): add standalone Zigbee2MQTT app (scaled to 0 pending data restore)"
git push -u origin feat/zigbee2mqtt
gh pr create --base main --title "feat(zigbee2mqtt): standalone Zigbee2MQTT in cluster" --body "Phase 1 of docs/superpowers/plans/2026-10-01-rpi-decommission.md. Starts scaled to 0."
```

Expected: a Deployment with `replicas: 0`, port 8080, the `z2m.` host, the `/app/data` mount and both env `secretRef`s appear.

### Task 1.2: Restore the RPi Z2M data into the PVC **[USER + CONFIRM]**

- [ ] **Step 1: [USER] Export from the RPi**

Ask the user to copy the Z2M addon data directory (`/config/zigbee2mqtt/` on HAOS, via the Samba/SSH addon) containing `configuration.yaml`, `database.db`, `coordinator_backup.json`, `state.json` to a local folder, and to **edit `configuration.yaml`** in that copy:

```yaml
serial:
  port: tcp://<slzb-ip>:6638   # confirm the port in the SLZB web UI (Z2M socket)
  adapter: ember               # keep whatever the existing config uses (ember or zstack)
```

and remove the `mqtt:` `user`/`password`/`server` keys (they come from env). Do **not** paste this file into the chat or repo.

- [ ] **Step 2: [CONFIRM] Merge the PR and let ArgoCD create the app (replicas 0)**

```bash
kubectl -n ha-zigbee2mqtt get pvc,deploy
```

Expected: PVC `Bound`, Deployment `0/0`.

- [ ] **Step 3: [CONFIRM] Copy data with a helper pod**

```bash
kubectl -n ha-zigbee2mqtt run z2m-restore --image=busybox:1.37 --restart=Never --overrides='{"spec":{"securityContext":{"runAsUser":568,"runAsGroup":568,"fsGroup":568},"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"zigbee2mqtt-data"}}],"containers":[{"name":"z2m-restore","image":"busybox:1.37","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/app/data"}]}]}}'
kubectl -n ha-zigbee2mqtt wait --for=condition=Ready pod/z2m-restore
kubectl -n ha-zigbee2mqtt cp <local-folder>/. z2m-restore:/app/data/
kubectl -n ha-zigbee2mqtt exec z2m-restore -- ls -la /app/data
kubectl -n ha-zigbee2mqtt delete pod z2m-restore
```

The PVC name is `kubectl -n ha-zigbee2mqtt get pvc` output (adjust `claimName`). Expected: the four files are listed, owned by 568.

### Task 1.3: Cut over Z2M **[CONFIRM + USER]**

**Files:**
- Modify: `cluster/apps/home-automation/zigbee2mqtt/values.yaml` (`replicas: 1`)

- [ ] **Step 1: [USER] Stop the RPi's Z2M and Mosquitto addons**

The SLZB socket takes one client. Ask the user to stop the **Zigbee2MQTT** addon (and disable "start on boot"), then the **Mosquitto** addon, on the RPi.

- [ ] **Step 2: [USER] Repoint the RPi HA MQTT integration**

Settings → Devices & services → MQTT → Configure: broker `mqtt.<domain>`, port 1883, the `home_assistant` user/password.

- [ ] **Step 3: Flip replicas, commit, PR**

```bash
git switch -c fix/zigbee2mqtt-start origin/main
sed -i 's/replicas: 0 # data restore first.*/replicas: 1/' cluster/apps/home-automation/zigbee2mqtt/values.yaml
(cd cluster/apps/home-automation/zigbee2mqtt && helm dependency build && helm template z . -f values.yaml | grep -n "replicas: 1")
git add -A && git commit -m "feat(zigbee2mqtt): start Zigbee2MQTT" && git push -u origin fix/zigbee2mqtt-start
gh pr create --base main --title "feat(zigbee2mqtt): start Zigbee2MQTT" --body "Phase 1 cutover; RPi Z2M/Mosquitto stopped first."
```

- [ ] **Step 4: Verify**

```bash
kubectl -n ha-zigbee2mqtt logs deploy/zigbee2mqtt --tail=50
```

Expected: `Connected to MQTT server`, the coordinator connection to `tcp://<slzb-ip>:6638` succeeds, and the device list loads without "re-pair" prompts.

- [ ] **Step 5: [USER] Functional acceptance**

All Zigbee devices appear in the RPi's HA; toggling a light/switch from HA changes its state and the state returns to HA; `kubectl -n ha-zigbee2mqtt delete pod -l app.kubernetes.io/name=zigbee2mqtt` (**[CONFIRM]**) restarts and devices return within a minute. Open `https://z2m.<domain>` and confirm the frontend loads.

- [ ] **Step 6: Docs and memory**

Add to `docs/src/general/network.md` the `.26` MQTT row and a "Zigbee2MQTT / MQTT" bullet; add a `.claude/memory/` note (or update `reference_home_network_hardware.md`) saying MQTT/Z2M moved in-cluster on `<date>`. Commit on the same branch.


### Task 1.4: Cilium `cni.exclusive: false`

Branch: `feat/multus-prereq-cilium`

**Files:**
- Modify: `cluster/apps/core/cilium/values.yaml`

- [ ] **Step 1: Edit**

Under `cilium:` add (keep the existing keys):

```yaml
  cni:
    exclusive: false
```

- [ ] **Step 2: Verify render**

```bash
cd cluster/apps/core/cilium && helm dependency build && helm template cilium . -f values.yaml | grep -n -i "cni-exclusive"
```

Expected: `cni-exclusive: "false"` in the `cilium-config` ConfigMap.

- [ ] **Step 3: Lint, commit, PR**, `git commit -m "feat(cilium): allow chained CNI configs (cni.exclusive=false) for Multus"`.

- [ ] **Step 4: [CONFIRM] Sync and verify**

Sync of a Cilium config change restarts agents. Ask for the user's go-ahead, then:

```bash
kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | head -15
TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig talosctl -n 192.168.48.2 ls /etc/cni/net.d
```

Expected: agents Ready, `Cluster health` OK, `05-cilium.conflist` still present, no workload disruption.

### Task 1.5: Multus app

Branch: `feat/multus`

**Files:**
- Create: `cluster/apps/system/multus/kustomization.yaml`
- Create: `cluster/apps/system/multus/app-config.yaml`

- [ ] **Step 1: Check CNI plugins on Talos (read-only)**

```bash
TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig talosctl -n 192.168.48.2 ls /opt/cni/bin
```

Expected: `macvlan` and `static` among the binaries. **If either is missing**, add a `cni-plugins` installer DaemonSet (the upstream `containernetworking/plugins` release archive copied to `/opt/cni/bin` via an init container) as an extra manifest in `cluster/apps/system/multus/` and re-check before continuing.

- [ ] **Step 2: Pick the release**

```bash
gh release list -R k8snetworkplumbingwg/multus-cni -L 5
```

Use the latest stable `vX.Y.Z` for the thick DaemonSet.

- [ ] **Step 3: `kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
metadata:
  name: multus

resources:
  # renovate-raw: datasource=github-releases depName=k8snetworkplumbingwg/multus-cni
  - https://github.com/k8snetworkplumbingwg/multus-cni/releases/download/vX.Y.Z/multus-daemonset-thick.yml
```

Replace `vX.Y.Z` with the release from Step 2. Confirm the manifest's asset URL exists: `curl -fsI <url> | head -1` (expect `HTTP/2 302`/`200`).

- [ ] **Step 4: `app-config.yaml`**

```yaml
- enabled: "true"
  namespace: kube-system
  syncWave: "-4"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
```

- [ ] **Step 4b: Apply the Talos guide's Multus requirements** (docs.siderolabs.com → Kubernetes guides → CNI → Multus; read on 2026-10-02, Talos < v1.14 branch):
  - Raise the Multus daemon limits (upstream's 50Mi can OOM-kill the primary CNI plugin) to requests 200m/100Mi, limits 300m/150Mi: done as a kustomize patch.
  - Check `talosctl --nodes <ip> list -l /var` shows `run -> /run`; if it does not, patch the `host-run-netns` hostPath to `/var/run/netns/`. Verified on mc1 and nv1: `run -> /run`, no patch needed.
  - Cilium needs `cni.exclusive=false` or it silently renames `00-multus.conf` to `00-multus.conf.cilium_bak`: live since Task 1.4; after Multus starts, confirm `00-multus.conf` (not a `.cilium_bak`) exists in `/etc/cni/net.d`.
  - The guide's NAD `dataDir: /run/cni` applies to IPAM plugins that keep leases (host-local, whereabouts). Our NADs use `static` IPAM, which keeps no state, so it is not needed; add it if the IPAM type ever changes.
  - The guide's primary example bridges the NIC in Talos machine config (`br0`, `bridge` CNI plugin). We deliberately use macvlan on `eth0` (no node network changes, avoids touching the VIP/node IPs), which is why Task 1.5 also installs `macvlan` and `static`.

- [ ] **Step 5: Render and inspect Talos-relevant paths**

```bash
kubectl kustomize cluster/apps/system/multus | grep -n -E "hostPath|path: /(etc/cni|opt/cni|var/run)|kind: (DaemonSet|CustomResourceDefinition)"
```

Expected: host paths `/etc/cni/net.d` and `/opt/cni/bin` for CNI config/binaries, and the `NetworkAttachmentDefinition` CRD. If the manifest uses other host paths, add a kustomize patch pointing them at the Talos paths.

- [ ] **Step 6: Lint, commit, PR**; **[CONFIRM]** sync; verify:

```bash
kubectl -n kube-system get ds -l app=multus
kubectl get crd network-attachment-definitions.k8s.cni.cncf.io
TALOSCONFIG=... talosctl -n 192.168.48.2 ls /etc/cni/net.d
```

Expected: DaemonSet ready on all nodes; the CRD exists; `00-multus.conf` appears alongside `05-cilium.conflist`; existing pods are unaffected (`kubectl get pods -A | grep -v Running | grep -v Completed` shows nothing new).

### Task 1.6: Matter server app (matter.js) with macvlan interface

**Server choice (researched 2026-10-02):** `python-matter-server` is archived (8.1.2 was the last release). The RPi's Matter Server addon (9.2.0) runs the **matter.js** server (`ghcr.io/matter-js/matterjs-server:1.4.0`, bundled by the addon), and its Python data was migrated to the new format automatically at addon 9.0.0. The server is documented as a drop-in replacement: same `/data` directory and WebSocket API; it runs unprivileged as UID 1000 (so the volume needs `fsGroup: 1000`) and needs roughly twice the Python server's RAM. Pin the same server version as the addon (1.4.0) so the restored data is read by the version that wrote it.

Sources: `home-assistant/addons` `matter_server/` (config.yaml, build.yaml, run script, CHANGELOG) and `matter-js/matterjs-server` `docs/docker.md`, `docs/os_requirements.md`.

Branch: `feat/matter-server`

**Files:**
- Create: `cluster/apps/home-automation/matter-server/app-config.yaml`
- Create: `cluster/apps/home-automation/matter-server/Chart.yaml`
- Create: `cluster/apps/home-automation/matter-server/values.yaml`
- Create: `cluster/apps/home-automation/matter-server/templates/nad.yaml`

**Interfaces:**
- Produces: namespace `ha-matter-server`, websocket `ws://matter-server.ha-matter-server.svc.cluster.local:5580/ws`, `net1` at `192.168.48.61/24`, PVC at `/data`.

- [ ] **Step 1: `app-config.yaml`** — as in Task 1.1 Step 2 with `namespace: ha-matter-server`, plus `enabled: "true"`. **`Chart.yaml`** as in Task 1.1 Step 3 with `name: matter-server`.

- [ ] **Step 2: `templates/nad.yaml`**

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan48
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "capabilities": { "ips": true },
      "ipam": {
        "type": "static",
        "routes": [
          { "dst": "192.168.0.0/16", "gw": "192.168.48.254" }
        ]
      }
    }
```

The route sends LAN-bound replies out `net1` so traffic from other VLANs is not asymmetric; the pod's default route and cluster traffic stay on Cilium `eth0`.

- [ ] **Step 3: `values.yaml`**

```yaml
app-template:
  defaultPodOptions:
    securityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      fsGroupChangePolicy: "OnRootMismatch"
    nodeSelector:
      node-role.kubernetes.io/control-plane: ""
  controllers:
    main:
      strategy: Recreate
      replicas: 0 # data restore first (Task 1.7); flipped to 1 there
      pod:
        annotations:
          k8s.v1.cni.cncf.io/networks: '[{"name":"vlan48","ips":["192.168.48.61/24"]}]'
      containers:
        main:
          image:
            repository: ghcr.io/matter-js/matterjs-server
            tag: 1.4.0@sha256:54232d0d3e7dff5a54759469d2753399270412b4c30c55b31750a4595e4cb236
          args:
            - --storage-path
            - /data
            - --primary-interface
            - net1
            - --fabricid
            - "2"
            - --vendorid
            - "4939"
            - --enable-time-sync
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
  service:
    main:
      controller: main
      ports:
        ws:
          port: 5580
  persistence:
    data:
      type: persistentVolumeClaim
      accessMode: ReadWriteOnce
      size: 1Gi
      globalMounts:
        - path: /data
```

**`--fabricid 2 --vendorid 4939` are mandatory** (found on the first start, 2026-10-02): the addon's run script passes them, and together they select the stored fabric `server-2-134b`. Without them the server defaults to fabric 1 / vendor `0xfff1`, logs `Using new server ID format: server-1-fff1` and `Found 0 nodes`, and silently creates a new empty fabric next to the restored data. `--enable-time-sync` mirrors the addon's default (`time_sync: auto`, on when the host clock is NTP-synchronized; the nodes are). The WebSocket on `net1` is unauthenticated and reachable from the LAN; it is needed on `net1` only while the RPi's HA is the client, and Task 4.2 restricts the listen address to the pod's cluster IP afterwards.

- [ ] **Step 4: Verify, lint, commit, PR**

```bash
cd cluster/apps/home-automation/matter-server && helm dependency build && helm template matter . -f values.yaml | grep -n -E "NetworkAttachmentDefinition|k8s.v1.cni|primary-interface|replicas: 0|5580|matterjs-server|fsGroup"
helm template matter . -f values.yaml | grep -n -A3 "^kind: Service"
cd /workspaces/home-ops-ha-migration && task lint:all
git add cluster/apps/home-automation/matter-server
git commit -m "feat(matter-server): add matter.js Matter server on VLAN 48 macvlan (scaled to 0)"
```

- [ ] **Step 5: [CONFIRM] Verify `net1` with a throwaway pod before depending on it**

After the PR merges and Multus is running, ask the user to approve a temporary test pod that mirrors the annotation (a different IP, `192.168.48.69`):

```bash
kubectl -n ha-matter-server run net-test --image=nicolaka/netshoot --restart=Never --overrides='{"metadata":{"annotations":{"k8s.v1.cni.cncf.io/networks":"[{\"name\":\"vlan48\",\"ips\":[\"192.168.48.69/24\"]}]"}},"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},"containers":[{"name":"net-test","image":"nicolaka/netshoot","command":["sleep","900"]}]}}'
kubectl -n ha-matter-server exec net-test -- ip -4 addr show net1
kubectl -n ha-matter-server exec net-test -- ip -6 addr show net1
kubectl -n ha-matter-server exec net-test -- ip -6 route
kubectl -n ha-matter-server exec net-test -- ping -c2 192.168.50.8
kubectl -n ha-matter-server exec net-test -- ping -c2 -I net1 192.168.48.254
kubectl -n ha-matter-server exec net-test -- ping -6 -c2 <OMR-address-of-a-Thread-device-or-SLZB>
kubectl -n ha-matter-server exec net-test -- avahi-browse -a -t 2>/dev/null | head || true
kubectl -n ha-matter-server exec net-test -- sysctl net.ipv6.conf.all.forwarding net.ipv6.conf.net1.accept_ra net.ipv6.conf.net1.accept_ra_rt_info_max_plen
kubectl -n ha-matter-server delete pod net-test
```

Matter-specific gate (from `os_requirements.md`): IPv6 forwarding must be **0** in the pod (otherwise no reachability probing); `accept_ra` must be at least 1 on `net1` so the pod gets its default route/SLAAC address. Route Information Options (`accept_ra_rt_info_max_plen=64`) are not required here because the route to the Thread OMR prefix comes from the UniFi static route, but record the values. The same document warns that mDNS forwarders (UniFi's mDNS option) "tend to corrupt or severely hinder the Matter packets" and that Matter's link-local multicast does not cross VLANs. Our server (VLAN 48) and border router (VLAN 50) are on different VLANs and rely on that reflector, which already worked for phone commissioning on 2026-09-29; so the real test is Task 1.7 Step 8 (Thread devices operate and recover after a pod restart). If Thread devices flap or are unreachable there, the fallback is a tagged VLAN 50 interface for the Matter pod (own task, user decision) or reverting to the RPi addon (Step 9).

Expected: `net1` has `192.168.48.69/24`, a SLAAC IPv6 address and an IPv6 default route via the UCG-Max; the QNAP ping works; the Thread (OMR) address replies through the UniFi static route; mDNS responses from Chromecasts are visible. If IPv6 SLAAC is missing, add a `tuning` plugin chain to the NAD setting `net.ipv6.conf.net1.accept_ra=2` and re-test. Remember Review Focus 1: do not test against an LB IP.

### Task 1.7: Cut over the Matter server **[USER + CONFIRM]**

Branch: `fix/matter-server-start`

**Files:**
- Modify: `cluster/apps/home-automation/matter-server/values.yaml` (`replicas: 1`)

**Interfaces:**
- Consumes: Task 1.6 app (PVC, `net1` at `192.168.48.61`), Task 1.5 Multus.
- Produces: a live Matter server owning the fabric, reachable by the RPi's HA at `ws://192.168.48.61:5580/ws` (the pod's `net1` address is routable from VLAN 50; the ClusterIP is not) and, after Phase 4, by the cluster HA at `ws://matter-server.ha-matter-server.svc.cluster.local:5580/ws`.

The Thread network and the SLZB address are **not** changing during this migration (user-confirmed), so the existing UniFi OMR static route and firewall allow stay as they are. Only if a failed migration forces the Thread network to be re-created does the OMR prefix change; then follow the runbook in `docs/src/general/matter-thread.md` to update the route first. Never run two Matter servers on the same storage/fabric. The RPi addon is stopped before the cluster server starts, and the RPi's data stays on the RPi as the rollback.

- [ ] **Step 1: [USER] Stop the RPi's Matter Server addon**

Settings → Add-ons → Matter Server → Stop, and disable "Start on boot". The RPi HA's Matter entities go unavailable (expected). Do not uninstall the addon.

- [ ] **Step 2: [USER] Back up the add-on's data**

Create a partial backup containing only **Matter Server** (and the HA config for reference), download the `.tar`. Never commit it.

- [ ] **Step 3: Extract and check the fabric data (local)**

```bash
mkdir -p /tmp/haos && cd /tmp/haos && tar xf <backup>.tar && ls
mkdir -p matter && tar xzf addon_*matter_server*.tar.gz -C matter
find matter -maxdepth 3 -type f | head -30
```

Adjust the archive name to what `ls` shows. Expected: a non-empty `data/` with the matter.js server's storage files (already in the matter.js format since addon 9.0.0, so no migration runs). A leftover `data/.migrations/` directory (backup of the old Python data) may exist: do not copy it. If they are missing, **stop**: restart the RPi addon (rollback) and tell the user that the backup did not include add-on data; without it every Matter device must be recommissioned.

- [ ] **Step 4: [CONFIRM] Copy the data into the Matter PVC (Deployment still at 0 replicas)**

```bash
kubectl -n ha-matter-server get pvc,deploy
rm -rf /tmp/haos/matter/data/.migrations
kubectl -n ha-matter-server run matter-restore --image=busybox:1.37 --restart=Never --overrides='{"spec":{"securityContext":{"runAsUser":1000,"runAsGroup":1000,"fsGroup":1000},"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"matter-server-data"}}],"containers":[{"name":"matter-restore","image":"busybox:1.37","command":["sleep","900"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl -n ha-matter-server wait --for=condition=Ready pod/matter-restore
kubectl -n ha-matter-server cp /tmp/haos/matter/data/. matter-restore:/data/
kubectl -n ha-matter-server exec matter-restore -- ls -la /data
kubectl -n ha-matter-server delete pod matter-restore
```

Adjust `claimName` to the real PVC name from the first command and the source folder to where Step 3 found the files. Expected: the fabric files are listed in `/data`.

- [ ] **Step 5: Flip replicas, commit, PR**

```bash
cd /workspaces/home-ops-ha-migration && git fetch origin main && git switch -c fix/matter-server-start origin/main
sed -i 's/replicas: 0 # data restore first.*/replicas: 1/' cluster/apps/home-automation/matter-server/values.yaml
(cd cluster/apps/home-automation/matter-server && helm dependency build && helm template m . -f values.yaml | grep -n "replicas: 1")
git add -A && git commit -m "feat(matter-server): start Matter server" && git push -u origin fix/matter-server-start
gh pr create --base main --title "feat(matter-server): start Matter server" --body "Phase 1 cutover; RPi Matter addon stopped first."
```

- [ ] **Step 6: Verify the server (read-only)**

First read the start-up log for the store it opened: it must be `server-2-134b` and the controller must list the restored nodes (here 3 Thread nodes plus any Wi-Fi ones; `nextNodeId` was 9). `server-1-fff1` or `Found 0 nodes` means the fabric/vendor args are wrong: stop and fix the args before anything else (nothing may connect to the wrong store).


```bash
kubectl -n ha-matter-server logs deploy/matter-server --tail=60
kubectl -n ha-matter-server exec deploy/matter-server -- ip -4 addr show net1
```

Expected: the server starts on `net1`, loads the existing fabric and nodes (no "new fabric created"/empty-storage message), and `net1` is `192.168.48.61/24`. If the log shows a freshly created fabric, **stop**: scale to 0, clear `/data`, and re-do Step 4.

- [ ] **Step 7: [USER] Repoint the RPi HA's Matter integration**

Settings → Devices & services → Matter → Configure (or remove-and-re-add the config entry **only if** the UI offers no URL field; removing the entry does not remove devices from the fabric): uncheck "Use the official Matter Server Supervisor add-on" and set the URL to `ws://192.168.48.61:5580/ws`.

- [ ] **Step 8: [USER] Acceptance with the RPi's HA**

All Matter nodes show as available; toggle a Matter-over-Thread device and a Wi-Fi Matter device; read a sensor value. **[CONFIRM]** restart the pod (`kubectl -n ha-matter-server delete pod -l app.kubernetes.io/name=matter-server`) and verify the nodes come back within a couple of minutes. Check the cluster log for IPv6/Thread errors (`kubectl -n ha-matter-server logs deploy/matter-server | grep -i -E "error|timeout|unreachable"`); an empty result is expected.

- [ ] **Step 9: Rollback path**

Scale the cluster server to 0 (revert the PR), start the RPi Matter addon, and set the RPi HA's Matter URL back to the addon. The RPi's data is untouched; any Matter changes made while the cluster server was live (new devices) are lost, so avoid commissioning devices during the test window.

- [ ] **Step 10: Docs and memory**

Add `.61` (Matter server) and the macvlan/Multus design to `docs/src/general/network.md`; add to `docs/src/general/matter-thread.md` that the Matter server runs in the cluster on VLAN 48 (`net1`), and update `.claude/memory/reference_matter_thread_cross_vlan.md`. Commit on the same branch.


### Task 1.8: Music Assistant **[USER + CONFIRM]**

Branches: `feat/music-assistant` (app, scaled to 0), then `fix/music-assistant-start` (replicas 1)

Why macvlan: Music Assistant's docs say that without host networking "player discovery and any players that need direct network access (AirPlay, Chromecast, DLNA, Sonos, and similar) will not work", and that restricting ports is unsupported. A pod with its own VLAN 48 address (`net1`) has no port restrictions and receives the reflected mDNS, like the Matter server.

**Files:**
- Create: `cluster/apps/home-automation/music-assistant/app-config.yaml`
- Create: `cluster/apps/home-automation/music-assistant/Chart.yaml`
- Create: `cluster/apps/home-automation/music-assistant/values.yaml`
- Create: `cluster/apps/home-automation/music-assistant/templates/nad.yaml`

**Interfaces:**
- Consumes: Multus and the `vlan48` attachment pattern from Tasks 1.4–1.6.
- Produces: namespace `ha-music-assistant`; `net1` at `192.168.48.62/24` (web `:8095`, streams `:8097`); in-cluster Service on 8095 (the rendered name is recorded in Step 3; later tasks assume `music-assistant`); `ma.<domain>` on `envoy-internal`; PVC at `/data`.

- [ ] **Step 1: Recorded answers and remaining [USER] items**

Answers already given: players are **Chromecast and DLNA, all on the Trusted VLAN (`192.168.10.0/24`)**; the UniFi mDNS reflector covers every VLAN; the music library is **on the QNAP** (correction: an earlier reading of "no library" was wrong). Providers in use: **Spotify, YouTube Music, Tidal and the QNAP files**. Still to confirm with the user:
1. **Resolved: the RPi mounts the QNAP library as an NFS share through HAOS network storage**, so MA's Local-filesystem provider uses a path under `/media/<name>`. Still needed from the user (read from HAOS Settings → System → Storage): the mount `<name>` and the NFS server export path; the pod mounts the same export at `/media/<name>`. (Other options considered, for the record: either (a) a HAOS network-storage mount appearing under `/media/<name>` (Settings → System → Storage) used by MA's "Local filesystem" provider, or (b) MA's own SMB provider (`smb://192.168.50.8/<share>`) — not the case here.) The QNAP must allow the cluster nodes' pod egress (node IPs `192.168.48.2–5`, since pod traffic is SNATed) in the NFS share's access rules; the user confirms this on the QNAP. Streaming-provider credentials (Spotify, YouTube Music, Tidal) live in the add-on data and are restored with it; nothing is re-entered in git, but re-authorization may be requested (checked in Step 8).
2. **Firewall (UniFi):** already resolved. The user confirmed the Trusted ↔ infra zones (which contain VLAN 48 and 50) are allow-all, so `192.168.48.62` needs no new rules. Re-check only if players later move to another zone.
3. **Devices MA plays to today (user-reported: Samsung TV, Alexa Dot, Xbox, Nvidia Shield, plus Chromecasts) and the expected path for each:**
   - **Nvidia Shield and Chromecasts:** Google Cast provider, discovered over mDNS (works through the reflector).
   - **Samsung TV (QE55Q67T, 2020 QLED):** should support AirPlay 2; ask the user to confirm it is enabled on the TV (Settings → General → Apple AirPlay Settings) and check whether it appears under MA's AirPlay provider (mDNS, works through the reflector); otherwise DLNA (see Step 8).
   - **Xbox:** not used for music (user-confirmed); dropped.
   - **Alexa Dot:** not used with MA (user-confirmed); nothing to migrate and no public exposure needed.

- [ ] **Step 2: Create the branch, pin the image, write the files**

```bash
cd /workspaces/home-ops-ha-migration && git fetch origin main && git switch -c feat/music-assistant origin/main
gh release list -R music-assistant/server -L 3
docker buildx imagetools inspect ghcr.io/music-assistant/server:<TAG> | head -3
```

Use the stable tag matching the RPi add-on version where possible; record `tag@sha256:digest`.

`app-config.yaml`:

```yaml
- enabled: "true"
  namespace: ha-music-assistant
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

`Chart.yaml`:

```yaml
---
apiVersion: v2
name: music-assistant
type: application
version: 1.0.0
appVersion: "1.0.0"
dependencies:
  - name: app-template
    version: 5.2.1
    repository: https://bjw-s-labs.github.io/helm-charts
```

`templates/nad.yaml`:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: vlan48
spec:
  config: |
    {
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "capabilities": { "ips": true },
      "ipam": {
        "type": "static",
        "routes": [
          { "dst": "192.168.0.0/16", "gw": "192.168.48.254" }
        ]
      }
    }
```

`values.yaml`:

```yaml
app-template:
  defaultPodOptions:
    nodeSelector:
      node-role.kubernetes.io/control-plane: ""
  controllers:
    main:
      strategy: Recreate
      replicas: 0 # data restore first (Step 5); flipped to 1 in Step 6
      pod:
        annotations:
          k8s.v1.cni.cncf.io/networks: '[{"name":"vlan48","ips":["192.168.48.62/24"]}]'
      containers:
        main:
          image:
            repository: ghcr.io/music-assistant/server
            tag: <TAG>@sha256:<DIGEST>
          env:
            TZ: Europe/Warsaw
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
  service:
    main:
      controller: main
      ports:
        http:
          port: 8095
  route:
    main:
      annotations:
        external-dns.alpha.kubernetes.io/controller: dns-controller
      parentRefs:
        - name: envoy-internal
          namespace: envoy-gateway
          sectionName: https
      hostnames:
        - ma.<secret:private-domain>
      rules:
        - backendRefs:
            - identifier: main
  persistence:
    data:
      type: persistentVolumeClaim
      accessMode: ReadWriteOnce
      size: 5Gi
      globalMounts:
        - path: /data
```

Add the QNAP library as a read-only NFS volume under `persistence:` (path values come from Step 1 question 1; use the **same container path the restored provider config uses**, for example `/media/<name>`, so the restored Local-filesystem provider needs no edit):

```yaml
    library:
      type: nfs
      server: 192.168.50.8
      path: <qnap-nfs-export-path>
      globalMounts:
        - path: <container-path-from-restored-config>
          readOnly: true
```

If the RPi uses MA's SMB provider instead, no volume is needed: the restored `smb://192.168.50.8/<share>` provider works from the pod over `net1`/`eth0` as long as the QNAP is reachable (VLAN 50, allow-all). Note that MA mounting SMB itself may need extra container capabilities (`SYS_ADMIN`, `DAC_READ_SEARCH`) and an AppArmor/seccomp relaxation; prefer the NFS volume above and switch the provider to a Local-filesystem path if SMB mounting fails in the pod. Timezone `Europe/Warsaw` is user-confirmed.

- [ ] **Step 3: Verify the render, lint, commit, PR**

```bash
cd cluster/apps/home-automation/music-assistant && helm dependency build && helm template ma . -f values.yaml > /tmp/ma.yaml
grep -n -E "NetworkAttachmentDefinition|k8s.v1.cni|replicas: 0|port: 8095|ma\.|/data|node-role" /tmp/ma.yaml
grep -n -A3 "^kind: Service" /tmp/ma.yaml
cd /workspaces/home-ops-ha-migration && task lint:all
git add cluster/apps/home-automation/music-assistant
git commit -m "feat(music-assistant): add Music Assistant on VLAN 48 macvlan (scaled to 0)"
git push -u origin feat/music-assistant
gh pr create --base main --title "feat(music-assistant): Music Assistant on VLAN 48 macvlan" --body "Phase 1 of docs/superpowers/plans/2026-10-01-rpi-decommission.md. Starts scaled to 0 pending data restore."
```

Expected: the annotation with `192.168.48.62/24`, `replicas: 0`, port 8095, the `ma.` host and the `/data` mount appear. Record the rendered Service name; if it is not `music-assistant`, correct the URLs in Tasks 3.2 and 4.1 and in the spec.

- [ ] **Step 4: [USER] Stop the RPi add-on and back up its data**

Settings → Add-ons → Music Assistant → Stop, disable "Start on boot" (do not uninstall). Create a partial backup containing only **Music Assistant**, download the `.tar`. Never commit it. Also create a long-lived access token in the RPi HA (profile → Security) for Step 8 and keep it out of the repo and chat.

- [ ] **Step 5: Extract, check, and [CONFIRM] restore into the PVC (Deployment at 0 replicas)**

```bash
mkdir -p /tmp/haos && cd /tmp/haos && tar xf <backup>.tar && ls
mkdir -p ma && tar xzf addon_*music_assistant*.tar.gz -C ma
find ma -maxdepth 3 -type f | head -30
```

Adjust the archive name to what `ls` shows. Expected: `settings.json` and the library database (`library.db`) under `data/`. If missing, **stop**, restart the RPi add-on (rollback) and tell the user the backup lacked add-on data.

```bash
kubectl -n ha-music-assistant get pvc,deploy
kubectl -n ha-music-assistant run ma-restore --image=busybox:1.37 --restart=Never --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"music-assistant-data"}}],"containers":[{"name":"ma-restore","image":"busybox:1.37","command":["sleep","900"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl -n ha-music-assistant wait --for=condition=Ready pod/ma-restore
kubectl -n ha-music-assistant cp /tmp/haos/ma/data/. ma-restore:/data/
kubectl -n ha-music-assistant exec ma-restore -- ls -la /data
kubectl -n ha-music-assistant delete pod ma-restore
```

Adjust `claimName` to the real PVC and the source folder to where the files were found.

- [ ] **Step 6: Flip replicas, commit, PR, sync**

```bash
git fetch origin main && git switch -c fix/music-assistant-start origin/main
sed -i 's/replicas: 0 # data restore first.*/replicas: 1/' cluster/apps/home-automation/music-assistant/values.yaml
(cd cluster/apps/home-automation/music-assistant && helm dependency build && helm template ma . -f values.yaml | grep -n "replicas: 1")
git add -A && git commit -m "feat(music-assistant): start Music Assistant" && git push -u origin fix/music-assistant-start
gh pr create --base main --title "feat(music-assistant): start Music Assistant" --body "Phase 1 cutover; RPi add-on stopped first."
```

**[CONFIRM]** the sync after merge.

- [ ] **Step 7: Verify the pod and fix the published address**

```bash
kubectl -n ha-music-assistant logs deploy/music-assistant --tail=60
kubectl -n ha-music-assistant exec deploy/music-assistant -- ip -4 addr show net1
```

Expected: the server starts, `net1` is `192.168.48.62/24`, and the logs show providers loading. Then **[USER]** opens `https://ma.<domain>` → Settings → Core → Stream server and sets **Published IP address** to `192.168.48.62` (and bind to all interfaces). Without this MA may advertise the pod IP (`10.244.x.x`) to players.

From a host on the player VLAN (not the cluster):

```bash
nc -vz 192.168.48.62 8095
nc -vz 192.168.48.62 8097
```

Expected: both open.

- [ ] **Step 8: [USER] Repoint the RPi HA, then accept**

1. Music Assistant integration in the RPi HA: set the server URL to `http://192.168.48.62:8095` (the pod's `net1` address is routable from VLAN 50; the ClusterIP is not).
2. In MA → Settings → Providers → Home Assistant: URL of the RPi HA (`http://192.168.50.9:8123`) and the long-lived token from Step 4. The token is never committed.
3. Acceptance: library (including the QNAP files: a track plays from disk), playlists and favorites present; browse and play one item from each of Spotify, YouTube Music and Tidal (if one asks to re-authorize, the user does it in the MA UI; tokens are stored in `/data`); the Chromecasts on Trusted appear in MA's player list (mDNS via the reflector); play a track to each Chromecast and to a group; the queue survives **[CONFIRM]** `kubectl -n ha-music-assistant delete pod -l app.kubernetes.io/name=music-assistant`; the RPi HA's media-player entities control it. 4. **DLNA (known gap, now only the Samsung TV, and only if AirPlay does not work).** MA's DLNA provider documents automatic discovery plus a network scan of its own subnet, and no manual add by IP. SSDP does not cross VLANs (the mDNS reflector only forwards mDNS), so DLNA renderers on Trusted will probably not appear. Check Settings → Players after 5 minutes (the docs say discovery can take that long). If they are missing, in order:
   - **a. Add them to Home Assistant instead.** The HA `dlna_dmr` integration accepts a manual device-description URL (find it in the device's UPnP description, usually `http://<device-ip>:<port>/description.xml`), and MA's Home Assistant provider can expose selected HA `media_player` entities as MA players. Streams still come from MA at `192.168.48.62`, so the firewall rules from Step 1 apply. Verify with a real playback; if MA does not offer the entity as a player, go to b.
   - **b. Give the MA pod a second macvlan interface on the Trusted VLAN.** This needs VLAN 10 tagged on the node ports in UniFi, a Talos VLAN sub-interface (`eth0.10`) in `provision/talos/nodes/*.yaml`, and a second NetworkAttachmentDefinition on it. It restores SSDP/mDNS/broadcast on Trusted but puts the nodes on Trusted at L2 (bypassing inter-VLAN firewall rules), so it needs an explicit user decision and its own task before use.
   - **c. Drop DLNA for those devices** if Chromecast or another path covers them.

- [ ] **Step 9: Rollback path**

Scale the cluster server to 0 (revert the PR), start the RPi Music Assistant add-on, and repoint the RPi HA's MA integration back to the add-on. The RPi's add-on data is untouched.

- [ ] **Step 10: Docs and memory**

Add `.62` (Music Assistant) and `ma.<domain>` to `docs/src/general/network.md` and a short Music Assistant section (macvlan rationale, published IP setting, firewall requirement). Update `.claude/memory/` with a note that MA needs its own LAN address, not a bridge network. Commit on the Task 1.8 branch.

---

# PHASE 2 — DNS and ad-blocking

### Task 2.1: Move Talos nodes off the RPi's DNS **[CONFIRM]**

Branch: `fix/talos-nameserver`

**Files:**
- Modify: `provision/talos/templates/controlplane.yaml` (nameservers)
- Modify: `provision/talos/templates/worker.yaml` (nameservers, if present)

- [ ] **Step 1: Locate every nameserver reference**

```bash
cd /workspaces/home-ops-ha-migration && git fetch origin main && git switch -c fix/talos-nameserver origin/main
grep -n -B1 -A3 "nameservers" provision/talos/templates/*.yaml provision/talos/nodes/*.yaml
grep -n "192.168.50.9" provision/talos/templates/*.yaml provision/talos/nodes/*.yaml
```

- [ ] **Step 2: Replace `192.168.50.9` with `192.168.48.254` everywhere found**, including the NTP comment in `controlplane.yaml` that says "nameserver is AdGuard on the RPi" (reword to "nameserver is the UCG-Max").

```bash
sed -i 's/192\.168\.50\.9/192.168.48.254/' provision/talos/templates/controlplane.yaml provision/talos/templates/worker.yaml
sed -i 's/nameserver is AdGuard on the RPi/nameserver is the UCG-Max/' provision/talos/templates/controlplane.yaml
grep -n "192.168.50.9" provision/talos/templates/*.yaml || echo "none left"
```

Expected: `none left`.

- [ ] **Step 3: Regenerate and diff**

```bash
task talos:generate
git status --short
git diff --stat
```

Expected: only the template files (and generated files if tracked) change; no other drift.

- [ ] **Step 4: Commit and PR** — `git commit -am "fix(talos): resolve through UCG-Max instead of RPi AdGuard"`, push, `gh pr create`.

- [ ] **Step 5: [CONFIRM] Apply node by node**

After merge, show the user the apply command from `.taskfiles` (`task talos:apply` — read `.taskfiles/*/Taskfile.y*ml` to get the exact node argument form) and apply to **one node at a time**, waiting for the user's go-ahead between nodes. After each node:

```bash
TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig talosctl -n <node-ip> get resolvers -o yaml
```

Expected: `192.168.48.254` is the only resolver. Also `kubectl get nodes` stays `Ready`.

### Task 2.2: AdGuard Home app (two instances + sync)

Branch: `feat/adguard-home`

**Files:**
- Create: `cluster/apps/system/adguard-home/app-config.yaml`
- Create: `cluster/apps/system/adguard-home/Chart.yaml`
- Create: `cluster/apps/system/adguard-home/values.yaml`
- Create: `cluster/apps/system/adguard-home/templates/externalsecret.yaml`

**Interfaces:**
- Consumes: Bitwarden entries `ADGUARD_USER` / `ADGUARD_PASSWORD` (existing, UUIDs in `cluster/apps/system/adguard-dns/templates/externalsecret.yaml`).
- Produces: namespace `adguard-home`; DNS on `192.168.48.24` (primary) and `192.168.48.25` (replica); in-cluster web service of the primary for external-dns and `agh-proxy`; secret `adguard-home-secret` with `USERNAME`, `PASSWORD`.

- [ ] **Step 1: Pin images**

```bash
docker buildx imagetools inspect adguard/adguardhome:<TAG> | head -3
docker buildx imagetools inspect ghcr.io/bakito/adguardhome-sync:<TAG> | head -3
```

Use the latest stable tag of each (check `gh release list -R AdguardTeam/AdGuardHome -L 3` and `-R bakito/adguardhome-sync`). Record `tag@sha256:digest`.

- [ ] **Step 2: `app-config.yaml`**

```yaml
- enabled: "true"
  namespace: adguard-home
  syncWave: "-3"
  syncPolicy:
    enabled: true
    selfHeal: true
    prune: false
  plugin:
    env:
      - name: SECRET_PROVIDER
        value: cluster-secrets
```

- [ ] **Step 3: `Chart.yaml`** (same shape as Task 1.1 Step 3 with `name: adguard-home`).

- [ ] **Step 4: `values.yaml`**

```yaml
app-template:
  defaultPodOptions:
    labels:
      adguard-home/role: dns
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                adguard-home/role: dns
    nodeSelector:
      node-role.kubernetes.io/control-plane: ""
  controllers:
    primary:
      strategy: Recreate
      containers:
        main:
          image:
            repository: adguard/adguardhome
            tag: <TAG>@sha256:<DIGEST>
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
    replica:
      strategy: Recreate
      containers:
        main:
          image:
            repository: adguard/adguardhome
            tag: <TAG>@sha256:<DIGEST>
          resources:
            requests:
              cpu: 50m
              memory: 128Mi
            limits:
              memory: 512Mi
    sync:
      containers:
        main:
          image:
            repository: ghcr.io/bakito/adguardhome-sync
            tag: <TAG>@sha256:<DIGEST>
          args: ["run"]
          env:
            ORIGIN_URL: http://adguard-home-web-primary.adguard-home.svc.cluster.local:3000
            REPLICA1_URL: http://adguard-home-web-replica.adguard-home.svc.cluster.local:3000
            CRON: "*/10 * * * *"
            RUNONSTART: "true"
            FEATURES_DHCP_SERVER_CONFIG: "false"
            FEATURES_DHCP_STATIC_LEASES: "false"
          envFrom:
            - secretRef:
                name: adguard-home-secret
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
  service:
    dns-primary:
      controller: primary
      type: LoadBalancer
      annotations:
        lbipam.cilium.io/ips: "192.168.48.24"
      ports:
        dns-udp:
          port: 53
          protocol: UDP
        dns-tcp:
          port: 53
          protocol: TCP
    dns-replica:
      controller: replica
      type: LoadBalancer
      annotations:
        lbipam.cilium.io/ips: "192.168.48.25"
      ports:
        dns-udp:
          port: 53
          protocol: UDP
        dns-tcp:
          port: 53
          protocol: TCP
    web-primary:
      controller: primary
      ports:
        http:
          port: 3000
    web-replica:
      controller: replica
      ports:
        http:
          port: 3000
  persistence:
    data-primary:
      type: persistentVolumeClaim
      accessMode: ReadWriteOnce
      size: 2Gi
      advancedMounts:
        primary:
          main:
            - path: /opt/adguardhome/conf
              subPath: conf
            - path: /opt/adguardhome/work
              subPath: work
    data-replica:
      type: persistentVolumeClaim
      accessMode: ReadWriteOnce
      size: 2Gi
      advancedMounts:
        replica:
          main:
            - path: /opt/adguardhome/conf
              subPath: conf
            - path: /opt/adguardhome/work
              subPath: work
```

The sync tool reads `ORIGIN_USERNAME`/`ORIGIN_PASSWORD`/`REPLICA1_USERNAME`/`REPLICA1_PASSWORD` from the secret (Step 5).

- [ ] **Step 5: `templates/externalsecret.yaml`**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: adguard-home
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: bitwarden
  refreshInterval: 1h
  target:
    name: adguard-home-secret
    creationPolicy: Owner
    template:
      engineVersion: v2
      data:
        ORIGIN_USERNAME: "{{ `{{ .ADGUARD_USER }}` }}"
        ORIGIN_PASSWORD: "{{ `{{ .ADGUARD_PASSWORD }}` }}"
        REPLICA1_USERNAME: "{{ `{{ .ADGUARD_USER }}` }}"
        REPLICA1_PASSWORD: "{{ `{{ .ADGUARD_PASSWORD }}` }}"
  data:
    - secretKey: ADGUARD_USER
      remoteRef:
        key: "7e657efe-c9fa-420d-8959-b40800e9dea5" #gitleaks:allow #ADGUARD_USER
    - secretKey: ADGUARD_PASSWORD
      remoteRef:
        key: "6ccac8f0-d23e-48da-ae23-b40800e9e7f0" #gitleaks:allow #ADGUARD_PASSWORD
```

- [ ] **Step 6: Verify the render and the real Service names**

```bash
cd cluster/apps/system/adguard-home
helm dependency build && helm template adguard-home . -f values.yaml > /tmp/agh.yaml
grep -n -E "^kind: (Deployment|Service)|name: adguard-home-|lbipam|port: (53|3000)" /tmp/agh.yaml
```

Expected: Deployments `adguard-home-primary`, `-replica`, `-sync`; Services `adguard-home-dns-primary`, `-dns-replica`, `-web-primary`, `-web-replica` with the two LB IPs; both TCP and UDP 53. **If the Service names differ from `adguard-home-web-primary` / `adguard-home-web-replica`, fix `ORIGIN_URL` / `REPLICA1_URL` in `values.yaml` to the rendered names** before committing.

- [ ] **Step 7: Lint, commit, PR**

```bash
cd /workspaces/home-ops-ha-migration && task lint:all
git add cluster/apps/system/adguard-home
git commit -m "feat(adguard-home): add two-instance AdGuard Home with sync"
git push -u origin feat/adguard-home
gh pr create --base main --title "feat(adguard-home): in-cluster AdGuard Home (primary + replica)" --body "Phase 2 of docs/superpowers/plans/2026-10-01-rpi-decommission.md. Seeded with RPi config before DHCP cutover."
```

### Task 2.3: Seed config and verify DNS **[USER + CONFIRM]**

- [ ] **Step 1: [USER] Export from the RPi**

Ask the user to copy `AdGuardHome.yaml` from the HAOS AdGuard addon (`/addon_configs/<slug>_adguard/AdGuardHome.yaml`, via the Samba/SSH addon) to a local file. It contains admin password hashes: **never paste it into chat or commit it**.

- [ ] **Step 2: Prepare the seed locally**

Work on a copy; set:
- `http.address: 0.0.0.0:3000`
- `dns.bind_hosts: [0.0.0.0]`, `dns.port: 53`
- `dns.upstream_dns`: public DoH upstreams (for example `https://dns.cloudflare.com/dns-query`, `https://dns.quad9.net/dns-query`) plus, for the local zone and reverse lookups, `[/<domain>/]192.168.48.254` and `[/168.192.in-addr.arpa/]192.168.48.254`; `use_private_ptr_resolvers: true`, `local_ptr_upstreams: [192.168.48.254]`
- remove RPi-specific values (`dhcp` enabled flags, old `bind_host` addresses).
- Keep `users:` (so the Bitwarden credentials match), filters, user rules, clients.
- Record the rewrites list (`filtering.rewrites`) for Step 6.

- [ ] **Step 3: [CONFIRM] Seed both PVCs** (after merge, with each Deployment scaled to 0 or just created and crash-looping on first start; prefer scaling to 0 first)

```bash
kubectl -n adguard-home scale deploy/adguard-home-primary deploy/adguard-home-replica --replicas=0
for who in primary replica; do
  kubectl -n adguard-home run agh-seed-$who --image=busybox:1.37 --restart=Never --overrides="{\"spec\":{\"volumes\":[{\"name\":\"d\",\"persistentVolumeClaim\":{\"claimName\":\"adguard-home-data-$who\"}}],\"containers\":[{\"name\":\"agh-seed-$who\",\"image\":\"busybox:1.37\",\"command\":[\"sleep\",\"600\"],\"volumeMounts\":[{\"name\":\"d\",\"mountPath\":\"/data\"}]}]}}"
  kubectl -n adguard-home wait --for=condition=Ready pod/agh-seed-$who
  kubectl -n adguard-home exec agh-seed-$who -- mkdir -p /data/conf /data/work
  kubectl -n adguard-home cp <seed-file> agh-seed-$who:/data/conf/AdGuardHome.yaml
  kubectl -n adguard-home delete pod agh-seed-$who
done
kubectl -n adguard-home scale deploy/adguard-home-primary deploy/adguard-home-replica --replicas=1
```

Check the PVC names with `kubectl -n adguard-home get pvc` first and adjust `claimName`.

- [ ] **Step 4: Check pod placement and services (read-only)**

```bash
kubectl -n adguard-home get pods -o wide
kubectl -n adguard-home get svc
```

Expected: primary and replica on **different nodes**; LB IPs `192.168.48.24` and `.25` assigned.

- [ ] **Step 5: DNS verification from a LAN host (devcontainer or the user's machine)**

```bash
for ip in 192.168.48.24 192.168.48.25; do
  dig @$ip +short envoy-internal-test.<domain> A
  dig @$ip +short doubleclick.net A
  dig @$ip +short google.com A
  dig @$ip -x 192.168.48.254 +short
done
```

Expected for both IPs: the cluster-internal name resolves (use any existing app hostname), `doubleclick.net` returns `0.0.0.0` (blocked), `google.com` resolves, the reverse lookup answers from UniFi. Run it also from a host on VLAN 10 and VLAN 40.

- [ ] **Step 6: Rewrites diff (Review Focus 4)**

Compare `filtering.rewrites` from the seed with the `DNSEndpoint`s that external-dns publishes (`k8s.`, `qnap.`, plus every HTTPRoute host). Remove from the seed any rewrite that external-dns will recreate or any rewrite you cannot explain, so `policy: sync` has no foreign records to fight over. Confirm `adguardhome-sync` logs show a clean primary → replica sync:

```bash
kubectl -n adguard-home logs deploy/adguard-home-sync --tail=40
```

Expected: `Sync successful`, replica rewrites equal the primary's.

### Task 2.4: Repoint external-dns, `agh-proxy` and DHCP **[CONFIRM + USER]**

Branch: `chore/adguard-cutover`

**Files:**
- Modify: `cluster/apps/default/hass-proxy/templates/service.yaml` (agh Endpoints → primary web Service)
- Modify: `docs/src/general/network.md`

- [ ] **Step 1: [USER] Update Bitwarden `ADGUARD_URL`** to `http://adguard-home-web-primary.adguard-home.svc.cluster.local:3000` (use the rendered service name from Task 2.2 Step 6) and confirm. ESO refreshes within an hour; to force it, **[CONFIRM]** `kubectl -n adguard-dns annotate externalsecret adguard-dns force-sync=$(date +%s) --overwrite` then `kubectl -n adguard-dns rollout restart deploy/adguard-dns`.

- [ ] **Step 2: Verify external-dns writes to the primary**

```bash
kubectl -n adguard-dns logs deploy/adguard-dns -c external-dns --tail=30
```

Expected: successful reconcile, no 401/connection errors; a new test HTTPRoute host appears in both AdGuard instances after the next sync.

- [ ] **Step 3: Repoint `agh.<domain>`**

The `agh-proxy` `Service`/`Endpoints` pair in `cluster/apps/default/hass-proxy/templates/service.yaml` forwards to the RPi (`192.168.50.9:8812`). Delete that pair, and change the `agh-proxy` HTTPRoute backendRef in `httproute.yaml` to point straight at the new primary:

```yaml
        - name: adguard-home-web-primary
          namespace: adguard-home
          port: 3000
```

and add to `cluster/apps/system/adguard-home/templates/referencegrant.yaml` (create) a `ReferenceGrant` allowing `HTTPRoute` in `hass-proxy` to reference the Service:

```yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-hass-proxy-httproute
spec:
  from:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      namespace: hass-proxy
  to:
    - group: ""
      kind: Service
      name: adguard-home-web-primary
```

Verify: `kubectl kustomize`/`helm template` renders cleanly in both apps; `task lint:all`.

- [ ] **Step 4: Commit, PR, merge, verify** `https://agh.<domain>` shows the new instance's login and the same filters.

- [ ] **Step 5: [USER] DHCP cutover**

1. A day ahead, lower the DHCP lease time on each VLAN to 1 hour.
2. Set DNS servers for every VLAN to `192.168.48.24` and `192.168.48.25` (UniFi Networks → each network → DHCP name server). Do not add UniFi or the RPi as a third entry.
3. Watch the RPi AdGuard query log: client count should fall toward zero within the lease window. Ask the user to list the remaining clients and fix their static DNS settings.
4. Restore longer leases.

- [ ] **Step 6: Docs/memory**

Update `docs/src/general/network.md`: DNS flow (clients → `.24`/`.25`; UniFi upstream for the local zone; nodes → `.254`), IP table rows `.24`, `.25`, `.26`, `.60`, `.61`; remove "AdGuard on the RPi" wording. Update `.claude/memory/reference_gateway_dns_architecture.md` and `reference_home_network_hardware.md`.

---

# PHASE 3 — Home Assistant restore

### Task 3.1: Home Assistant app changes

Branch: `feat/home-assistant-prod`

**Files:**
- Modify: `cluster/apps/home-automation/home-assistant/values.yaml`
- Modify: `cluster/apps/home-automation/home-assistant/app-config.yaml` (`enabled: "true"`)
- Create: `cluster/apps/home-automation/home-assistant/templates/nad.yaml` (same content as Task 1.6 Step 2)
- Modify: `cluster/apps/home-automation/home-assistant/templates/secrets.yaml`

**Interfaces:**
- Consumes: CNPG secret `home-assistant-cnpg-app` (keys `uri`), Matter websocket from Task 1.6, MQTT service name from Task 0.1.
- Produces: HA on `192.168.48.60` (`net1`), recorder on Postgres, routes `dom.<domain>` (dry-run) and later `hass.<domain>`.

- [ ] **Step 1: Confirm the CNPG secret name (read-only, after the first sync) or from the chart**

```bash
grep -n "bootstrap" -A8 charts/pgsql-cnpg/templates/cnpg.yaml
```

The operator creates `<cluster-name>-app` with `uri`, `host`, `dbname`, `username`, `password`. Cluster name is `home-assistant-cnpg`, so the secret is `home-assistant-cnpg-app`. Use `kubectl -n ha-home-assistant get secret` after sync to confirm.

- [ ] **Step 2: Edit `values.yaml`** — `app-template.controllers.main`:

```yaml
      pod:
        annotations:
          k8s.v1.cni.cncf.io/networks: '[{"name":"vlan48","ips":["192.168.48.60/24"]}]'
```

and under `app-template.defaultPodOptions` add:

```yaml
    nodeSelector:
      node-role.kubernetes.io/control-plane: ""
```

and in the HA container add:

```yaml
          env:
            RECORDER_DB_URL:
              valueFrom:
                secretKeyRef:
                  name: home-assistant-cnpg-app
                  key: uri
```

Change `app-config.yaml` to `enabled: "true"`. Leave the `dom.` route in place for the dry-run.

- [ ] **Step 3: Update `templates/secrets.yaml` secret values**

`SECRET_MQTT_HOST` keeps `mqtt://home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local` (Review Focus 1: no LB IP). Leave `SECRET_EXTERNAL_URL` as `dom.` for the dry-run.

- [ ] **Step 4: Verify the render**

```bash
cd cluster/apps/home-automation/home-assistant && helm dependency build && helm template home-assistant . -f values.yaml | grep -n -E "k8s.v1.cni|RECORDER_DB_URL|home-assistant-cnpg-app|NetworkAttachmentDefinition|node-role"
```

Expected: all five strings present.

- [ ] **Step 5: Lint, commit, PR, merge, [CONFIRM] sync**

```bash
cd /workspaces/home-ops-ha-migration && task lint:all
git add -A && git commit -m "feat(home-assistant): enable with macvlan net1, Postgres recorder env, control-plane pinning"
```

After sync: `kubectl -n ha-home-assistant get cluster.postgresql.cnpg.io,pods,pvc` → CNPG healthy, HA pod running with `net1` (`kubectl -n ha-home-assistant exec sts/home-assistant -- ip -4 addr show net1` shows `192.168.48.60/24`).

### Task 3.2: Dry-run restore **[USER + CONFIRM]**

- [ ] **Step 1: [USER] Take a HAOS backup** (Settings → System → Backups, full, download the `.tar`). Never commit it.

- [ ] **Step 2: Extract only what is needed (local)**

```bash
mkdir -p /tmp/haos && cd /tmp/haos && tar xf <backup>.tar
ls
tar xzf homeassistant.tar.gz -C /tmp/haos/ha-config    # config
```

Adjust file names to what `ls` shows (HAOS uses `homeassistant.tar.gz` and per-add-on archives). The config sits under `data/` inside the archive.

- [ ] **Step 3: Sanitize the config copy**

In `ha-config/data/`:
- delete `home-assistant_v2.db*` (recorder history is not restored);
- move `automations.yaml`, `scripts.yaml`, `scenes.yaml` to `*.disabled` so nothing runs during the dry-run;
- ensure `configuration.yaml` has:

```yaml
recorder:
  db_url: !env_var RECORDER_DB_URL
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 10.244.0.0/16
```

merging with any existing `http:` and `recorder:` blocks (Review Focus 2);
- remove or comment `hassio:`/supervisor-only keys; grep for LB-IP or `mqtt.<domain>` uses of cluster services (Review Focus 1):

```bash
grep -rn -E "192\.168\.48\.(2[0-9]|3[0-9]|4[0-9]|50)|mqtt\.<domain>" /tmp/haos/ha-config/data/ || echo "no LB-IP references"
```

- In `.storage/core.config_entries` disable (`"disabled_by": "user"`) the `mqtt`, `matter`, `music_assistant` and any device-controlling entries for the dry-run. The cluster Matter server (Task 1.7) is serving the RPi's HA and must not get a second client sending commands. The Matter entry's URL is fixed at cutover (Task 4.1).

- [ ] **Step 4: [CONFIRM] Copy into the config PVC**

```bash
kubectl -n ha-home-assistant scale sts/home-assistant --replicas=0
kubectl -n ha-home-assistant run ha-restore --image=busybox:1.37 --restart=Never --overrides='{"spec":{"securityContext":{"runAsUser":568,"runAsGroup":568,"fsGroup":568},"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"home-assistant-config"}}],"containers":[{"name":"ha-restore","image":"busybox:1.37","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/config"}]}]}}'
kubectl -n ha-home-assistant wait --for=condition=Ready pod/ha-restore
kubectl -n ha-home-assistant cp /tmp/haos/ha-config/data/. ha-restore:/config/
kubectl -n ha-home-assistant delete pod ha-restore
kubectl -n ha-home-assistant scale sts/home-assistant --replicas=1
```

- [ ] **Step 5: Dry-run checks**

```bash
kubectl -n ha-home-assistant logs sts/home-assistant --tail=100
```

Expected: boots without the `hassio` errors, recorder connects to Postgres (`kubectl -n ha-home-assistant exec <cnpg-pod> -- psql -U app -c '\dt' | head` shows HA tables), `https://dom.<domain>` loads (valid session or onboarding), entity registry present. **[USER]** reviews integrations (Settings → Devices & services): list SSDP/UPnP/DHCP-discovery integrations to decide on IP-based reconfiguration (spec "Known gap"); check Chromecast discovery over `net1`.

---

# PHASE 4 — Cutover and decommission

### Task 4.1: Final cutover **[CONFIRM + USER]**

Branch: `feat/hass-cutover`

**Files:**
- Modify: `cluster/apps/home-automation/home-assistant/values.yaml` (route hostname + parents)
- Modify: `cluster/apps/home-automation/home-assistant/templates/secrets.yaml` (`SECRET_EXTERNAL_URL`)
- Modify: `cluster/apps/default/hass-proxy/templates/httproute.yaml` (remove `hass-proxy` HTTPRoute)
- Modify: `cluster/apps/default/hass-proxy/templates/service.yaml` (remove `hass-proxy` Service/Endpoints)

- [ ] **Step 1: Prepare the PR (not merged yet)**

In HA `values.yaml` change the main route to the production host and both gateways:

```yaml
  route:
    main:
      annotations:
        external-dns.alpha.kubernetes.io/controller: dns-controller
      parentRefs:
        - name: envoy-external
          namespace: envoy-gateway
          sectionName: https
        - name: envoy-internal
          namespace: envoy-gateway
          sectionName: https
      hostnames:
        - hass.<secret:private-domain>
      rules:
        - backendRefs:
            - identifier: main
```

Set `SECRET_EXTERNAL_URL: "https://hass.<secret:private-domain>"`. Remove the `hass-proxy` `HTTPRoute` and its `Service`/`Endpoints` (the proxy otherwise collides on the same hostname). Keep `dom-code.<domain>` (code-server). Render each app and lint.

- [ ] **Step 2: [USER] Take a fresh HAOS backup and stop the RPi HA**

Download the new full backup; then stop Home Assistant core on the RPi (`ha core stop` in the SSH/Terminal addon). From this moment the RPi's HA is down.

- [ ] **Step 3: Re-extract and sanitize** exactly as Task 3.2 Steps 2–3, **but without** moving automations aside and **without** disabling config entries; still fix MQTT broker host (`home-assistant-mqtt-rmq.ha-rabbitmq.svc.cluster.local`, via the integration's reconfigure after boot or by editing `core.config_entries`) the Matter URL (`ws://matter-server.ha-matter-server.svc.cluster.local:5580/ws`) and the Music Assistant URL (`http://music-assistant.ha-music-assistant.svc.cluster.local:8095`); then in MA's Home Assistant provider, repoint its HA URL to the cluster HA service and rotate the long-lived token.

- [ ] **Step 4: [CONFIRM] Restore the final HA config**

Repeat the HA config copy from Task 3.2 Step 4 (HA scaled to 0 first) with the final sanitized config. The Matter server is already running with the live fabric (Task 1.7), so there is no Matter data to restore here.

- [ ] **Step 5: [CONFIRM] Merge the cutover PR and sync** `home-assistant` and `hass-proxy`.

- [ ] **Step 6: Verify**

```bash
kubectl -n ha-matter-server logs deploy/matter-server --tail=50
kubectl -n ha-home-assistant logs sts/home-assistant --tail=100
```

Expected: the Matter server still shows all nodes connected (no "no fabrics" message), HA connects to MQTT and Matter without errors, `https://hass.<domain>` works **from the LAN and from the internet** (Cloudflare tunnel), the companion app reconnects, Z2M devices respond, Chromecast entities are available, automations fire. **[USER]** acceptance list: entity count roughly equals the old instance, a Matter device toggles, a Zigbee device toggles, TTS to a Chromecast plays, backup job configured (Task 4.2 step 3).

- [ ] **Step 7: Rollback path (if acceptance fails)**

Revert the cutover PR (restores `hass-proxy` to the RPi), tell the user to `ha core start` on the RPi, and stop the cluster HA (`replicas: 0`). Re-point the RPi HA's Matter integration back at `ws://192.168.48.61:5580/ws` if it was changed (the cluster Matter server keeps serving it; do not restart the RPi Matter addon). Phase 3's data stays on the PVCs for another attempt.

### Task 4.2: Decommission and cleanup

Branch: `chore/rpi-decommission`

**Files:**
- Modify: `docs/src/general/network.md`, `docs/src/general/hardware.md`, `docs/src/general/matter-thread.md`
- Modify: `.claude/memory/reference_home_network_hardware.md`, `reference_matter_thread_cross_vlan.md`, `reference_gateway_dns_architecture.md`
- Delete (after the retention window): `cluster/apps/default/hass-proxy/`

- [ ] **Step 1: [USER] Retention window**

Keep the RPi powered off with its SD card/backup for **14 days** (user-confirmed). During the window nothing should have used it: re-check AdGuard queries by client and the `hass.<domain>` access logs for the old path.

- [ ] **Step 2: Docs and memory**

- `network.md`: remove the RPi from the topology diagram and IP table; add AdGuard `.24`/`.25`, MQTT `.26`, macvlan `.60`/`.61`/`.62`; document the DNS flow and the macvlan/Multus design.
- `hardware.md`: mark the RPi decommissioned.
- `matter-thread.md`: production HA and the Matter server are now in the repo (`home-automation/home-assistant`, `matter-server`); note the OMR route must be revisited if the Thread network is re-formed.
- Memory files: update the three listed above; do not write the private domain literally.

- [ ] **Step 3: Backups for the new HA**

Add a VolSync `ReplicationSource` (follow the repo's existing VolSync pattern, `grep -rn ReplicationSource cluster/apps | head`) for the HA config PVC, Z2M data PVC, Matter PVC and Music Assistant PVC; verify one backup completes (`kubectl get replicationsource -A`).

- [ ] **Step 3b: Restrict the Matter WebSocket to the cluster network**

After Phase 4 the RPi's HA no longer needs the `net1` address. The matter.js server's WebSocket is unauthenticated and binds to all interfaces by default. In `cluster/apps/home-automation/matter-server/values.yaml` add the pod IP to the container env and bind to it so only cluster traffic (HA via the Service) reaches it:

```yaml
          env:
            POD_IP:
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
```

and add `--listen-address` / `$(POD_IP)` to the args (Kubernetes expands `$(POD_IP)` in `args`). Keep `--primary-interface net1` (Matter/mDNS still uses `net1`). Verify HA still reaches the server (`ws://matter-server.ha-matter-server.svc.cluster.local:5580/ws`) and that `nc -vz 192.168.48.61 5580` from another LAN host now fails. Commit via PR.

- [ ] **Step 4: Remove `hass-proxy`** following the repo's removal procedure (memory: `reference_app_removal_procedure.md` — deleting the directory never auto-prunes): delete `cluster/apps/default/hass-proxy/`, then **[CONFIRM]** `kubectl delete application hass-proxy -n argocd`, and check for PVCs (none expected).

- [ ] **Step 5: Final PR** with the docs/memory/cleanup changes; mark the plan complete by moving this plan to `docs/superpowers/archive/` if that is the repo's convention for finished work.

- [ ] **Step 6: [USER] Retire the RPi** (reuse or recycle). Done.
