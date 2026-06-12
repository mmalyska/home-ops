---
name: talos-node-removal
description: Use when removing, replacing, or decommissioning a Talos node — covers the correct talosctl reset workflow
user-invocable: false
origin: auto-extracted
---

# Talos Node Removal

**Extracted:** 2026-06-12
**Context:** Removing a control plane or worker node (hardware replacement, decommission, OS reinstall)

## Problem

Manual node removal requires 4+ steps in the correct order (cordon → drain → etcd remove-member → kubectl delete → shutdown). Wrong order risks etcd split-brain or the node failing to rejoin after reinstall.

## Solution

`talosctl reset` handles everything automatically — cordons, drains, leaves etcd, erases disk, powers off:

```bash
# Step 1: Reset the node (handles cordon/drain/etcd-leave/erase/shutdown)
talosctl -n <node-ip> reset

# Step 2: Remove the Kubernetes node object (reset does NOT do this)
kubectl delete node <node-name>
```

The machine is powered off after reset. To reinstall (e.g. after hardware swap):

```bash
# Verify cluster version before applying
talosctl version -n <other-node-ip>

# Boot from Talos ISO, apply existing machine config
talosctl apply-config --insecure -n <node-ip> \
  -f provision/talos/clusterconfig/<node>.yaml
```

Talos installs onto the new disk and rejoins etcd automatically. No uncordon needed — nodes join uncordoned.

## When to Use

- NVMe/disk replacement requiring power-off
- Node decommission
- OS reinstall or Talos version migration on a single node

## Key Constraint

etcd requires 2/3 quorum — never reset two control plane nodes simultaneously.

## Reference

Official docs: https://docs.siderolabs.com/talos/v1.13/deploy-and-manage-workloads/scaling-down
