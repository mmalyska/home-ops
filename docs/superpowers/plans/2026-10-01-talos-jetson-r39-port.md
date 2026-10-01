# Plan: port talos-jetson-orin to JetPack 7 (r39 / CUDA 13)

Date: 2026-10-01. Status: plan only, no code written. Research: `docs/superpowers/research/2026-10-01-jetpack7-nv1.md`.

## Goal

Get nv1 (Jetson Orin NX 16 GB, standard Seeed reComputer J401) running Talos with a working GA10B GPU on JetPack 7.2 (Jetson Linux r39.2), so pods can run CUDA 13 workloads. Work happens in the fork `mmalyska/talos-jetson-orin` (upstream `schwankner/talos-jetson-orin`, pinned to r36.5 today). The r36.5 build must keep working until r39 is proven on hardware.

Out of scope: board swap and MAXN Super (separate decision, see `.plans/TODO.md`), CUDA 13 workload images, vLLM.

## Context a fresh session needs

- **How the fork builds.** Siderolabs `pkgs`-style packages. `nvidia-tegra-nvgpu/pkg.yaml` downloads three pinned tarballs (OE4T `linux-nvgpu`, `linux-nv-oot` branch `patches-r36.5`, `linux-hwpm`), applies `nvidia-tegra-nvgpu/patches/{nvgpu,nvidia-oot}/*.patch`, builds these modules out of tree against the Talos 6.18 kernel with Clang: `host1x`, `mc-utils`, `host1x-fence`, `host1x-nvhost`, `nvhwpm`, `tegra-drm` (headless, no fbdev), `nvmap`, `devfreq` governor, `nvgpu` (with `CONFIG_TEGRA_GK20A_NVHOST*=y`). Modules are signed with a fixed key, which must match the custom kernel (see `scripts/build-extensions.sh`, `BUGS.md` bugs 2, 12). Installer and USB image come from `scripts/build-uki.sh`, `scripts/build-usb-image.sh` and `.github/workflows/`. Userspace: `manifests/gpu/cdi-setup.yaml` downloads r36.5 debs from NVIDIA's apt (`VER="36.5.0-..."`); GPU firmware extension in `.github/workflows/build-extensions.yaml` (r36.5 apt). Current versions: Talos v1.14.0, kernel 6.18.48.
- **Where the DTB comes from.** Not from the image. The SPI-flash DTB (flashed by the Seeed package) is used. Flashing JetPack 7 therefore changes the device tree under Talos.
- **DTB probe result (research finding 7).** Between r36.5 and r39.2.0 for the standard J401 / Orin NX 16 GB: GPU (`nvidia,ga10b`), memory-controller and HWPM nodes are unchanged; `host1x@13e00000` changes (no `actmon` region/clock, new `nvidia,syncpoint-shim` -> `nvidia,tegra234-syncpoint-shim` node at `memory@60000000`). The r39 OE4T/NVIDIA `host1x` (`drivers/gpu/host1x/dev.c`) reads that phandle itself. The r36.5 `host1x` module will most likely not probe on an r39 DTB.
- **Which GPU driver.** For Orin the compute driver in r39 is still `nvgpu` (Orin/tegra234 gets `nvidia-l4t-kernel-nvgpu`: `nvgpu.ko` plus open display modules; OE4T's r39.2.1 recipe builds `compute-nvgpu` for tegra234). OpenRM (`nvidia.ko`, `nvidia-uvm.ko`, installed with `apply_binaries.sh --openrm`) is the Thor path; NVIDIA's notes say nvgpu is not supported on Thor and `--openrm` is what Thor uses. No evidence that OpenRM covers T234/GA10B. So: the open NVIDIA driver is not an option for nv1; the nvgpu stack has to be ported.
- **Sources.** OE4T has no r39 branch of `linux-nvgpu` (only r36.5) and no r39 `linux-nv-oot` (r36.5, r38.x only). The r39.2.1 pins are in OE4T `meta-tegra` `recipes-kernel/nvidia-kernel-oot/nvidia-kernel-oot_39.2.1.bb`, branch `l4t/l4t-r39.2.1` on NVIDIA's gitlab (`gitlab.com/nvidia/nv-tegra/...`): nv-oot `e71bacb7`, hwpm `80b966b1`, nvgpu `fc23d335` (verify these when starting). Seeed's `Linux_for_Tegra` branch `r39.2.0` also has `source/nvidia-oot`, board DTS, flash configs and prebuilt `nvidia-l4t-kernel-nvgpu` debs (useful as a reference build). meta-tegra's r39 recipe already carries Linux 6.18 compatibility patches for nvidia-oot (conftest `__assign_str`, bluetooth, `drm/tegra` PMC power API); reuse the relevant ones.
- **Version skew to avoid.** Seeed's current flash package is r39.2.0; NVIDIA's latest is r39.2.1. The flashed firmware/DTB, the module sources and the userspace libs should all come from one release. Decide in task A1.
- **nv1 constraints.** nv1 is the only GPU node (llama-server, embeddings, Hermes depend on it). Existing ops notes: `docs/src/k8s/nv1-jetson.md` (META DHCP key `0x0a` returns after a reflash, GPU plugin watchdog, memory budget).

## Key decisions (proposed, confirm before starting)

1. Keep r36.5 and r39 buildable side by side in the fork (parallel package dir or version variable), so rollback never needs a rebuild.
2. Stay on one r39 point release (A1) instead of mixing.
3. No hardware flashing until phase A and B are done and green.
4. Develop on a feature branch in the fork (`feat/jetpack7-r39`), upstream-friendly (small commits, patches kept as `.patch` files with a short header).

## Phases and tasks

### Phase A: build-only (no hardware, no cluster impact)

- [ ] A1. Pick the target release: r39.2.0 (matches Seeed's flash package) or r39.2.1. Confirm tags/branches exist for nv-oot, hwpm, nvgpu on NVIDIA's gitlab and which one Seeed's DTS/flash config were built from. Record commit SHAs.
- [ ] A2. Fork housekeeping: sync fork `main` with upstream, create `feat/jetpack7-r39`, add a `docs/jetpack7.md` stub that tracks status.
- [ ] A3. Add an r39 package (e.g. `nvidia-tegra-nvgpu-r39/pkg.yaml`) with tarball URLs and SHA-256/512 for the A1 SHAs. Mirror the structure of `nvidia-tegra-nvgpu/pkg.yaml` (conftest step, `oot()` helper, module list). Include `drivers/gpu/host1x-emu` only if the r39 module set requires it.
- [ ] A4. Rebase the three existing patches onto the r39 trees: `nvgpu/0001-nvhost-syncpt-retry-and-skip-id0`, `nvgpu/0002-netlist-flexible-array`, `nvidia-oot/0001-tegra-drm-headless-no-fbdev`. Drop any that r39 already fixed.
- [ ] A5. Make `host1x`, `mc-utils`, `host1x-fence`, `host1x-nvhost`, `hwpm`, `tegra-drm`, `nvmap`, `devfreq` and `nvgpu` compile against Linux 6.18.48 with Clang. Expect conftest probe failures (see `BUGS.md` bug 24: probes run with `CC=clang`, `-Werror` removed). Pull in meta-tegra's 6.18 patches where they apply. Fail the build if a conftest probe is silently missing.
- [ ] A6. Re-check the DRM/host1x ABI match: `tegra-drm.ko` must come from the same r39 tree as `host1x.ko` and shadow the in-tree ones (as in the r36 package). Re-check `softdep` ordering in `nvidia-tegra.conf` and that r39 does not add a new module dependency (compare against `nvidia-l4t-kernel-nvgpu`'s module list: `nvgpu.ko` plus whatever the r39 nvmap/host1x need).
- [ ] A7. Wire the r39 package into `scripts/build-extensions.sh` and the installer build (selected by a version variable), produce a signed module set and a custom installer image tagged with the JetPack release (e.g. `...-nvgpu<ver>-r39`). CI (`.github/workflows/build-extensions.yaml`, `release.yaml`) builds both r36 and r39.
- [ ] A8. Userspace for CDI: replace the r36.5 apt source in `manifests/gpu/cdi-setup.yaml` and the firmware extension step with r39 equivalents (`t234` component, `nvidia-l4t-firmware` r39, CUDA 13 `libcuda`/`libnvrm_gpu`). Keep it version-switchable. Check which r39 libs are needed (CUDA 13 user-mode driver, `libnvrm_gpu`, `libnvrm_mem`, `libnvos`, ...) by listing the contents of the r39 debs Seeed ships under `kernel/` and the NVIDIA apt repo.
- [ ] A9. Review: module symbol check (`modinfo`, `nm -u` against kernel `Module.symvers`) and signature check for every `.ko`; build log scan for "undefined" and conftest warnings.

Exit gate for phase A: signed r39 module set builds in CI from a clean checkout.

### Phase B: hardware prerequisites (no flashing yet)

- [ ] B1. Get Seeed's r39 flash package for Orin NX 16 GB (standard J401), or build from the `r39.2.0` branch, and a Linux x86 host with USB recovery access. Verify SHA-256.
- [ ] B2. Find a QSPI-only flash procedure for Orin NX with the Seeed DTB: the BSP has `*-qspi.conf` variants (e.g. `p3768-0000-p3767-0000-a0-qspi.conf`), but they use NVIDIA's reference DTB. Work out whether a custom conf can flash QSPI with `tegra234-j401-p3768-0000+p3767-0000-recomputer.dtb` without touching NVMe. If not possible, the plan must assume the NVMe is wiped and Talos is reinstalled.
- [ ] B3. Check the overlay set the r39 flash package applies (carveouts, camera/display overlays) against what nv1 runs now, since `reserved-memory` carveouts come from `tegra234-carveouts.dtbo` and nvgpu/nvmap need them.
- [ ] B4. Decide the test target: a spare Orin module/board if one is acquired, otherwise nv1 itself. If nv1: pick a maintenance window; scale down GPU consumers (llama-server, embeddings; see `cluster/apps/ai/`); cordon and drain nv1; take note of node labels, taints and the machine config (`provision/talos/nodes/nv1.yaml`).
- [ ] B5. Capture the rollback kit: r36.5 Seeed flash package, the current r36 installer/USB image, the live DTB (already saved during research, re-capture before the flash), and the `talosctl` commands to re-register nv1.

### Phase C: hardware bring-up (needs explicit user go-ahead; nv1 downtime)

- [ ] C1. Flash r39 firmware (QSPI only if B2 allows). Boot the r39 USB image in Talos maintenance mode. Capture `dmesg` before applying config.
- [ ] C2. Verify in order: `host1x` probes (no `actmon` errors), `/dev/dri/renderD128` exists, `nvmap`, `nvgpu` probes, `/dev/nvgpu/igpu0/*` exist, firmware loaded (no ACR bootstrap failure).
- [ ] C3. Apply the nv1 machine config with the new installer image, reinstall, re-check the META DHCP key (`talosctl -n 192.168.48.5 get operatorspecs` must be empty).
- [ ] C4. Run the CDI setup with r39 libs. Run a CUDA 13 smoke test (`deviceQuery` or a small llama.cpp build with sm_87) and confirm GPU, not CPU. Compare tok/s with the r36 baseline (`docs/superpowers/plans/artifacts/2026-08-13-nv1-cpu-baseline.md` and the numbers in the research doc).
- [ ] C5. Soak: sustained multi-prompt load for hours, watch kernel logs for nvgpu faults (including the Orin NX 16 GB floorswept-GPC0 SLUB corruption report in research finding 4), memory (`MemAvailable`), and power mode behaviour.
- [ ] C6. Go/no-go. If no-go or unstable: execute the rollback kit (B5).

### Phase D: finish

- [ ] D1. Update the fork README and `docs/jetpack7.md` (versions, supported boards/DTB notes, flash steps).
- [ ] D2. Open an upstream PR or issue to `schwankner/talos-jetson-orin` (upstream issue about r39 was drafted but not posted; the token could not create issues there).
- [ ] D3. In home-ops: bump the installer image in `provision/talos/nodes/nv1.yaml`, switch GPU images to CUDA 13 where wanted, update `docs/src/k8s/nv1-jetson.md` and `.plans/TODO.md`, archive this plan.

## Risks

- nvgpu r39 on Linux 6.18 is a second kernel-API jump with no upstream recipe; NVIDIA's own r39 kernel is 6.8.12.
- The SPI-flash DTB is board-vendor specific. A different carrier board (see research finding 5) means a different DTB; test one board at a time.
- One GPU node: a failed bring-up takes GPU workloads offline until rollback finishes.
- UEFI behaviour after r39 firmware (Bug 25 same-version upgrade quirk, boot order, USB priority) is unverified.
- Licensing: GPU firmware and NVIDIA modules are distributed under NVIDIA licences (see Sidero PR #1518 discussion); keep the existing approach of pulling firmware from NVIDIA's apt.

## Open questions

- Which r39 point release do Seeed's flash package and DTB correspond to, and do the matching gitlab tags exist?
- Can QSPI be flashed alone with the Seeed DTB?
- Does the r39 UEFI still pass its DTB to sd-boot unchanged, and do `LoaderEntryDefault` writes persist?
- Does `nvmap` or `nvgpu` in r39 need modules the r36 package never built?
