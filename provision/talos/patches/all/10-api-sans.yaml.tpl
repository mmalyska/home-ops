# What:   Names and IPs the node API certificate is valid for: the control-plane VIP, the cluster domain, loopback
# Why:    talosctl and kubectl connect through the VIP and the public cluster name
# Nodes:  all nodes
# Apply:  live
machine:
  certSANs:
    - ${TALHELPER_CLUSTERENDPOINTIP}
    - ${TALHELPER_CLUSTERDOMAIN}
    - 127.0.0.1
