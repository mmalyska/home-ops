---
name: Local cluster access from devcontainer
description: Permission rules and CLI details for kubectl, talosctl, terraform, argocd inside the devcontainer
type: reference
---

**Permission Rules:**
- Read-only operations: run freely
- Mutating operations (apply/delete/create/update/destroy/taint/upgrade/restart): ALWAYS confirm with user first

### kubectl
- kubeconfig: `~/.kube/config`
- Safe: `get`, `describe`, `logs`, `top`, `diff`
- Confirm first: `apply`, `delete`, `patch`, `rollout restart`, `exec`

### talosctl
- Binary: `/usr/local/bin/talosctl`; TALOSCONFIG set via `.envrc`
- Nodes: mc1=192.168.48.2, mc2=192.168.48.3, mc3=192.168.48.4
- Safe: `get`, `health`, `logs`, `version`, `dmesg`, `ps`, `services`, `disks`, `memory`, `cpu`
- Confirm first: `apply-config`, `upgrade`, `reset`, `reboot`, `shutdown`

### terraform
- Working dir: `provision/terraform/cloudflare/`; run `task terraform:init:cloudflare` first
- Safe: `show`, `plan`, `state list`, `state show`
- Confirm first: `apply`, `destroy`, `taint`, `import`

### argocd
- Login first: `task argocd:login`
- Safe: `app list`, `app get`, `app diff`, `proj list`
- Confirm first: `app sync`, `app delete`, `app set`
