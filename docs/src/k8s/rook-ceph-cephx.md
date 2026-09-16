# Rook-Ceph CephX Key Ciphers

Ceph reports several permanent `HEALTH_WARN` checks about "insecure key types".
They are muted in `cluster/apps/core/rook-ceph/cluster/values.yaml`. This page
explains why, and what has to be true before they can be unmuted.

**Short version:** the Ceph CSI keys must keep using the older `aes` cipher
because `aes256k` requires Linux kernel 7.0+ in the RBD/CephFS client, and no
Talos release ships one. Everything else follows from that.

## Background

Ceph tentacle (v20.2.x) added a stronger CephX key cipher, `aes256k`, and health
checks that flag the older `aes` as insecure. This arrived here with the
rook-ceph v1.20.7 suite upgrade, which also moved the cluster to Ceph v20.2.4.

The change is tied to **CVE-2025-30156**, which affects all Ceph clusters. Rook's
remediation is: run Rook ≥ v1.20.6, Ceph ≥ v20.2.4, and rotate the daemon keys.
All three are done — see [Current state](#current-state).

Cipher support arrived in:

| Component | Minimum version | Ours |
|---|---|---|
| Ceph | v20.2.4 (tentacle) | v20.2.4 ✅ |
| Rook | v1.20.5 | v1.20.7 ✅ |
| ceph-csi (for `aes256k` CSI keys) | **v3.17.1** | v3.17.0 ❌ |
| Linux kernel (for `aes256k` kernel mounts) | **7.0** | 6.18.42 ❌ |

## The split that matters

`spec.security.cephx` has separate sections, and they cannot be treated alike.

### Daemon keys — moved to `aes256k`

`osd`, `mds`, `mgr`, plus `admin`, `crash` and `ceph-exporter`. These are
userspace Ceph processes with no kernel client involved, so they take the
stronger cipher safely. Rotating them is what cleared
`AUTH_INSECURE_SERVICE_KEY_TYPE` — the only `[ERR]` check, and the reason the
cluster briefly reported `HEALTH_ERR`.

Two non-obvious points:

- **`keyType` alone does nothing.** Per the CRD, with `keyRotationPolicy`
  `Disabled` or unspecified, changing `keyType` never initiates rotation. The
  policy and a `keyGeneration` bump are what actually rotate keys.
- **Do not set `daemon.keyType`.** The Rook docs say "Rook automatically detects
  the best CephX key type for daemon keys. Do not set this unless required to
  work around an issue." It selects `aes256k` on its own; the operator log
  confirms it.

### CSI keys — must stay on `aes`

`client.csi-rbd-node`, `client.csi-rbd-provisioner`, `client.csi-cephfs-node`,
`client.csi-cephfs-provisioner`.

These are used by the **kernel** RBD and CephFS clients when mounting PVCs.
`aes256k` needs kernel 7.0+. Forcing it on a 6.x kernel breaks every kernel
mount and takes out all PVCs. The Rook chart's own default carries the comment
*"required when Kubernetes nodes don't run Linux kernel 7.0+"*.

`csi.keyType: aes` is set **explicitly** rather than left to the chart default,
following Rook's advice to "always set the desired `spec.security.cephx.csi.keyType`
to guarantee the key type can be supported by kernel mounts". A future chart
default flipping to `aes256k` would otherwise break storage silently.

### `allowedCiphers` — deliberately unset

Maps to Ceph's `auth_allowed_ciphers`. The CRD warns it "can disrupt cluster
availability". Restricting it to `aes256k` would lock out the CSI clients above,
which is an immediate storage outage. It stays unset until CSI can move.

## The muted warnings

All four trace to the single fact that CSI keys must remain on `aes`.

| Check | Why it fires | Muted |
|---|---|---|
| `AUTH_INSECURE_CLIENT_KEY_TYPE` | the 4 `csi-*` keys, plus `client.rbd-mirror-peer` | yes |
| `AUTH_INSECURE_KEYS_ALLOWED` | mons must keep accepting `aes` for those clients | yes |
| `AUTH_INSECURE_KEYS_CREATABLE` | same | yes |
| `AUTH_EMERGENCY_CIPHERS_SET` | Rook sets `mon-auth-emergency-allowed-ciphers="aes,aes256k"` so mixed-cipher operation works | yes |

Rook's documentation sanctions this directly:

> It is expected that Rook clusters will have constraints that prevent immediate
> resolution of all warnings. Warnings that cannot be resolved immediately can be
> ignored safely.

`AUTH_EMERGENCY_CIPHERS_SET` is **not** in Rook's documented mute list. It is
muted here anyway because muting the other three without it changes nothing —
Ceph stays `HEALTH_WARN` and the ArgoCD app stays `Degraded`, so the exercise
would be pointless. The check reports a state Rook itself configured and this
cluster requires.

The real cost of leaving them unmuted is that a permanent `HEALTH_WARN` trains
everyone to ignore Ceph's health, so a genuine problem looks identical to this
known one.

### Not muted, on purpose

`AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE` is left visible. Rook documents that
rotating service tokens keep the old cipher for **two to three hours** after
daemon migration, then clear on their own. Observed here: present 1h22m after
rotation, gone by 3h41m. Muting it would hide a real transient signal.

## Current state

```yaml
# cluster/apps/core/rook-ceph/cluster/values.yaml
security:
  cephx:
    csi:
      keyType: aes            # kernel-bound, explicit on purpose
    daemon:
      keyRotationPolicy: KeyGeneration
      keyGeneration: 1        # bump to rotate daemon keys again
```

CVE-2025-30156 is remediated: Rook v1.20.7, Ceph v20.2.4, daemon keys rotated.
`AUTH_INSECURE_SERVICE_KEY_TYPE` is gone. Ceph reports `HEALTH_OK` with the four
warnings muted.

## Unmuting — the gate and the procedure

**Gate:** all nodes on Linux kernel 7.0+ **and** ceph-csi ≥ v3.17.1.

Talos tracks the 6.18 **longterm** kernel branch, not latest stable. As of
2026-09, Linux 7.2.x is stable but 6.18.x is the LTS, and no Talos release —
including v1.15 alphas — ships a 7.x kernel. This is a "revisit in months, not
weeks" item, tracked in `.plans/TODO.md`.

Check the gate with:

```sh
kubectl get nodes -o custom-columns='NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion'
kubectl -n rook-ceph get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | grep cephcsi | sort -u
```

When both clear, follow Rook's *Migrating CSI keys to a new key type*:

1. Confirm every node kernel supports `aes256k`.
2. Rotate CSI keys with `keepPriorKeyCountMax: 1` so in-use keys stay active:

    ```yaml
    csi:
      keyRotationPolicy: KeyGeneration
      keyGeneration: 2       # higher than current
      keepPriorKeyCountMax: 1
      keyType: aes256k
    ```

3. Watch `status.cephx.csi.keyGeneration` until rotation completes.
4. New PVC mounts use the new keys; existing mounts keep the old ones.
5. Cordon, drain, optionally reboot, and uncordon each node in turn so pods
   remount with the new keys.
6. Once all nodes are rehydrated, set `keepPriorKeyCountMax: 0` to drop old keys.
7. Restrict `allowedCiphers` to `aes256k`.
8. Flip the four `muteHealthWarning` entries to `policy: unmute`, so stray `aes`
   keys become visible again.

If anything breaks mid-migration, Rook documents reverting to `aes`.

## References

- [Rook: CephX Keys and Rotation](https://rook.io/docs/rook/latest/Storage-Configuration/Advanced/cephx-key-rotation/)
- [Rook: CephCluster CRD — health settings](https://rook.io/docs/rook/latest/CRDs/Cluster/ceph-cluster-crd/#health-settings)
- CVE-2025-30156
