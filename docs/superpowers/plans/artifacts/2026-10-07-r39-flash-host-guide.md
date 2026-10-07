# Flash nv1 to JetPack 7 (r39.2.0 QSPI) from an Ubuntu host

Date: 2026-10-07. Companion to `2026-10-03-r39-phase-b-flash-rollback.md` (what and why). This file is the how. Written from Seeed's and NVIDIA's scripts, **not run on hardware**; steps marked *verify* are the ones to check as you go. Stop at any step that does not match.

What it does: replaces only the firmware in the module's SPI flash (QSPI: bootloader, UEFI, DTB) with Seeed's r39.2.0 firmware for the standard J401 (`recomputer-orin-j401`). The NVMe with the current Talos install is not touched. Then you boot the r39 Talos USB image to look at the GPU stack before changing anything on the NVMe.

## 0. Which host

NVIDIA's flash tool (`l4t_initrd_flash.sh`) boots a small initrd on the board and then, for Orin, the host serves the files to the board over **NFS on a USB network link (`usb0`, IPv6) and SSH**. The board also re-enumerates on USB in the middle of the run.

| Host | Verdict |
|---|---|
| Native Ubuntu 22.04 or 24.04 on x86-64 (PC, laptop, mini PC) | **Use this.** |
| Ubuntu live USB on your Windows PC (boot it, "Try Ubuntu", no install) | **Good option if you have no Linux machine.** Needs about 60 GB free disk to work on (an external SSD, or a second internal disk); the live session's RAM disk is too small. |
| WSL2 on Windows | **Not recommended.** The stock WSL2 kernel has no NFS server and no USB-network drivers, USB reaches WSL only through `usbipd-win`, and the board has to be re-attached when it re-enumerates mid-flash. A half-finished QSPI flash is the worst moment to hit a problem. See section 9 if you still want to try. |

The rest assumes native Ubuntu (or a live USB) with `sudo`, about 60 GB free, and a USB-C data cable to the board's flashing port.

## 1. Prepare the host

```sh
sudo apt-get update
sudo apt-get install -y wget git curl lbzip2 build-essential flex bison libssl-dev bc
mkdir -p ~/r39 && cd ~/r39
```

## 2. Download the BSP (r39.2.0, not r39.2.1)

