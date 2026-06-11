---
name: talos-ethernet-config
description: >
  EthernetConfig is a separate top-level Talos machine config document, not a
  nested field under machine.network.interfaces. Use when configuring NIC ring
  buffers, channels, or features on Talos nodes.
when_to_use: >
  Trigger phrases: "ring buffer", "NIC tuning", "ethtool", "EthernetConfig",
  "packet drops", "e1000e", "NIC configuration", "ethernet rings".
---

# Talos EthernetConfig

## The Trap

`ethernetConfig` does **not** nest under `machine.network.interfaces[]`. This fails:

```yaml
# WRONG — causes "unknown keys found during decoding"
machine:
  network:
    interfaces:
      - interface: eth0
        ethernetConfig:       # ← does not exist here
          rings:
            rx: 4096
```

## Correct Format

`EthernetConfig` is a **standalone document** appended after the main `v1alpha1` doc:

```yaml
---
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
  tx: 4096
```

## Repo Pattern

Add a template file and append it in the `generate` task — same pattern as `extension-nut-client.yaml`:

1. Create `provision/talos/templates/ethernet-rings.yaml`:

```yaml
---
apiVersion: v1alpha1
kind: EthernetConfig
name: eth0
rings:
  rx: 4096
  tx: 4096
```

2. Append it in `.taskfiles/talos/Taskfile.yaml` for controlplane nodes:

```bash
envsubst < templates/extension-nut-client.yaml >> /tmp/talos-patched.yaml
cat templates/ethernet-rings.yaml >> /tmp/talos-patched.yaml   # ← add this line
mv /tmp/talos-patched.yaml clusterconfig/home-{{.ITEM}}.yaml
```

## Check Supported Values First

Before setting ring sizes, verify hardware limits:

```bash
TALOSCONFIG=provision/talos/clusterconfig/talosconfig
talosctl -n <node-ip> --talosconfig $TALOSCONFIG get ethernetstatus eth0 -o yaml \
  | grep -A 6 "rings:"
```

Look for `rx-max` and `tx-max`. The Intel I219-LM (e1000e) on Lenovo M720q supports `rx-max: 4096, tx-max: 4096` with a default of 256.

## Other EthernetConfig Fields

| Field | ethtool equivalent | Purpose |
|-------|-------------------|---------|
| `rings.rx` / `rings.tx` | `ethtool -G` | Ring buffer size |
| `channels` | `ethtool -L` | RX/TX channel count |
| `features` | `ethtool -K` | Driver feature flags |
| `wakeOnLAN` | `ethtool -s wol` | Wake-on-LAN modes |
