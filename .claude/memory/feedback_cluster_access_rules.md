---
name: Local cluster access permission rules
description: Read-only ops run freely; mutating ops always confirm with user first
type: feedback
---

**kubectl** — safe (run freely): `get`, `describe`, `logs`, `top`, `diff`; confirm first: `apply`, `delete`, `patch`, `rollout restart`, `exec`

**talosctl** (nodes: mc1=.2, mc2=.3, mc3=.4) — safe: `get`, `health`, `logs`, `version`, `dmesg`, `ps`, `services`, `disks`; confirm: `apply-config`, `upgrade`, `reset`, `reboot`, `shutdown`

**terraform** (dir: `provision/terraform/cloudflare/`) — safe: `show`, `plan`, `state`; confirm: `apply`, `destroy`, `taint`, `import`

**argocd** — safe: `app list`, `get`, `diff`; confirm: `app sync`, `delete`, `set`

**Why:** Mutating cluster state can cause service disruption; user must always be aware of what's changing.

**How to apply:** Before any mutating command, state the action and ask for confirmation even if the context seems obvious.
