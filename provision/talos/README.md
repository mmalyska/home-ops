# Talos configuration as code
Folder contains cluster definition using [talhelper](https://github.com/budimanjojo/talhelper).

## Usage
`talhelper genconfig` -> generate configurations to apply
`talosctl -n 192.168.48.4 apply-config --insecure -f clusterconfig/kubernetes-mc3.yaml` -> apply first config
`talosctl -n 192.168.48.4 apply-config -f clusterconfig/kubernetes-mc3.yaml` -> apply config
`talosctl upgrade --nodes 192.168.48.4 --image ghcr.io/siderolabs/installer:v1.4.2` -> upgrade talos
