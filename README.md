# Home k8s infrastructure

Deploying a cluster with [Talos](https://www.talos.dev) and [Terraform](https://www.terraform.io) backed by [ArgoCD](https://argo-cd.readthedocs.io/) and [Bitwarden Secrets Manager](https://bitwarden.com/products/secrets-manager/).

## Overview

- [Core components](https://github.com/mmalyska/home-ops#-components)
- [Setup](https://github.com/mmalyska/home-ops#-setup)
- [Repository structure](https://github.com/mmalyska/home-ops#-repository-structure)
- [Deployment](https://github.com/mmalyska/home-ops#-deployment)
- [Post installation](https://github.com/mmalyska/home-ops#-post-installation)

## 🧱 Core components

### 🚚 Provisioning

For provisioning the following tools are used:

- [Talos](https://www.talos.dev) - this is used to provision all nodes within cluster with uniform system and configuration as gitops
- [Terraform](https://www.terraform.io) - in order to help with the DNS settings this is used to provision an already existing Cloudflare domain and DNS settings

### 📦 Kubernetes

- [cert-manager](https://cert-manager.io/) - SSL certificates - with Cloudflare DNS challenge
- [Cilium](https://cilium.io/) - CNI (container network interface), kube-proxy replacement, L2 load balancer announcements
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps tool for deploying manifests from the `cluster` directory
- [rook.io](https://rook.io/) - ceph storage for k8s
- [nfs](https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/) - used for cold storage on QNAP
- [Envoy Gateway](https://gateway.envoyproxy.io/) - Kubernetes Gateway API implementation with two gateways:
  - **envoy-external** (192.168.48.20) - internet-facing via Cloudflare Tunnel
  - **envoy-internal** (192.168.48.21) - internal network only
- [Cloudflared](https://github.com/cloudflare/cloudflared) - Cloudflare Tunnel client for external access
- [external-dns (cloudflare)](https://github.com/kubernetes-sigs/external-dns) - publishes external HTTPRoutes and DNSEndpoints to Cloudflare DNS
- [external-dns (adguard)](https://github.com/kubernetes-sigs/external-dns) - publishes internal HTTPRoutes and DNSEndpoints to AdGuard Home DNS
- [Keycloak](https://www.keycloak.org/) - identity provider (OIDC)
- [External Secrets Operator](https://external-secrets.io/) - secret synchronization from Bitwarden Secrets Manager
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) - monitoring (Prometheus + Grafana)
- [CloudNative-PG](https://cloudnative-pg.io/) - PostgreSQL operator
- [VolSync](https://volsync.readthedocs.io/) - persistent volume backup and restore

## 📝 Setup

### 💻 Systems

- Nodes running [Talos](https://www.talos.dev). These nodes are bare metals.
- A [Cloudflare](https://www.cloudflare.com/) account with a domain, this will be managed by Terraform.
- QNAP used as NFS and S3 storage.

### 🧠 Devcontainer

For fast setup I use devcontainer to have same environment across different devices. See more inside `.devcontainer` and at [Devcontainers](https://containers.dev/)

### 🔧 Tools

1. Install the **most recent versions** of the following command-line tools on your workstation, if you are using [Homebrew](https://brew.sh/) on macOS or Linux skip to steps 3 and 4.

   - Required:
     [go-task](https://github.com/go-task/task),
     [ipcalc](http://jodies.de/ipcalc),
     [jq](https://stedolan.github.io/jq/),
     [kubectl](https://kubernetes.io/docs/tasks/tools/),
     [pre-commit](https://github.com/pre-commit/pre-commit),
     [terraform](https://www.terraform.io),
     [yq](https://github.com/mikefarah/yq),
     [argocd CLI](https://github.com/argoproj/argo-cd),
     [mkdocs](https://www.mkdocs.org/)

   - Recommended:
     [direnv](https://github.com/direnv/direnv),
     [helm](https://helm.sh/),
     [kustomize](https://github.com/kubernetes-sigs/kustomize),
     [prettier](https://github.com/prettier/prettier),
     [stern](https://github.com/stern/stern),
     [yamllint](https://github.com/adrienverge/yamllint),
     [gitleaks](https://github.com/gitleaks/gitleaks),
     [argocd](https://argoproj.github.io/cd/),
     [kubelogin](https://github.com/int128/kubelogin),
     [k9s](https://k9scli.io/)

2. This guide heavily relies on [go-task](https://github.com/go-task/task) as a framework for setting things up. It is advised to learn and understand the commands it is running under the hood.

3. Install [go-task](https://github.com/go-task/task) via Brew

   ```sh
   brew install go-task/tap/go-task
   ```

4. Install workstation dependencies via Brew

   ```sh
   task init
   ```

### ⚠️ pre-commit

It is advisable to install [pre-commit](https://pre-commit.com/) and the pre-commit hooks that come with this repository.
[gitleaks](https://github.com/gitleaks/gitleaks) will check to make sure you are not accidentally committing secrets.

1. Enable Pre-Commit

   ```sh
   task precommit:init
   ```

2. Update Pre-Commit, though it will occasionally make mistakes, so verify its results.

   ```sh
   task precommit:update
   ```

## 📂 Repository structure

The Git repository contains the following directories under `cluster` and are ordered below by how Argo CD will apply them.

```text
📁 cluster
├──📄 bootstrap-application.yaml - root app-of-apps entry point
├──📁 projects   - ArgoCD AppProject definitions (core/system/default/games/home-automation)
├──📁 appsets    - ArgoCD ApplicationSet definitions (auto-discover app-config.yaml files)
├──📁 apps       - application manifests organized by category
│   ├──📁 core   - cluster core (cilium, argocd, rook-ceph)
│   ├──📁 system - platform services (traefik, cert-manager, monitoring, keycloak, external-secrets...)
│   ├──📁 default - workload apps (jellyfin, gitea, n8n, open-webui, gethomepage...)
│   ├──📁 games  - game servers (minecraft-bedrock, vintagestory)
│   └──📁 home-automation - home automation (vernemq, ollama, whisper, piper, openwakeword)
└──📁 .tools     - utility manifests (rook wipe jobs, etc.)
```

## 🚀 Deployment

### ☁️ Global Cloudflare API Token

In order to use Terraform and `cert-manager` with the Cloudflare DNS challenge you will need to create an API Token.

1. Head over to Cloudflare and create an API Token by going [here](https://dash.cloudflare.com/profile/api-tokens).

2. Under the `API Tokens` section, create a scoped API Token.

3. Store the API Token in **Bitwarden Secrets Manager** and reference it by UUID in:
   - `provision/terraform/cloudflare/bitwarden_secrets.tf` (via `bitwarden-secrets` Terraform provider)
   - `cluster/apps/system/cert-manager/resources/api-token-externalsecret.yaml` (via ESO ExternalSecret)

### ⚡ Preparing Talos nodes

1. Get a ISO image of the installer from latest [release](https://github.com/mmalyska/talos-images/releases)

2. Configure nodes inside `provision/talos/talconfig.yaml`

3. Run `task talos:init` to generate talos configs for each node

4. Follow guide on [Getting Started](https://www.talos.dev/v1.6/introduction/getting-started/) for details on Talos installation

### ☁️ Configuring Cloudflare DNS with Terraform

📍 Review the Terraform scripts under `./provision/terraform/cloudflare/` and make sure you understand what it's doing (no really review it).
If your domain already has existing DNS records be sure to export those DNS settings before you continue.
Ideally you can update the terraform script to manage DNS for all records if you so choose to.

1. Pull in the Terraform deps by running `task terraform:init:cloudflare`

2. Review the changes Terraform will make to your Cloudflare domain by running `task terraform:plan:cloudflare`

3. Finally have Terraform execute the task by running `task terraform:apply:cloudflare`

If Terraform was ran successfully you can log into Cloudflare and validate the DNS records are present.

### 🐙 Bootstrapping the cluster

📍 Before running bootstrap, make sure your `.envrc` is sourced (via `direnv`) so that `BWS_TOKEN`, `KUBECONFIG`, and `TALOSCONFIG` are all set in your environment.

1. Apply Talos config to each node (first boot, use `--insecure` before the PKI is established):

   ```sh
   talosctl apply-config --nodes 192.168.48.2 --insecure -f provision/talos/clusterconfig/home-mc1.yaml
   talosctl apply-config --nodes 192.168.48.3 --insecure -f provision/talos/clusterconfig/home-mc2.yaml
   talosctl apply-config --nodes 192.168.48.4 --insecure -f provision/talos/clusterconfig/home-mc3.yaml
   ```

2. Push your configuration to git so ArgoCD can read it:

   ```sh
   git add -A
   git commit -m "chore: initial cluster configuration"
   git push
   ```

3. Run the full bootstrap (etcd → kubeconfig → Cilium → ESO secret injection → Rook wipe → ArgoCD):

   ```sh
   task bootstrap:kubernetes
   ```

   This single command automates the following phases in order:

   | Phase | What happens |
   | ----- | ------------ |
   | **etcd** | Bootstraps the etcd leader on the first control-plane node |
   | **kubeconfig** | Fetches kubeconfig from Talos into `$KUBECONFIG` |
   | **apps** (helmfile) | Installs Cilium CNI and `kubelet-csr-approver`; waits for all nodes `Ready` |
   | **eso-bootstrap** | Creates the `external-secrets` namespace and injects the `bitwarden-access-token` K8s Secret from `$BWS_TOKEN` |
   | **rook** | Wipes Rook data directories and raw disks on every node (destructive — disks must be clean for Ceph) |
   | **argocd** | Creates an empty `cluster-secrets` placeholder so the repo-server CMP sidecar can start, applies the ArgoCD kustomize, applies the root `bootstrap-application.yaml`, and waits for `argocd-server` to be ready |

   > After `task bootstrap:kubernetes` completes, ArgoCD is running and the root app-of-apps is applied.
   > ApplicationSets auto-discover all `enabled: "true"` apps and begin syncing them. External Secrets
   > Operator deploys first (sync-wave `-5`), authenticates with Bitwarden using the injected token,
   > and populates the `cluster-secrets` K8s Secret — at which point ArgoCD can fully resolve
   > `<secret:key>` tokens in all app manifests.

4. Log in to ArgoCD with the local admin account (OIDC is unavailable until Keycloak finishes deploying):

   ```sh
   task argocd:login
   # When prompted, use local credentials — SSO will not work yet
   ```

5. Sync the Rook Ceph operator and cluster (manual gate — storage is not auto-synced to prevent accidental disk claims):

   ```sh
   task bootstrap:rook-sync
   ```

6. Once Keycloak has deployed and its realm/client are configured, SSO login works automatically.
   You can re-run `task argocd:login` to switch to SSO.

🎉 **Congratulations** you have a Kubernetes cluster managed by ArgoCD, your Git repository is driving the state of your cluster.

## 📣 Post installation

### 👉 Cluster maintenance

This section will be about upgrading k8s and onther components on your cluster using Talos.
