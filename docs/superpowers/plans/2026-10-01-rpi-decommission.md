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
- Cilium LB pool is `192.168.48.20–50`. Allocations in this plan: `.25` AdGuard primary, `.31` AdGuard replica, `.26` MQTT (`.24` is already used by `alloy-router-syslog`; see the IP table in `docs/src/general/network.md`, and run its "check before assigning" commands before taking any address). Macvlan pod block `192.168.48.60–.69` (outside the pool): `.60` Home Assistant, `.61` Matter server, `.62` Music Assistant.
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

The RPi add-on is 2.10.5 (`music-assistant/home-assistant-addon` `music_assistant/config.yaml`); pin the same version (multi-arch index digest `sha256:28023f8c…aedc`, verified 2026-10-02). The addon is a thin wrapper around the upstream image `ghcr.io/music-assistant/server`, whose entrypoint is fixed to `--data-dir /data --cache-dir /data/.cache` (pass no `args`), which exposes 8095, and which runs as root (no `runAsNonRoot`). The addon excludes `cache.db`, `collage_images/*` and `.cache/*` from its backups, so the cache and artwork rebuild on first start. Upstream documents host networking as mandatory and a bridge network as unsupported; a macvlan `net1` with its own LAN address is neither (same stance as the Matter server), so Step 7 verifies discovery and the stream address explicitly.

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
            tag: 2.10.5@sha256:28023f8c0d96ca2496391f3218a6d70d7ef3ba84db846b3a3f3cd9ce7ef8aedc
          env:
            TZ: Europe/Warsaw
            LOG_LEVEL: info
          resources:
            requests:
              cpu: 100m
              memory: 512Mi
            limits:
              memory: 2Gi
  service:
    main:
      controller: main
      ports:
        http:
          port: 8095
        stream:
          port: 8097
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

- [ ] **Step 5b: Findings from the real backup (2026-10-03) and what Step 5 must do with them**
  - The backup is addon `d5369777_music_assistant` **2.10.4** (pin 2.10.4, not 2.10.5). `/data` is small (library DB 57MB, `auth.db`, `settings.json`, playlists/images dirs, `sendspin/` identity, WebRTC cert/key). Leave out `options.json`, `*.backup`, logs and `.cache`.
  - **Library provider is `filesystem_nfs`** (MA's own in-container NFS mount; host/export are Fernet-encrypted in `settings.json`, the key travels in the same file). Decision (user, option B): no `SYS_ADMIN`; the share is mounted by Kubernetes at `/media/music` and re-added as a Local filesystem provider (the 225 local tracks rescan as new items; their favorites and playlist entries are re-created by hand). In the restored `settings.json` set `providers[filesystem_nfs--*].enabled = false` so MA does not try to mount NFS in the container; remove that provider in the UI after the new one has scanned.
  - **Login lockout:** the only admin is linked solely to Home Assistant OAuth, which MA offers only once the `hass` provider has a URL (the restored `hass` provider has none). With an existing admin MA skips `/setup`, so you could not sign in. In the restored `auth.db`, delete the admin user and its provider link (keep `homeassistant_system`, the service user, and its integration token). With no non-system users MA redirects a browser request to `/setup`, where the user creates the first admin (username/password chosen by the user; never typed into the chat). Until then the JSON-RPC API answers 503 "Setup required", so the RPi HA's MA integration cannot connect before `/setup` is done.
  - Spotify already shows "playback authorization required" on the RPi; re-authorize it in the MA UI. There is no YouTube Music or Tidal provider in this MA. Players: Shield (Cast), MacBook (AirPlay), web players (Sendspin), plus HA media players `konsola_xbox_w_salonie` and `housekeeper` via the `hass_players` provider (needs the HA provider configured with the RPi HA URL and a long-lived token, entered in the UI; repoint to the cluster HA at cutover).
  - There is no `core.streams` section in the restored settings, so no stale `publish_ip`/`bind_ip`: set the published IP to `192.168.48.62` in the UI after the first start.

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

Also read the restored `settings.json` (extracted in Step 5) for network keys before the first start: if `publish_ip` or `bind_ip` hold the RPi's address (for example `192.168.50.9`), a stale `bind_ip` makes the server fail to bind and a stale `publish_ip` hands players the wrong address. Check with `python3 -c "import json;d=json.load(open('settings.json'));print({k:v for k,v in d.get('core',{}).get('streams',{}).get('values',{}).items() if 'ip' in k or 'url' in k})"` (adjust the path to the file's real structure; do not print provider credentials) and set both to the new address or empty before copying. The upstream docs also say the server detects its own IP at startup and to confirm it in the log; with two interfaces the default route is `eth0` (pod network), so confirm the logged address is `192.168.48.62`, not `10.244.x.x`.

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

