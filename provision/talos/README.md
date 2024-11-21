# Talos configuration as code

Folder contains cluster definition using [talhelper](https://github.com/budimanjojo/talhelper).

## Usage

`talhelper genconfig` -> generate configurations to apply

`talosctl --nodes 192.168.48.2 apply-config --insecure -f provision/talos/clusterconfig/home-mc1.yaml` -> apply first config

`kubectl get csr -o name | grep "certificates.k8s.io" | xargs kubectl certificate approve` -> approve all csr

apply cilium cni:
```
helm dependencies update cluster/core/cilium
helm template -n kube-system cluster/core/cilium | kubectl apply -f -
```
apply argocd:
```
kustomize build cluster/core/argocd | argocd-secret-replacer sops -f cluster/core/argocd/secret.sec.yaml | kubectl apply -f -
```

`talosctl --nodes 192.168.48.4 apply-config -f clusterconfig/kubernetes-mc3.yaml` -> apply config

`talosctl --nodes 192.168.48.4 upgrade --image ghcr.io/siderolabs/installer:v1.4.2` -> upgrade talos

`talosctl --nodes 192.168.48.4 upgrade-k8s --to 1.27.2` -> upgrade k8s
