# Phase B: r39 flash and rollback checklist for nv1

Date: 2026-10-03. Plan: `docs/superpowers/plans/2026-10-01-talos-jetson-r39-port.md`. Nothing in this file has been run on hardware. Steps marked **verify** rest on reading Seeed's and NVIDIA's scripts, not on a test.

## What B1 to B3 found

**B2, QSPI-only flash: yes, with Seeed's own config.** Seeed's `Linux_for_Tegra` (branch `r39.2.0`) flashes the standard J401 with the config `recomputer-orin-j401` (DTB `tegra234-j401-p3768-0000+p3767-0000-recomputer.dtb`, pinmux/padvoltage `*-hdmi-a03`, overlays `tegra234-dcb-p3767-0000-hdmi.dtbo` and `…imx219-dual-seeed.dtbo`). Their CI builds a QSPI-only package for the same config in two ways (`.gitlab-ci.yml` lines 168 and 170):

```sh
# T234, as in Seeed's CI: only the SPI-flash layout, no system image
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg" \
  --showlogs --network usb0 recomputer-orin-j401 external
# or, with the newer switch the script also has
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --qspi-only --showlogs --network usb0 recomputer-orin-j401 external
```

`flash_t234_qspi.xml` declares one device only, `type="spi" instance="0"` (BCT, mb1/mb2, bpmp, secure-os, UEFI `cpu-bootloader`, eks, dce, rce, adsp and so on, A and B slots). It has no NVMe or eMMC partitions, so the NVMe disk with the current Talos install is not touched. **Verify** on the flash host before nv1 is connected: run the command with `--no-flash` first (builds the package, no device needed; Seeed's CI sets `BOARDID`, `BOARDSKU`, `FAB`, `BOARDREV`, `CHIP_SKU` for this, take the values from the module's EEPROM or nv1's current r36 log).

Do **not** use the README command (`--external-device nvme0n1p1 … internal`): it repartitions and writes the NVMe.

Seeed's own production flow is the same idea: stage 1 is a minimal QSPI image, stage 2 is the SSD. Seeed r39 firmware boots from NVMe, which is what Talos needs.

**B1, flash package.** Seeed does not publish a ready r39 package for this; build from sources:

| Item | Source | Notes |
|---|---|---|
| NVIDIA BSP | `https://developer.nvidia.com/downloads/embedded/l4t/r39_release_v2.0/release/Jetson_Linux_r39.2.0_aarch64.tbz2` | **r39.2.0**, not the r39.2.1 tarball used for the userspace extension. Record the SHA-256 when downloaded. |
| Sample rootfs | `…/Tegra_Linux_Sample-Root-Filesystem_r39.2.0_aarch64.tbz2` | The flash scripts expect `rootfs/`; **verify** whether a QSPI-only run needs it populated (Seeed's CI does it). |
| Seeed overlay | `https://github.com/Seeed-Studio/Linux_for_Tegra`, branch `r39.2.0` (HEAD `df17ed2`) | Copy over the BSP tree (`cp -r … Linux_for_Tegra/`). Board configs, pinmux, `kernel/dtb/` and bootloader overrides. |
| DTBs | built in Seeed's tree (`kernel/dtb/`) | No prebuilt `*recomputer*.dtb` ships in the repo. Either build them (readme steps 3 to 8, kernel source sync) or take them from Seeed's release package. Open item. |
| Flash host | x86-64 Ubuntu 22.04/24.04, `sudo`, USB-C data cable to the recovery port, `abootimg`, `qemu-user-static`, `sshpass`, `libxml2-utils`, `nfs-kernel-server` | Needs a real x86 host; the home-ops devcontainer is not suitable (USB passthrough). |

The flashed firmware/DTB (r39.2.0) and the module sources and userspace libraries (r39.2.1) differ by one point release. A1 recorded that r39.2.1 leaves the GPU, host1x and MC device-tree nodes and the nvgpu source unchanged versus r39.2.0.

**B3, overlays and carveouts.** Seeed's `recomputer-orin-j401.conf` adds exactly two overlays on top of the NVIDIA defaults (HDMI display DCB and the dual IMX219 camera overlay). The `reserved-memory` carveouts nvgpu/nvmap need come from NVIDIA's `tegra234-carveouts.dtbo`, which the BSP applies at flash time through `OVERLAY_DTB_FILE`. **Verify** after the dry run: `OVERLAY_DTB_FILE` in the generated flash log lists `tegra234-carveouts.dtbo`, and decompile the DTB the flash would write (the `bootloader/*.dtb` it produces) and compare its `reserved-memory` with `nv1-live.dts` captured from the running r36 node (research finding 7).

## B4: nv1 maintenance plan

Test target: nv1 itself (no spare Orin). The design keeps the existing NVMe Talos (r36, Talos v1.13.10, `ghcr.io/schwankner/custom-installer:v1.13.10-6.18.48-nvgpu5.11.1-drm-noshim`) untouched until C3, so rollback up to that point is a QSPI reflash.

Impact to expect: **all GPU consumers are down for the whole window** (hours; plan a day). nv1 is the only GPU node.

| Consumer | Where | Before the window |
|---|---|---|
| llama-server | `cluster/apps/ai/llm/server/` | scale to 0 (ArgoCD `selfHeal` will revert a manual scale: disable auto-sync on the app first, or set `replicas: 0` on the branch) |
| embeddings | `cluster/apps/ai/llm/embeddings/` | same |
| Hermes agent | `cluster/apps/ai/hermes-agent/` | main model and compression are cloud already; check what falls back when llama-server is gone |
| device plugin, CDI setup, power-mode | `cluster/apps/system/nvidia/` | stay deployed; the r36 CDI DaemonSet will fail on an r39 boot, expected until D3 |

Cluster side (needs the user's confirmation before each, per the hard rules): `kubectl cordon nv1`, `kubectl drain nv1 --ignore-daemonsets --delete-emptydir-data`. The OSDs are on mc1 to mc3 (check `kubectl -n rook-ceph get pods -o wide | grep osd` that none is on nv1); if none is, no `noout` is needed. Node labels and taints to restore are in `provision/talos/nodes/nv1.yaml` (`accelerator: jetson-orin`, `nvidia.com/gpu.type: igpu`; kubelet re-registers the node, so labels from the machine config come back by themselves).

Needed at the console: **HDMI monitor and USB keyboard, or the serial header**. After a QSPI reflash the UEFI variables (boot order) may be reset; Talos' fallback path `\EFI\BOOT\BOOTAA64.efi` on the ESP should still boot, but picking the entry by hand in the UEFI menu must be possible. **Verify** (unverified: Orin UEFI variable persistence across QSPI reflash).

## B5: rollback kit (assemble before the window)

1. **r36.5 flash package**: `https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v5.0/release/Jetson_Linux_r36.5.0_aarch64.tbz2` plus Seeed's branch `r36.5.0` (HEAD `f9a6831`), same `recomputer-orin-j401` config, flashed with the same QSPI-only command. Dry-run it too (`--no-flash`) and keep the package on the flash host, plus its SHA-256.
2. **Current r36 USB image / installer**: `ghcr.io/schwankner/custom-installer:v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim` (from `provision/talos/patches/node/nv1/20-install-image.yaml`) is what the NVMe boots today. Keep a USB stick with the matching r36 image from the fork's last r36 release.
3. **Live DTB**: re-capture right before the flash: `TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig talosctl -n 192.168.48.5 read /sys/firmware/fdt > nv1-live-<date>.dtb` (the earlier copy is `nv1-live.dtb`).
4. **Machine config**: The nv1 patches under `provision/talos/patches/node/nv1/` are in git, nothing to export (`task talos:explain -- nv1` lists them in merge order). Note the node's META state (`talosctl -n 192.168.48.5 meta` and `get operatorspecs`); the DHCP key `0x0a` has to be re-checked after any reflash (`docs/src/k8s/nv1-jetson.md`).
5. **Rollback procedure** (valid until C3 wrote r39 to the NVMe): put nv1 in recovery, flash the r36.5 QSPI package, boot from NVMe, check `talosctl -n 192.168.48.5 health`, `kubectl get node nv1`, uncordon, scale GPU apps back. After C3 the NVMe holds the r39 install, so rollback also needs the r36 installer applied again. Both images are Talos v1.14.0, so this is a same-version `talosctl upgrade` and hits the Jetson UEFI stale-boot-entry problem (see below); the reliable route is the r36 USB image and a reinstall.

## Things the plan did not have before

- **Same-version install and the UEFI boot entry.** nv1 already runs Talos v1.14.0 on the r36 custom installer (`v1.14.0-6.18.48-nvgpu5.11.1-drm-noshim`); the control plane is on v1.14.2 (a worker one patch behind is fine). The r39 installer is `v1.14.0-6.18.48-nvgpu39.2.1-jp7`, so C3 is a same-version change, and the Jetson UEFI keeps booting the old UKI after it (`provision/talos/README.md`, "nv1 boots the wrong UKI after an upgrade"; upstream Bug 25). Expect to rename the stale UKI on the ESP (privileged pod on nv1, `mv EFI/Linux/Talos-v….efi …bak`) and to repeat it for a rollback. `task talos:upgrade` fails with `nv1 runs vX, expected vY` when it happens; do not re-run the upgrade. Moving nv1 to Talos 1.14.2 as well would need a new custom installer with that Talos version and kernel; the fork's r39 build is pinned to Talos 1.14.0 / kernel 6.18.48 (`scripts/common.sh`).
- **Registry credentials.** The fork's packages must stay private (NVIDIA binaries). A node that pulls `ghcr.io/mmalyska/custom-installer:…` (upgrade or reinstall in C3, and the installer image in `20-install-image.yaml`) needs `machine.registries.config` with a pull token. The USB image carries everything and needs no pull. Today's installer comes from `ghcr.io/schwankner/…` (public).
- **C1 stays non-destructive.** Booting the r39 USB image in maintenance mode touches neither the NVMe nor Kubernetes. Everything up to C2 can be judged from `dmesg` before deciding to continue.

## Go/no-go before the flash (Phase C gate)

- [ ] r39.2.0 BSP and Seeed overlay assembled on the flash host, SHA-256 recorded
- [ ] `--no-flash` dry run done for r39 **and** r36.5; carveouts overlay confirmed (B3)
- [ ] r36.5 rollback package and r36 USB image on hand
- [ ] Live DTB re-captured
- [ ] Console access (HDMI + keyboard or serial) ready, USB stick with the r39 image written (`talos-usb-nvgpu39.2.1-jp7.raw` from the release artifact)
- [ ] GPU apps scaled to 0, ArgoCD auto-sync handled, node cordoned and drained (needs your confirmation)
- [ ] Explicit go-ahead from the user for Phase C