### Task 2.1: Move Talos nodes off the RPi's DNS **[DONE 2026-10-03]**

PR #5431 first set `machine.network.nameservers` to the UCG-Max (`192.168.48.254`), which broke internal-name resolution: the UCG-Max and Cloudflare know no internal-only names (s3, qnap, k8s, argocd, the OIDC issuer host), and CoreDNS, which reads the node resolver list only at pod start, still held the old list. Interim list `[RPi, UCG-Max]`; **final list `[192.168.48.25, 192.168.48.31, 192.168.48.254]`** (both AdGuard instances, UCG-Max as last resort; PR #5437). Applied to mc1, mc2, mc3, nv1 one at a time without a reboot; `talosctl get resolvers` shows the three addresses.

**Lesson (do not repeat the plain `task talos:apply`):** the Taskfile pins Talos `v1.13.10` / Kubernetes `v1.35.9` (Renovate bumps) while the nodes run Talos installer `v1.13.8` / Kubernetes `v1.35.8`. A normal `task talos:apply N=<node>` would also have rolled the control-plane images and the installer image. What was done instead:
1. `task talos:generate TALOS_VERSION=v1.13.8 KUBERNETES_VERSION=v1.35.8` (versions overridden to the live ones; needs `mkdir -p provision/talos/clusterconfig` in a worktree).
2. `talosctl apply-config --nodes <ip> --file clusterconfig/home-<node>.yaml --dry-run -m auto` must show only the intended lines per node. (A JSON patch is refused on multi-document configs; a strategic-merge patch would append to the list instead of replacing it.)
3. `talosctl apply-config ... -m auto`, then verify resolvers and node Ready before the next node.
4. Delete the generated `clusterconfig/home-*.yaml` and `talosconfig` (they contain secrets) but keep the tracked `clusterconfig/.gitignore`.

The pending Renovate version bumps are a separate upgrade and have not been applied.

### Task 2.2: AdGuard Home app (two instances + sync) **[PR #5432]**

Built in `cluster/apps/system/adguard-home/` (namespace `adguard-home`): `adguard/adguardhome:v0.107.79` (latest stable, pinned by digest) as `primary` and `replica` Deployments, each with its own 2Gi Ceph PVC (`/opt/adguardhome/conf` and `/opt/adguardhome/work` via subPath), required pod anti-affinity, pinned to the control-plane nodes (Cilium L2 announcements exclude nv1); `ghcr.io/bakito/adguardhome-sync:v0.9.3` as `sync` (origin primary, replica1, `CRON */10 * * * *`, `RUN_ON_START true`, DHCP sync off; settings per the README: `RUN_ON_START`, not `RUNONSTART`). Services: `adguard-home-dns-primary` (LB `192.168.48.25`) and `adguard-home-dns-replica` (LB `192.168.48.31`), both `externalTrafficPolicy: Local` so AdGuard sees real client IPs (otherwise every query appears to come from a node, breaking per-client stats and putting all of VLAN 48 under one per-subnet rate limit); `adguard-home-web-primary` / `-replica` ClusterIP on 3000. ExternalSecret `adguard-home-secret` (Bitwarden `ADGUARD_USER` / `ADGUARD_PASSWORD`). **Everything starts at `replicas: 0`.**

IP choice: `.24` is used by `alloy-router-syslog`, so `.25` and `.31` are used; see the IP table in `docs/src/general/network.md` (PR #5433).

### Task 2.3: Seed the config, start, and verify DNS **[USER + CONFIRM]**

**What the RPi's AdGuard config turned out to be** (HAOS addon `a0d7b954_adguard` 6.3.0, from the user's backup `adg.tar`): no users (`users: []`, login through HA ingress), DHCP disabled, 3 filter lists, `use_private_ptr_resolvers` with `192.168.10.1`, 8 DNS rewrites (node short names, `unifi`, the Minecraft host, the ASUS DDNS name, two duplicating external-dns records), and 51 `user_rules`: 6 hand-written allowlist rules and 45 written by external-dns. **external-dns writes its records into `user_rules`** (`$dnsrewrite` rules plus `k8s.main.a-<host>` TXT ownership markers), not into the rewrites list. The seed keeps all 51 so cluster names resolve on day one and external-dns keeps ownership.