Firmware and DTB come from r39.2.0 (what Seeed's overlay targets). The r39.2.1 tarball in the repo's CI is only for userspace libraries.

```sh
wget https://developer.nvidia.com/downloads/embedded/l4t/r39_release_v2.0/release/Jetson_Linux_r39.2.0_aarch64.tbz2
wget https://developer.nvidia.com/downloads/embedded/l4t/r39_release_v2.0/release/Tegra_Linux_Sample-Root-Filesystem_r39.2.0_aarch64.tbz2
sha256sum Jetson_Linux_r39.2.0_aarch64.tbz2 Tegra_Linux_Sample-Root-Filesystem_r39.2.0_aarch64.tbz2 | tee SHA256.txt
tar xf Jetson_Linux_r39.2.0_aarch64.tbz2
sudo tar xpf Tegra_Linux_Sample-Root-Filesystem_r39.2.0_aarch64.tbz2 -C Linux_for_Tegra/rootfs/
```

Keep `SHA256.txt` (NVIDIA publishes no checksum next to the download, so this is your record for the rollback notes).

## 3. Add Seeed's overlay

```sh
git clone --depth=1 -b r39.2.0 https://github.com/Seeed-Studio/Linux_for_Tegra.git seeed   # about 3.5 GB
cp -r seeed/* Linux_for_Tegra/
cd Linux_for_Tegra
sudo ./tools/l4t_flash_prerequisites.sh      # apt packages for the flash tool (NFS server, qemu, sshpass, ...)
sudo ./apply_binaries.sh                      # fills rootfs/ with NVIDIA's packages
```

## 4. Build the board DTBs

Seeed's repo has the DTS sources but not the compiled `recomputer` DTBs. Build them (this builds the whole kernel tree, expect 30 to 90 minutes and about 15 GB; only the DTBs are used):

```sh
wget https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/toolchain/aarch64--glibc--stable-2022.08-1.tar.bz2
mkdir -p l4t-gcc && tar xf aarch64--glibc--stable-2022.08-1.tar.bz2 -C l4t-gcc
export ARCH=arm64
export CROSS_COMPILE=$(realpath .)/l4t-gcc/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
cd source
./nvbuild.sh          # kernel + DTBs into kernel_out/ (do NOT pass -i)
./do_copy.sh          # copies the finished DTBs to ../kernel/dtb/
cd ..
ls -l "kernel/dtb/tegra234-j401-p3768-0000+p3767-0000-recomputer.dtb" \
      kernel/dtb/tegra234-dcb-p3767-0000-hdmi.dtbo \
      kernel/dtb/tegra234-p3767-camera-p3768-imx219-dual-seeed.dtbo \
      kernel/dtb/tegra234-carveouts.dtbo
sudo ./tools/l4t_update_initrd.sh
```

*Verify:* all four files exist. If `nvbuild.sh` fails on the toolchain (the r36 toolchain URL is the one Seeed's README uses), stop and tell me the error. If `do_copy.sh` does not produce the `recomputer.dtb`, stop.

## 5. Board in recovery mode, then a harmless dry run

Cluster side first (these change the cluster, so ask me to run them or do them yourself): scale down llama-server and embeddings, `kubectl cordon nv1`, `kubectl drain nv1 --ignore-daemonsets --delete-emptydir-data`. Then `talosctl -n 192.168.48.5 shutdown`.

Put the module in recovery mode as in Seeed's J401 guide (<https://wiki.seeedstudio.com/reComputer_J4012_Flash_Jetpack/>: power off, short the recovery jumper, USB-C data cable from the flashing port to the host, power on). Check:

```sh
lsusb | grep -i nvidia      # must show one NVIDIA device in APX/recovery mode
```

Dry run, builds the flash package and reads the module's identity, writes nothing to the board:

```sh
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg" \
  --no-flash --showlogs --network usb0 recomputer-orin-j401 external 2>&1 | tee ~/r39/dryrun.log
```

*Verify in `dryrun.log`:*
- the DTB it picks is `tegra234-j401-p3768-0000+p3767-0000-recomputer.dtb`
- `tegra234-carveouts.dtbo` is in the overlay list (nvgpu and nvmap need its `reserved-memory`)
- it mentions only the SPI layout `flash_t234_qspi.xml`, no `nvme0n1p1` and no external device
- no `Error`

Send me `dryrun.log` (or the relevant lines) before continuing.

Do **not** run the README's command with `--external-device nvme0n1p1 … internal`: that writes the NVMe.

## 6. Flash the QSPI

Keep the board in recovery mode and do not touch the cable.

```sh
sudo ./tools/kernel_flash/l4t_initrd_flash.sh \
  -p "-c bootloader/generic/cfg/flash_t234_qspi.xml --no-systemimg" \
  --flash-only --showlogs --network usb0 recomputer-orin-j401 external 2>&1 | tee ~/r39/flash.log
```

It takes roughly 10 to 20 minutes and ends with a success message. If it fails, the module stays in recovery mode and can simply be flashed again. The module is still recoverable from a failed flash as long as recovery mode works.

Afterwards: remove the recovery jumper, disconnect the USB-C cable, connect HDMI and a USB keyboard (or serial), power on. The old r36 Talos on the NVMe may boot, but without a working GPU (the r39 DTB does not match the r36 modules); that is expected and nv1 stays cordoned.

## 7. First boot of the r39 Talos image (no NVMe change)

On Windows, download the artifact (`gh run download 37633299032 -R mmalyska/talos-jetson-orin`, or from the run page) and write `talos-usb-nvgpu39.2.1-jp7.raw` to a 16 GB+ USB stick with Rufus (DD mode) or balenaEtcher.

Plug it into nv1, power on, open the UEFI menu (Esc or Del at the logo) and boot from the USB stick if it is not picked by itself. Talos comes up in maintenance mode (nothing is installed). From the repo, with the node's DHCP address from the console:

```sh
talosctl --insecure -n <ip> dmesg > nv1-r39-dmesg.txt
grep -iE "host1x|nvmap|nvgpu|tegra_hv|ivc|tegra-drm|firmware|ga10b|taint|oops|BUG" nv1-r39-dmesg.txt
```

*Good:* `host1x` and `nvgpu` probe without errors, `/dev/dri/renderD128` is created, no `ga10b` firmware load failure. Send me the dmesg and we decide on the next step together. Applying the machine config to the NVMe (Phase C3) is a separate decision.

## 8. Rollback

Same tool, r36.5 package: download `Jetson_Linux_r36.5.0_aarch64.tbz2` (<https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v5.0/release/>) and the matching sample rootfs, clone `Seeed-Studio/Linux_for_Tegra` branch `r36.5.0`, repeat sections 2 to 6 in a new directory with the same QSPI-only command (r36 DTBs are built the same way). The NVMe Talos then boots as before.

## 9. WSL2, only if you insist

Treat it as an experiment and stop at the first failed check.
1. `winget install usbipd` on Windows, then in an admin PowerShell: `usbipd list`, `usbipd bind --busid <id>`, `usbipd attach --wsl --busid <id> --auto-attach`.
2. WSL2 needs a custom kernel (`.wslconfig` `kernel=`) with `CONFIG_NFSD`, `CONFIG_NFSD_V4`, `CONFIG_USB_USBNET`, `CONFIG_USB_NET_CDCETHER`, `CONFIG_USB_NET_RNDIS_HOST`, `CONFIG_USB_NET_CDC_NCM`, IPv6, and systemd enabled in `/etc/wsl.conf` (for `binfmt` and `qemu-user-static`).
3. The check that decides everything: after the dry run reaches the point where the board boots its initrd, a `usb0` interface must appear in WSL (`ip a`). If it does not, stop and use a native Ubuntu live USB.
