# What:   kube-apiserver image at the Kubernetes version and the extra names its certificate is valid for
# Why:    The document needs the image explicitly (the generated base carried it); the SANs let clients use the VIP and
#         the cluster domain. Authentication, authorization, admission and audit are separate documents (21 to 26).
#         The API server OIDC is not configured: kubectl uses the Talos-generated kubeconfig
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
apiVersion: v1alpha1
kind: KubeAPIServerConfig
image: registry.k8s.io/kube-apiserver:${KUBERNETES_VERSION}
certExtraSANs:
  - ${TALHELPER_CLUSTERENDPOINTIP}
  - ${TALHELPER_CLUSTERDOMAIN}
  - 127.0.0.1
