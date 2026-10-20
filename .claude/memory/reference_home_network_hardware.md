---
name: Home network hardware
description: Router and NAS hardware details and IPs; the RPi that used to run HA is retired
type: reference
---

- **Router:** ASUS RT-AX58U with Asuswrt-Merlin firmware, IP `192.168.50.1`
- **NAS:** QNAP TS-251D, 8GB RAM, QM2-2P10G1TA PCIe (dual M.2 NVMe + 10GbE), IP `192.168.50.8` — role: NFS cold storage + S3 for cluster
- **RPi (retired):** was `192.168.50.9`, HAOS running Home Assistant, AdGuard Home, Mosquitto, Z2M, Matter and Music Assistant. Everything moved to the cluster 2026-10-02 to 2026-10-04, the RPi was stopped 2026-10-04 and retired after the retention window ended 2026-10-17 (nothing used it). `192.168.50.9` is free.
- **Where its services run now:** MQTT (Mosquitto, LB `192.168.48.26`), Zigbee2MQTT, Matter (macvlan `192.168.48.61`), Music Assistant (`.62`), HA (`hass.<domain>`), AdGuard Home (two instances at `192.168.48.25`/`.31`, DHCP on all VLANs points at them). SLZB-MR4U Zigbee/Thread coordinator at `192.168.50.239` (Z2M socket port 7638).
- **UPS:** the UPS USB is on the QNAP, served over NUT as `qnapups@192.168.50.8` (allow list = node IPs `192.168.48.2-5`); Talos nodes' `TALHELPER_UPSMON*` (Bitwarden) point at it.
