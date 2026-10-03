---
name: Home network hardware
description: Router, NAS, and RPi hardware details and IPs
type: reference
---

- **Router:** ASUS RT-AX58U with Asuswrt-Merlin firmware, IP `192.168.50.1`
- **NAS:** QNAP TS-251D, 8GB RAM, QM2-2P10G1TA PCIe (dual M.2 NVMe + 10GbE), IP `192.168.50.8` — role: NFS cold storage + S3 for cluster
- **RPi:** IP `192.168.50.9`, Home Assistant OS (HAOS) full install, AdGuard Home runs as HA addon
- **Migration status (2026-10-02):** MQTT (RabbitMQ, LB `192.168.48.26`) and Zigbee2MQTT already run in the cluster; the RPi's Mosquitto and Z2M addons are stopped. SLZB-MR4U Zigbee/Thread coordinator at `192.168.50.239` (Z2M socket port 7638). Matter and Music Assistant also moved (2026-10-02). AdGuard moved 2026-10-03: two in-cluster instances at `192.168.48.25`/`.31` (IPv6 `fd80:c04a:5687:48::25`/`::31`), DHCP on all VLANs points at them; the RPi's AdGuard (web on port 8812) is only still queried by a few VLAN 10 clients. HA moved too (cutover 2026-10-04, `hass.<domain>`); the RPi is stopped and kept until 2026-10-17. **Open item before retiring it:** the Talos nodes' NUT client monitors `qnapups@192.168.50.9`, i.e. the RPi's NUT server (UPS USB is on the RPi), which is down now; node UPS shutdown and HA's UPS sensors/automation need a new NUT source. Plan: docs/superpowers/plans/2026-10-01-rpi-decommission.md
