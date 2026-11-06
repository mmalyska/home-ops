# What:   Installer image: Image Factory schematic with kernel arguments only (no extensions), at the Talos version; install disk /dev/nvme0n1
# Why:    Default worker image; nv1 overrides it with its custom installer (node/nv1/20-install-image.yaml.tpl).
#         The disk selector comes from all/30-install.yaml (Talos 1.14.5 or newer keeps it when this patch merges in).
# Nodes:  workers
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/185266ddb5b9bb403289377302af1fd44575fe7f2864db5a7a96858837ccbcba:${TALOS_VERSION}
