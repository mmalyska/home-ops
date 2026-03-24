---
name: Network Hardware Reference
description: Physical hardware details for home network devices (router, NAS, RPi)
type: reference
---

## ISP Connection

- **ONT** (Optical Network Terminal) — fiber from ISP, 1 GbE WAN uplink to router

## Router

- **Model**: ASUS RT-AX58U
- **Firmware**: Asuswrt-Merlin (custom firmware, not stock ASUS)
- **IP**: 192.168.50.1 (gateway)

## NAS

- **Model**: QNAP TS-251D
- **RAM**: 8 GB
- **PCIe card**: QM2-2P10G1TA (dual M.2 NVMe + 10GbE port)
- **IP**: 192.168.50.8
- **Role**: NFS cold storage + S3 storage for the cluster

## Raspberry Pi

- **IP**: 192.168.50.9
- **OS**: Home Assistant OS (HAOS) — full HAOS install, not just a proxy
- **Role**: Home Assistant (home automation hub); AdGuard Home runs as a **HA addon**
