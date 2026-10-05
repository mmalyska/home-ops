# What:   kube-apiserver OIDC login (Keycloak) and the extra names its certificate is valid for
# Why:    kubectl users authenticate through Keycloak; the SANs let clients use the VIP and the cluster domain
# Nodes:  control plane
# Apply:  live (the kube-apiserver static pod restarts)
cluster:
  apiServer:
    extraArgs:
      oidc-client-id: ${TALHELPER_OIDCCLIENTID}
      oidc-groups-claim: groups
      oidc-groups-prefix: "oidc:"
      oidc-issuer-url: ${TALHELPER_OIDCISSUERURL}
      oidc-username-claim: email
      oidc-username-prefix: "oidc:"
    certSANs:
      - ${TALHELPER_CLUSTERENDPOINTIP}
      - ${TALHELPER_CLUSTERDOMAIN}
      - 127.0.0.1
