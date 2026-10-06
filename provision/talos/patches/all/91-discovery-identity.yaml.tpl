# What:   Cluster identity used by the discovery service: the cluster id and the shared secret
# Why:    Same values as before (they come from the Bitwarden-derived TALHELPER_CLUSTERNAME and TALHELPER_CLUSTERSECRET
#         variables that also feed secrets.yaml.tpl), so the discovery group and node membership do not change
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: DiscoveryIdentityConfig
clusterID: ${TALHELPER_CLUSTERNAME}
clusterSecret: ${TALHELPER_CLUSTERSECRET}
