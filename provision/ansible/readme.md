# Helpfull commands

To run test quickly on vagrant machines
```sh
ansible-playbook -i ./provision/ansible/tests/ansible_hosts.yml ./provision/ansible/playbooks/k8s.yaml --tags containerd
```
