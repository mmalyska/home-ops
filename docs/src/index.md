# Home cluster

This [repo](https://github.com/mmalyska/home-ops) is my homelab OPS stuff. This is a single source of truth for storing configuration for my home servers, cloud instances and other devices.

In this repo I'm focusing on:

- Provisioning homelab servers with [Talos](https://talos.dev) to have uniform way of configuring servers
- Configuring cloud services using [Terraform](https://www.terraform.io)
- Deploying applications with use of [ArgoCD](https://argo-cd.readthedocs.io)

## Tech Stack

### Provisioning

| Tool | Purpose |
| ---- | ------- |
| [Talos](https://talos.dev) | Kubernetes-focused immutable Linux OS for all nodes |
| [talhelper](https://github.com/budimanjojo/talhelper) | Talos config generation from `talconfig.yaml` |
| [Terraform](https://www.terraform.io) | Cloudflare DNS, tunnels, and firewall rules |

### Kubernetes

| Component | Purpose |
| --------- | ------- |
| [ArgoCD](https://argo-cd.readthedocs.io) | GitOps continuous delivery with ApplicationSets |
| [Cilium](https://cilium.io) | CNI, kube-proxy replacement, L2 load balancer announcements |
| [Traefik](https://traefik.io) | Ingress controller |
| [cert-manager](https://cert-manager.io) | Automated TLS certificates (Cloudflare DNS01) |
| [Rook-Ceph](https://rook.io) | Distributed block and file storage |
| [NFS subdir provisioner](https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/) | Cold storage on QNAP NAS |
| [Keycloak](https://www.keycloak.org) | Identity provider (OIDC) |
| [External Secrets Operator](https://external-secrets.io) | Secret sync from Bitwarden Secrets Manager |
| [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts) | Prometheus + Grafana monitoring |
| [CloudNative-PG](https://cloudnative-pg.io) | PostgreSQL operator |
| [VolSync](https://volsync.readthedocs.io) | PVC backup and restore |
| [Cloudflared](https://github.com/cloudflare/cloudflared) | Cloudflare Tunnel client |

### Secrets Management

| Tool | Purpose |
| ---- | ------- |
| [SOPS](https://github.com/mozilla/sops) | Encrypts secret files in Git using Age |
| [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/) | Environment secrets via BWS CLI |
