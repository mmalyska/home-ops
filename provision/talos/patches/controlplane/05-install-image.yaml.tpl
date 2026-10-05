# What:   Installer image: Image Factory schematic with the i915, intel-ucode and nut-client extensions, at the Talos version
# Why:    Control-plane nodes are Lenovo M720q with Intel GPUs and a UPS; the version tag follows TALOS_VERSION
# Nodes:  control plane
# Apply:  install-only
machine:
  install:
    image: factory.talos.dev/metal-installer/a586a5113bc834fd711beb77c98fb6f407c824fa3ab2f1cdf2940840b6e807f0:${TALOS_VERSION}
