sealing secrets in powershell
```ps
Get-Content .\secret.yaml | kubeseal --controller-namespace sealed-secrets --controller-name sealed-secrets --format yaml  >sealedsecret.yaml
```
