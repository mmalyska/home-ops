# What:   Cluster name and the Kubernetes API endpoint
# Why:    Replaces the cluster.clusterName and cluster.controlPlane.endpoint fields of the generated base with the same
#         values: the name `talosctl gen config` is given (CLUSTER_NAME in scripts/lib.sh) and the public cluster name on
#         port 6443. It needs the KubeServiceAccountConfig document (scripts/pki-documents.sh), Talos refuses it otherwise
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: KubeClusterConfig
clusterName: home
endpoint: https://${TALHELPER_CLUSTERDOMAIN}:6443
