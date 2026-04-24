---
name: Home network hardware
description: Router, NAS, and RPi hardware details and IPs
type: reference
---

- **Router:** ASUS RT-AX58U with Asuswrt-Merlin firmware, IP `192.168.50.1`
- **NAS:** QNAP TS-251D, 8GB RAM, QM2-2P10G1TA PCIe (dual M.2 NVMe + 10GbE), IP `192.168.50.8` — role: NFS cold storage + S3 for cluster
- **RPi:** IP `192.168.50.9`, Home Assistant OS (HAOS) full install, AdGuard Home runs as HA addon
