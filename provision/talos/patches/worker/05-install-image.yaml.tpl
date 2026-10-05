# What:   Installer image: Image Factory schematic with kernel arguments only (no extensions), at the Talos version; install disk /dev/nvme0n1
# Why:    Default worker image; nv1 overrides it with its custom installer (node/nv1/20-install-image.yaml).
#         The disk selector (CEL) is repeated in every file that is applied last for a node (controlplane/05, worker/05,
#         node/nv1/20) because talosctl machineconfig patch drops provisioning.diskSelector.match when a later patch
#         merges into the document; `talosctl validate` fails with "provisioning.diskSelector.match is required" if it is lost
# Nodes:  workers
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/185266ddb5b9bb403289377302af1fd44575fe7f2864db5a7a96858837ccbcba:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
