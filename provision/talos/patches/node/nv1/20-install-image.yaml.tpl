# What:   Custom installer image (OE4T nvgpu kernel modules for the Jetson Orin NX); install disk /dev/nvme0n1
# Why:    JetPack 7 (Jetson Linux r39.2, CUDA 13). The Jetson GPU needs the matching kernel and out-of-tree modules. The image is our own build of the fork
#         mmalyska/talos-jetson-orin (upstream: schwankner/talos-jetson-orin). The JetPack 7 installer has its own repository,
#         ghcr.io/mmalyska/custom-installer-jp7 (the r36 line stays in custom-installer); the package must stay public
#         because nv1 pulls it anonymously.
#         The tag is the plain Talos version (v<talos>, TALOS_VERSION), an alias that the fork pushes next to the compound tag
#         <talos>-<kernel>-nvgpu39.2.1-jp7 of the same image, so tuppr can swap the tag; the kernel module ABI must match the image (see provision/talos/README.md).
#         The disk selector comes from all/30-install.yaml (Talos 1.14.5 or newer keeps it when this patch merges in).
# Nodes:  nv1
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/mmalyska/custom-installer-jp7:${TALOS_VERSION}
