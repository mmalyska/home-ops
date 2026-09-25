---
name: reference_nv1_meta_dhcp
description: Talos META key 0x0a on nv1 carried a platform DHCP operator that flapped an extra IP and restarted kubelet, dropping nvidia.com/gpu to 0
metadata:
  type: reference
---

`dhcp: false` in the machine config does not remove a platform-layer DHCP operator stored in Talos META key `0x0a`; nv1 kept acquiring 192.168.48.210, the address flap restarted kubelet, and the Jetson device plugin (advertises one hard-coded GPU unit, never re-registers) left the node at `nvidia.com/gpu: 0`. Fix applied: `talosctl meta delete 0x0a` on nv1 (backup of the value was taken first). Self-heal: the device-plugin watchdog sidecar restarts the plugin when `kubelet.sock` changes, and the `NodeGpuUnavailable` alert fires if GPU allocatable stays 0.

**Why:** recurring `gpu: 0` incidents 2026-09-24/25.
**How to apply:** if GPU allocatable drops to 0 again, check `talosctl -n 192.168.48.5 get addresses` for a second address and `dmesg` for kubelet restarts before restarting the plugin. Runbook: `docs/src/k8s/nv1-jetson.md`. See [[reference_llama_server_nv1_memory]].
