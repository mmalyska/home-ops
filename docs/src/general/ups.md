# UPS & Power Management

A **CyberPower CP1350EPFCLCD** (1350VA/810W, AVR) protects all critical devices: router, switch, RPi, all 3 k8s nodes, and QNAP NAS.

The UPS is connected via USB to the RPi, which runs the **NUT Server** Home Assistant addon as the NUT master. The k8s nodes and QNAP act as NUT clients (slaves) and shut down gracefully on battery-low events.

| Role | Device |
|------|--------|
| NUT master (USB) | RPi — HAOS NUT Server addon |
| NUT slave | mc1, mc2, mc3 (k8s nodes) |
| NUT slave | QNAP TS-251D |

```mermaid
flowchart TB
    UPS[CyberPower CP1350EPFCLCD\n1350VA/810W, AVR]

    subgraph powered[Protected devices]
        Router[ASUS RT-AX58U\n192.168.50.1]
        Switch[NETGEAR GS108GE]
        RPi[Raspberry Pi 4B\n192.168.50.9\nNUT master]
        QNAP[QNAP TS-251D\n192.168.50.8\nNUT slave]

        subgraph K8S[Home Cluster]
            mc1[mc1\nNUT slave]
            mc2[mc2\nNUT slave]
            mc3[mc3\nNUT slave]
        end
    end

    UPS -->|Schuko| Router
    UPS -->|Schuko| Switch
    UPS -->|Schuko| RPi
    UPS -->|Schuko| QNAP
    UPS -->|Schuko| mc1
    UPS -->|Schuko| mc2
    UPS -->|Schuko| mc3
    UPS -->|USB monitor| RPi

    RPi -->|NUT notify| QNAP
    RPi -->|NUT notify| mc1
    RPi -->|NUT notify| mc2
    RPi -->|NUT notify| mc3
```
