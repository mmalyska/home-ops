# Create cloudflare secret

```sh
Get-Content .\secret.yaml | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --namespace cert-manager --format yaml > sealedsecret.yaml
```

WARNING: do not use `namespace: XXXX` in kustomize. It nchanges `kube-system` namespace in some files.

test certificate

```sh
kubectl apply -f test/test-cert.yaml
```
