---
name: talosctl talosconfig location
description: Always use TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig with talosctl
type: feedback
---

Always use `TALOSCONFIG=/workspaces/home-ops/provision/talos/clusterconfig/talosconfig` with talosctl commands. The config is NOT in `~/.talos/config`.

**Why:** The workspace config is the authoritative one for this cluster; the home-dir path doesn't exist in this devcontainer.

**How to apply:** Prefix all talosctl commands with the env var, or set it at the start of any talosctl-heavy session.
