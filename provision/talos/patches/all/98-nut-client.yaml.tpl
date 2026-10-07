# What:   NUT client: watch the UPS and power the node off when it reports low battery
# Why:    Clean shutdown on power loss; the NUT server runs on the QNAP (docs/src/general/ups.md)
# Nodes:  all nodes
# Apply:  live
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: nut-client
configFiles:
  - content: |
      MONITOR ${TALHELPER_UPSMONHOST} 1 ${TALHELPER_UPSMONUSER} ${TALHELPER_UPSMONPASSWD} secondary
      SHUTDOWNCMD "/sbin/poweroff"
    mountPath: /usr/local/etc/nut/upsmon.conf
