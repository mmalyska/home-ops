# What:   Kubelet: rotate serving certificates, default seccomp profile, pinned cluster DNS, kubelet image at the Kubernetes version
# Why:    kubelet-csr-approver signs the rotated serving certificates; CoreDNS is self-provisioned
#         (cluster.coreDNS.disabled), so the kube-dns Service address is pinned. The document needs the image
#         explicitly (without it Talos would pick its own default Kubernetes version); it follows KUBERNETES_VERSION.
#         A KubeletConfig document never uses the static pod manifests directory, which replaces the legacy
#         disableManifestsDirectory: true
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
