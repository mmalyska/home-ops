# What:   Installer image: Image Factory schematic with the i915, intel-ucode and nut-client extensions, at the Talos version; install disk /dev/nvme0n1
# Why:    Control-plane nodes are Lenovo M720q with Intel GPUs and a UPS; the version tag follows TALOS_VERSION.
#         The disk selector comes from all/30-install.yaml (Talos 1.14.5 or newer keeps it when this patch merges in).
# Nodes:  control plane
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0:${TALOS_VERSION}
