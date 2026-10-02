---
name: Home network hardware
description: Router, NAS, and RPi hardware details and IPs
type: reference
---

- **Router:** ASUS RT-AX58U with Asuswrt-Merlin firmware, IP `192.168.50.1`
- **NAS:** QNAP TS-251D, 8GB RAM, QM2-2P10G1TA PCIe (dual M.2 NVMe + 10GbE), IP `192.168.50.8` — role: NFS cold storage + S3 for cluster
- **RPi:** IP `192.168.50.9`, Home Assistant OS (HAOS) full install, AdGuard Home runs as HA addon
- **Migration status (2026-10-02):** MQTT (RabbitMQ, LB `192.168.48.26`) and Zigbee2MQTT already run in the cluster; the RPi's Mosquitto and Z2M addons are stopped. SLZB-MR4U Zigbee/Thread coordinator at `192.168.50.239` (Z2M socket port 7638). Matter, Music Assistant, AdGuard and HA still on the RPi. Plan: docs/superpowers/plans/2026-10-01-rpi-decommission.md
