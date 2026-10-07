# Talos Install Document (`UnattendedInstallConfig`) — Design

## Context

Talos 1.14 deprecates `machine.install` in favour of the `UnattendedInstallConfig`
document (`talosctl gen config` already generates it by default for new
clusters). This is the last Tier 2 item in `.plans/TODO.md`. The legacy block
keeps working, so this is cleanup, but the document also makes a reinstall
simpler: a node booted from USB or PXE in maintenance mode that is given a
config containing it installs itself, without a separate `talosctl install`.

Read the layered layout spec first (`2026-10-05-talos-config-layout-design.md`):
patch files in `provision/talos/patches/`, one document per file, `.yaml.tpl`
for files with variables, `$patch: delete` for blocks the generated base adds.

### Current state (verified 2026-10-05)

- `all/30-install.yaml`: `machine.install` with `disk: /dev/nvme0n1`,
  `wipe: false`, `grubUseUKICmdline: true`.
- The image is set per role and per node:
  `controlplane/05-install-image.yaml.tpl` and `worker/05-install-image.yaml.tpl`
  (Image Factory schematics at `${TALOS_VERSION}`), `node/nv1/20-install-image.yaml`
  (custom installer `ghcr.io/schwankner/custom-installer:v1.14.0-...`).
- Three readers use `machine.install.image` from the rendered config:
  `expected_version` in `scripts/lib.sh` (so `scripts/expected-version.sh`), the
  `upgrade` task in `.taskfiles/talos/Taskfile.yaml` (`TALOS_IMAGE`), and the
  README and skill text. Tests with fixtures for it, which fail when the field
  moves: `tests/test_lib.sh` and `tests/test_diff_live.sh`.
- All four nodes boot with UKI (`talosctl get securitystate`:
  `bootedWithUKI: true`, `secureBoot: false`), so grub is not involved.

### What the sources say

(Talos v1.14.2 `pkg/machinery/config/types/runtime/unattended_install.go` and
`internal/app/machined/pkg/controllers/runtime/unattended_install.go`; tuppr
`internal/talos/machineconfig.go`, read 2026-10-05.)

- **Installed nodes ignore the document.** The controller checks "already
  installed" first and only reports `installed`. The document acts on a node
  that is not installed yet. For our four installed nodes it only names the
  installer image that upgrades use.
- **Fields:** `installer.image`, `reboot` (unset: reboot after install only if an
  explicit image is set), `provisioning.diskSelector.match` (a required CEL
  expression, `disk.dev_path == "/dev/sda"` style) and `provisioning.wipe`,
  which **defaults to true**. There is no counterpart for `grubUseUKICmdline`,
  `extraKernelArgs`, `extensions`, `bootloader` (the last three are already
  deprecated in the legacy block; the Image Factory schematic carries them).
- Talos refuses the document next to a legacy `machine.install`.
- **tuppr supports both.** Its reader prefers `UnattendedInstallConfig`
  `installer.image` and falls back to `.machine.install.image`; its patcher edits
  whichever exists. It upgrades by version-swapping the node's current install
  image, which does not fit nv1's custom tag (`v1.14.0-6.18.48-nvgpu...`): nv1
  must be excluded or pinned when tuppr arrives (already known).
- **`talosctl machineconfig patch` loses the CEL expression on a merge.** When a
  later patch merges into a document whose base holds
  `provisioning.diskSelector.match`, the result has no `match`. It survives in the
  last patch applied. Reproduced with plain files outside the repo; `talosctl
validate` then fails with `provisioning.diskSelector.match is required`, so a
  loss cannot go unnoticed.

## Decisions

1. **Migrate now.** The document is inert on installed nodes, tuppr supports it,
   and it improves reinstalls.
2. **`wipe: false`, written explicitly** (the default is true). A wipe stays a
   deliberate manual step, as today.
