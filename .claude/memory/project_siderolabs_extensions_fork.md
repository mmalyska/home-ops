---
name: mmalyska/siderolabs-extensions fork
description: Details on the extensions fork for the nvgpu Talos system extension
type: project
---

`mmalyska/siderolabs-extensions` fork, branch `feat/jetson-nvgpu`, local: `/tmp/mmalyska-extensions/`.

Adds `nvgpu` system extension consuming `nvgpu-driver-pkg` from the pkgs fork.

**Key files:**
- `nvidia-gpu/nvgpu/pkg.yaml` — extension definition
- `.github/workflows/nvgpu.yaml` — custom CI: builds nvgpu extension for `linux/arm64`, runs `siderolabs/imager` installer with `--system-extension-image` to produce `installer-arm64.tar`, crane pushes to `ghcr.io/mmalyska/talos-nv1-installer:v1.12.6`

**CI produces:** `ghcr.io/mmalyska/talos-nv1-installer:v1.12.6` (docker schema v2, single-arch arm64)

**nv1 talconfig:** `/workspaces/home-ops/provision/talos/talconfig.yaml` uses `install.image: ghcr.io/mmalyska/talos-nv1-installer:v1.12.6`

**Why:** The extensions fork bundles the nvgpu driver into a Talos installer image for nv1.

**How to apply:** When updating Talos version for nv1, update the installer image tag here.
