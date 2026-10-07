# What:   Installer image: Image Factory schematic with the i915, intel-ucode and nut-client extensions, at the Talos version; install disk /dev/nvme0n1
# Why:    Control-plane nodes are Lenovo M720q with Intel GPUs and a UPS; the version tag follows TALOS_VERSION.
#         The disk selector (CEL) is repeated in every file that sets the installer image (controlplane/05, worker/05,
#         node/nv1/20): the last patch applied for a node must carry it, because talosctl machineconfig patch drops
#         provisioning.diskSelector.match when a later patch
#         merges into the document; `talosctl validate` fails with "provisioning.diskSelector.match is required" if it is lost
# Nodes:  control plane
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
