# Installing cluster

Install argocd using `kustomize`.

```sh
kustomize build . | argocd-secret-replacer sops -f secret.sec.yaml | kubectl apply -f -
```

Get admin password

```sh
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
```
