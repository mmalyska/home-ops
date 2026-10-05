# What:   Installer image: Image Factory schematic with kernel arguments only (no extensions), at the Talos version
# Why:    Default worker image; nv1 overrides it with its custom installer (node/nv1/20-install-image.yaml)
# Nodes:  workers
# Apply:  install-only
machine:
  install:
    image: factory.talos.dev/metal-installer/185266ddb5b9bb403289377302af1fd44575fe7f2864db5a7a96858837ccbcba:${TALOS_VERSION}