3. **Disk selector** `disk.dev_path == "/dev/nvme0n1"`, the same disk as the legacy
   `disk`.
4. **`grubUseUKICmdline` is dropped** (UKI nodes).
5. **`reboot` is left unset.**

## Design

- `all/30-install.yaml` becomes an `UnattendedInstallConfig` document with
  `provisioning.wipe: false` only (it merges safely).
- `controlplane/05-install-image.yaml.tpl`, `worker/05-install-image.yaml.tpl` and
  `node/nv1/20-install-image.yaml` each carry `installer.image` **and**
  `provisioning.diskSelector.match`. The `match` line is repeated on purpose: these
  are the last patches applied for their nodes, so the expression survives the
  merge (verified: all four render with it). Each header says why.
- `all/31-install-legacy-delete.yaml` deletes the generated `machine.install`
  block (`$patch: delete`).
- Readers: `expected_version` and the `upgrade` task read
  `select(.kind == "UnattendedInstallConfig") | .installer.image`; their test
  fixtures are changed first (RED) and then the readers (GREEN).
- Docs: the README, the `talos-config-editing` skill (including a note about the
  merge limitation and the explicit `wipe`) and `.plans/TODO.md`.
- `render.sh` tests: add an assertion that every node renders a
  `provisioning.diskSelector.match` and `wipe: false` (a guard next to the
  `talosctl validate` that already fails without `match`).

### Rollout

The change is `install-only`: applying it restarts nothing. Dry run says no reboot
(verified for mc1 and nv1). Apply one node at a time, mc1 first, with the live
reads below; `task talos:apply` is enough (the health gate does not depend on this
document).

Per node, before and after:

| Check                                                           | Expectation                                                                            |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `task talos:diff -- <node>` before                              | only the `machine.install` block becoming the document                                 |
| `talosctl get machineconfig v1alpha1 -n <ip>` after             | the `UnattendedInstallConfig` document with the right image, `match` and `wipe: false` |
| `scripts/expected-version.sh` on the rendered file              | `v1.14.2` (mc), `v1.14.0` (nv1)                                                        |
| `talosctl get unattendedinstallstatus` (if the resource exists) | phase `installed`                                                                      |
| node Ready, pods, `task talos:diff` after                       | no differences                                                                         |
| `task talos:upgrade N=<node>`                                   | reports "up to date" (reads the image from the new document)                           |

### Rollback

Revert the PR, render, and `task talos:apply` (or `talosctl apply-config`
directly). The legacy block is accepted by Talos 1.14 for the legacy contract.

## Risks

| Risk                                            | Effect                                                            | Mitigation                                                                               |
| ----------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| The CEL expression is lost by a later merge     | `validate` fails ("match is required")                            | Repeated in the last patch per node; render test guard; `talosctl validate` in the tests |
| Tooling still reads the legacy field            | `upgrade` or `expected-version` misreport                         | Readers and fixtures changed with RED then GREEN; Rollout check on `task talos:upgrade`  |
| A node boots into maintenance mode and installs | With `wipe: false` and the selector the disk is reused, not wiped | Explicit `wipe: false`                                                                   |
| tuppr and nv1's custom tag                      | tuppr would version-swap a non-version tag                        | Out of scope here; nv1 is excluded or pinned when tuppr arrives                          |
| Unattended reinstall is untested                | A real reinstall may need a step not covered here                 | Documented as "untested"; try it on the first real reinstall                             |

## Out of scope

- Reinstalling a node, tuppr, a Talos or Kubernetes upgrade.
- The nv1 `containerd.toml` overwrite, `FilesystemTrimConfig`, the remaining
  network config and Tier 3.
- Reporting the merge limitation upstream (worth doing, separately).

## Open items for the implementation plan

- Check whether `talosctl get unattendedinstallstatus` exists on 1.14.2 for the
  live check.
- Add the reinstall note (maintenance mode plus config) to the README as
  "expected, untested".
