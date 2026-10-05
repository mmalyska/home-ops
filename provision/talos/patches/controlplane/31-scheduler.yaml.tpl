# What:   kube-scheduler listens on all addresses
# Why:    Exposes the metrics endpoint so Prometheus can scrape it. The document needs the image explicitly
#         (the generated base carried it); it follows KUBERNETES_VERSION
# Nodes:  control plane
# Apply:  live (the static pod restarts)
apiVersion: v1alpha1
kind: KubeSchedulerConfig
image: registry.k8s.io/kube-scheduler:${KUBERNETES_VERSION}
extraArgs:
  bind-address: 0.0.0.0
