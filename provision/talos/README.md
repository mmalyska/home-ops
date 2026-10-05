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
  (the `UnattendedInstallConfig` document), `reboot` takes effect only after a node reboot (etcd settings, kernel modules,
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
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
```

To move such a node to a new Talos version, bump the tag in that file, nothing else. **Confirm a matching custom
installer exists first.** nv1's GPU kernel modules (`host1x`, `tegra_drm`, `nvgpu`, …) are ABI-bound to the exact
kernel build in that image, and Talos loads them during the boot sequence before starting services, so a mismatched
image can leave the node with networking up but `apid` never starting: reachable at the TCP level, unmanageable, and
fixable only over the console. See `docs/superpowers/specs/2026-08-13-jetson-igpu-design.md` and
`docs/superpowers/specs/2026-08-13-jetson-installer-build-design.md`.

The disk selector is repeated in this file on purpose: `talosctl machineconfig patch` drops `provisioning.diskSelector.match`
when a later patch merges into the document, so it must be in the last file applied for the node (see the header of the
file).

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

## Inspecting the config

`task talos:explain -- mc1` lists, for a node, every patch file in merge order with what it does, why, what applying
it costs, what it touches and which earlier file touches the same top-level item. Without arguments it shows all nodes;
`--markdown` prints the tables used for the generated config map.

`task talos:config-map` writes the same information for all nodes to `docs/src/talos/config-map.md`
(published with the docs). The file is generated from the patch headers, contains no secrets, and CI fails when it
is stale; regenerate it after any change to a patch file.

`task talos:diff -- mc1` renders the node from the repo, reads the config the node actually runs, and shows the
difference with secret values masked, plus the running Talos version against the expected one. It needs the same
environment as `task talos:generate` and a reachable cluster, and changes nothing. A node whose stored install-image tag
lags (for example nv1 after an upgrade) shows up here.

## Install settings and reinstalling a node

`patches/all/30-install.yaml` (explicit `wipe: false`), the role files `controlplane/05` and `worker/05` and
`node/nv1/20` build one `UnattendedInstallConfig` document per node: installer image, disk selector
(`disk.dev_path == "/dev/nvme0n1"`) and `wipe: false`. On an installed node the document is inert apart from
naming the installer image that upgrades use. It is meant to act when a node is not installed yet: a node booted
from USB or PXE in maintenance mode that is given this config should install itself to the matched disk, without a
separate `talosctl install`. **That path is expected but untested here**; try it on the first real reinstall and
record what you find. `wipe` defaults to true in this document and is set to false explicitly, so a wipe stays a
deliberate manual step.

## Checks

`task talos:check` runs, without secrets or a cluster, the patch convention check (`scripts/check-patches.sh`), the
config map freshness check and the shell tests (`tests/run.sh`). The same three run in CI
(`.github/workflows/talos-config.yaml`) on pull requests that touch `provision/talos/**`.

## Secrets

All secrets come from Bitwarden Secrets Manager: `.envrc` runs `bws` and exports them as `TALHELPER_*` environment
variables (the prefix is inherited from talhelper, which is no longer used). `secrets.yaml.tpl` maps them to the
talosctl secrets bundle format, and the few `.yaml.tpl` patches substitute the values they need. Nothing encrypted
is committed; the rendered files in `clusterconfig/` contain secrets and stay gitignored.
