# What:   Kubelet: rotate serving certificates, default seccomp profile, pinned cluster DNS, kubelet image at the Kubernetes version
# Why:    kubelet-csr-approver signs the rotated serving certificates; CoreDNS is self-provisioned
#         (cluster.coreDNS.disabled), so the kube-dns Service address is pinned. The document needs the image
#         explicitly (without it Talos would pick its own default Kubernetes version); it follows KUBERNETES_VERSION.
#         A KubeletConfig document never uses the static pod manifests directory, which replaces the legacy
#         disableManifestsDirectory: true.
#         Image GC: the kubelet default (85/80%, no max age) kept 700+ old images per node and held /var at
#         about 85%, which is also the imagefs.available<15% eviction limit, with the Ceph mons on the same
#         disk. Images unused for 14 days are removed, and GC starts at 70% and frees down to 60%
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: KubeletConfig
image: ghcr.io/siderolabs/kubelet:${KUBERNETES_VERSION}
clusterDNS:
  - 10.96.0.10
defaultRuntimeSeccompProfileEnabled: true
extraArgs:
  rotate-server-certificates: "true"
config:
  imageGCHighThresholdPercent: 70
  imageGCLowThresholdPercent: 60
  imageMaximumGCAge: 336h