- [ ] **Step 1: Seed** (already built locally in the scratchpad `adg/seed/`: `conf/AdGuardHome.yaml`, `work/data/filters/*`). Changes versus the RPi file: `http.address: 0.0.0.0:3000`, `dns.bind_hosts: [0.0.0.0]`, `filtering.safe_fs_patterns` to the container path, and `users` set to the Bitwarden `ADGUARD_USER` with a bcrypt hash of `ADGUARD_PASSWORD` (generated without printing the password; the file is git-excluded and mode 600). Never commit it.
- [ ] **Step 2: [CONFIRM] Copy into both PVCs** (Deployments at 0 replicas), with a short-lived helper pod per PVC (`adguard-home-data-primary`, `adguard-home-data-replica`): create `conf` and `work/data`, `kubectl cp` the seed in, verify file sizes and that no `AdGuardHome.yaml` contains a plaintext password, delete the helper pods.
- [ ] **Step 3: Start PR:** flip `replicas` to 1 on `primary`, `replica` and `sync`; merge only after the copy is verified (same discipline as Matter and Music Assistant: an unseeded start would show AdGuard's first-run wizard instead of DNS).
- [ ] **Step 4: Verify (read-only):** primary and replica Running on **different nodes**; `kubectl -n adguard-home get svc` shows `.25` / `.31`; no wizard in the logs; `adguard-home-sync` logs a successful sync; AdGuard's query log shows **real client IPs** for queries sent to `.25` from a LAN host (not a node address); if the L2 leader sits on a node without the pod, `externalTrafficPolicy: Local` must still answer, otherwise re-check Cilium L2 behaviour before continuing.
- [ ] **Step 5: DNS checks** (no `dig` here: use a small Python UDP/TCP DNS query, or a throwaway pod): for both `.25` and `.31`, from VLAN 48 and from a host on another VLAN: an internal name (`ma.<domain>`), `doubleclick.net` (blocked, answers `0.0.0.0`), `google.com`, a reverse lookup (PTR via the UCG-Max), and the node short names (`mc1`). Compare the rule and rewrite counts with the RPi (51 / 8).

### Task 2.4: Repoint `agh.<domain>`, then DHCP **[CONFIRM + USER]**

external-dns reaches AdGuard through `ADGUARD_URL=https://agh.<domain>/control`, which is the `agh-proxy` route in the `hass-proxy` app (backend: the RPi's AdGuard on `192.168.50.9:8812`). **No Bitwarden change is needed**: repointing that route moves external-dns to the new primary, and it authenticates with the same Bitwarden user and password the new instances now enforce.

- [ ] **Step 1: One PR, two apps:** in the `adguard-home` app add an HTTPRoute for `agh.<domain>` (parent `envoy-internal`, annotation `external-dns.alpha.kubernetes.io/controller: dns-controller`, backend `adguard-home-web-primary:3000` in the same namespace, so no ReferenceGrant is needed); in the `hass-proxy` app remove the `agh-proxy` HTTPRoute, Service and Endpoints (keep `hass-proxy` until Phase 4). Two routes with the same hostname must not coexist, so both changes land together. Render both apps and lint.
- [ ] **Step 2: After sync (confirm):** `https://agh.<domain>` shows the new instance's login; `kubectl -n adguard-dns logs deploy/adguard-dns -c external-dns` shows successful reconciles (no 401); create or touch a test HTTPRoute host and confirm the rule appears in both instances after the next sync.
- [ ] **Step 3: [USER] DHCP cutover.** (a) A day ahead, lower lease times to 1 hour on each VLAN. (b) Set the DNS servers of every VLAN's DHCP to `192.168.48.25` and `192.168.48.31` (no UniFi or RPi entry). (c) Check **IPv6**: the LB addresses are IPv4 only, so look at each VLAN's IPv6 DNS (RDNSS/DHCPv6) setting; if clients are handed the RPi's IPv6 address or the gateway's, decide whether to leave that or turn it off. (d) Watch the RPi AdGuard query log (`http://192.168.50.9:8812/control/querylog`, same user as the cluster): client count should fall toward zero within the lease window; fix devices with a hardcoded DNS. Status 2026-10-03: hourly queries fell from about 4,500 to near zero; only six VLAN 10 clients (a Mac, a phone, a few IoT devices) were still querying it; all nodes, the QNAP and the SLZB were gone. (e) Restore normal lease times.
- [ ] **Step 4: Docs/memory:** `network.md` DNS flow (clients → `.25`/`.31`; UniFi for reverse lookups; nodes → `.254`), mark `.25` / `.31` live in the IP table (PR #5433 reserved them), update `.claude/memory/reference_gateway_dns_architecture.md` and `reference_home_network_hardware.md`.

### Task 2.5: CoreDNS and IPv6 follow-ups **[DONE 2026-10-03]**

- **CoreDNS upstreams.** After the node resolvers became `[.25, .31, .254]`, a CoreDNS restart (needed to pick them up) made about a third of pod queries go to the UCG-Max (CoreDNS `forward` defaults to `random`): internal names failed and `doubleclick.net` was not blocked. Talos has `cluster.coreDNS.disabled: true` here and offers no Corefile customisation, so CoreDNS is now self-provisioned as an ArgoCD app from the upstream `coredns` Helm chart (`cluster/apps/system/coredns/`, PR #5438) with `policy sequential`, plus `machine.kubelet.clusterDNS: [10.96.0.10]` and `cluster.coreDNS.disabled` in both Talos templates (applied to all four nodes). Verified from a pod: internal names, public names and ad blocking all resolve with 0/20 failures.
- **Lesson:** deleting the live `coredns` Deployment (needed because the chart changes the immutable selector) before the `coredns` Argo app existed deadlocked ArgoCD, whose repo-server needs cluster DNS, and caused a cluster-wide DNS outage until the rendered Deployment was applied by hand and the ApplicationSet controller restarted. Create the Argo app first.
- **IPv6 (option A).** A dual-stack LoadBalancer is impossible on this IPv4-only cluster, so each AdGuard pod got an IPv6-only macvlan interface (`vlan48-v6` NAD): primary `fd80:c04a:5687:48::25`, replica `fd80:c04a:5687:48::31` (PRs #5439, #5440). AdGuard's `0.0.0.0` listener is dual-stack on the pod's sockets, so no `bind_hosts` edit was needed. Verified over IPv6 for both addresses. The UniFi manual IPv6 DNS per VLAN is a user step.

---

# PHASE 3 — Home Assistant restore

### Task 3.1: Home Assistant app changes **[DONE 2026-10-03, PR #5442, #5444]**

Enabled `home-assistant` with `replicas: 0` first (so an empty config dir is not initialised before the restore; Argo `selfHeal` reverts an imperative `scale`, so the start is a second PR, #5444). CNPG `home-assistant-cnpg` 2/2 healthy, secret `home-assistant-cnpg-app` (`uri`), HA on `net1` `192.168.48.60/24`, pinned to the control plane. Original task text below.

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

### Task 3.2: Dry-run restore **[DONE 2026-10-03]**

What actually happened (differs from the steps below):
- The backup is partial (`homeassistant.tar.gz` plus `ssl`, no database); Core `2026.9.4` equals the image.
- **No YAML `http:` block:** the config already uses the UI-managed `.storage/http` (`yaml_migration_done`), so `10.244.0.0/16` (Envoy reaches HA from the pod network) was added to `trusted_proxies` there. The `recorder: db_url: !env_var RECORDER_DB_URL` block was added to `configuration.yaml`.
- Sanitized copy: `automations.yaml` / `scenes.yaml` replaced by `[]` (originals kept), `cloud:`, `alexa:`, the RPi `generic_thermostat` and the RPi GPIO `switches/` commented out, `.cloud`, `deps`, `zigbee2mqtt`, `zigbee.db`, `music_assistant.db`, `node-red` and `custom_components/rpi_gpio` removed. Config entries disabled: `hassio raspberry_pi rpi_power adguard mqtt matter music_assistant zha smlight alexa_devices`. MQTT broker and the three Wyoming hosts were changed from LB IPs (`.26`, `.27`) to cluster service DNS names, because a macvlan pod cannot reach an LB IP held by its own node.
- Copied with a busybox helper pod while HA was at 0 and verified by file-tree hash (2,481 files).
- **Sidebar:** the old add-on panels are gone without the Supervisor. They were replaced with YAML dashboards (`lovelace: dashboards:` in `configuration.yaml`, ids must contain a hyphen: `z2m-panel`, `music-assistant-panel`, `adguard-home-panel`, `vscode-panel`) holding an iframe card each. A new dashboard needs an HA restart. None of the target sites sends `X-Frame-Options`.
- **Gotcha:** clients still handed the RPi's AdGuard cannot resolve names added after the `agh` move (external-dns writes to the cluster AdGuard only), e.g. `dom.<domain>` did not load until the Mac renewed its DHCP lease.
- Original automations: Daily reboot (`hassio.host_reboot`, drop), UPS changed state (NUT event, re-check), Dobranoc, Jenny screen on/off (assist satellite), a Matter IKEA switch driving a Zigbee bulb (needs Matter and Z2M). Scenes: Salon, Salon On.

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

- [ ] **Step 2b: Preconditions found during Phase 3:** Z2M must be running (it has been crash-looping since 2026-10-03 with `EHOSTUNREACH 192.168.50.239:7638`; check the SLZB power and the VLAN 48 to 50 path first) and VLAN 10 clients must be off the RPi's AdGuard (renew DHCP leases) or they will not resolve `hass.<domain>` consistently.

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
