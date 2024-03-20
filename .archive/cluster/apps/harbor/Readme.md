# Install harbor helm repo

```sh
helm repo add harbor https://helm.goharbor.io
helm repo update

kubeseal --controller-namespace sealed-secrets --format yaml < secret.yaml > sealedsecret.yaml
```
