# What:   Custom installer image (OE4T nvgpu kernel modules for the Jetson Orin NX); install disk /dev/nvme0n1
# Why:    JetPack 7 (Jetson Linux r39.2, CUDA 13). The Jetson GPU needs the matching kernel and out-of-tree modules. The image is our own build of the fork
#         mmalyska/talos-jetson-orin (upstream: schwankner/talos-jetson-orin). The JetPack 7 installer has its own repository,
#         ghcr.io/mmalyska/custom-installer-jp7 (the r36 line stays in custom-installer); the package must stay public
#         because nv1 pulls it anonymously.
#         The tag is the plain Talos version (v<talos>, TALOS_VERSION), an alias that the fork pushes next to the compound tag
#         <talos>-<kernel>-nvgpu39.2.1-jp7 of the same image, so tuppr can swap the tag; the kernel module ABI must match the image (see provision/talos/README.md).
#         The disk selector (CEL) is repeated in every file that sets the installer image (controlplane/05, worker/05,
#         node/nv1/20): the last patch applied for a node must carry it, because talosctl machineconfig patch drops
#         provisioning.diskSelector.match when a later patch
#         merges into the document; `talosctl validate` fails with "provisioning.diskSelector.match is required" if it is lost
# Nodes:  nv1
# Apply:  install-only
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: ghcr.io/mmalyska/custom-installer-jp7:${TALOS_VERSION}
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/nvme0n1"
