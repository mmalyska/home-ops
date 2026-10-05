# Setup of keycloak

The Kubernetes API server OIDC is **not configured** (since the apiServer migration, see `docs/superpowers/specs/2026-10-05-talos-apiserver-documents-design.md`): kubectl uses the Talos-generated kubeconfig. The steps below are the old manifest-based setup; to bring OIDC back, add a `jwt` entry to `provision/talos/patches/controlplane/24-apiserver-authentication.yaml` (issuer url, audiences, claim mappings) instead of API server flags.

Using KC in k8s `kubectl`.

Add new clientId into KC named `k8s`.
Add configuration to `/etc/kubernetes/manifests/kube-apiserver.yaml`:

```sh
    - --oidc-issuer-url=https://l.{DOMAIN}/realms/home
    - --oidc-client-id=k8s
    - --oidc-username-claim=email
    - "--oidc-username-prefix=oidc:"
    - --oidc-groups-claim=groups
    - "--oidc-groups-prefix=oidc:"
```

Add RBAC entry for admin group `oidc-admin-role` or for specifig NS in `/ns-roles`.

Konfigure `kubectl`:

```sh
- name: oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=https://l.{DOMAIN}/realms/home
      - --oidc-client-id=k8s
      - --oidc-client-secret=secret-from-oidc
      command: kubectl
      env:
      provideClusterInfo: false
```
