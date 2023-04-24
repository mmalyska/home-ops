# Talos configuration as code
Folder contains cluster definition using [talhelper](https://github.com/budimanjojo/talhelper).

## Usage
`talhelper genconfig` -> generate configurations to apply
`talosctl --nodes 192.168.48.4 apply-config --insecure --file clusterconfig/kubernetes-mc3.yaml` -> apply config
