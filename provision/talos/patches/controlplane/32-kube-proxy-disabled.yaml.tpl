# What:   kube-proxy is not deployed
# Why:    Cilium replaces kube-proxy. The legacy bind-address argument is dropped: it has no effect on a proxy that is not deployed.
#         The image is pinned to KUBERNETES_VERSION although nothing runs: talosctl upgrade-k8s (tuppr) writes it into the live
#         document on every Kubernetes upgrade, so git has to carry it or talos:diff shows a difference
# Nodes:  control plane
# Apply:  live
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
image: registry.k8s.io/kube-proxy:${KUBERNETES_VERSION}
