# Talos configuration as code
Folder contains cluster definition using [talhelper](https://github.com/budimanjojo/talhelper).

## Usage
`talhelper genconfig` -> generate configurations to apply
`talosctl --nodes 192.168.48.4 apply-config --insecure -f clusterconfig/kubernetes-mc3.yaml` -> apply first config
`talosctl --nodes 192.168.48.4 apply-config -f clusterconfig/kubernetes-mc3.yaml` -> apply config
`talosctl --nodes 192.168.48.4 upgrade --image ghcr.io/siderolabs/installer:v1.4.2` -> upgrade talos
`talosctl --nodes 192.168.48.4 upgrade-k8s --to 1.27.2` -> upgrade k8s
