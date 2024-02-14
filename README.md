# Home k8s infrastructure

Deploying a cluster with [Talos](https://www.talos.dev) and [Terraform](https://www.terraform.io) backed by [ArgoCD](https://argo-cd.readthedocs.io/) and [SOPS](https://github.com/mozilla/sops).

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
- [flannel](https://github.com/flannel-io/flannel) - CNI (container network interface)
- [ArgoCD](https://argo-cd.readthedocs.io/) - GitOps tool for deploying manifests from the `cluster` directory
- [rook.io](https://rook.io/) - ceph storage for k8s
- [nfs](https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/) - used for cold storage on QNAP
- [metallb](https://metallb.universe.tf/) - bare metal load balancer
- [traefik](https://traefik.io) - ingress controller

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
     [age](https://github.com/FiloSottile/age),
     [ansible](https://www.ansible.com),
     [go-task](https://github.com/go-task/task),
     [ipcalc](http://jodies.de/ipcalc),
     [jq](https://stedolan.github.io/jq/),
     [kubectl](https://kubernetes.io/docs/tasks/tools/),
     [pre-commit](https://github.com/pre-commit/pre-commit),
     [sops](https://github.com/mozilla/sops),
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
     [ansible-lint](https://ansible.readthedocs.io/projects/lint/),
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
[sops-pre-commit](https://github.com/k8s-at-home/sops-pre-commit) will check to make sure you are not by accident committing un-encrypted secrets.

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
├──📁 projects - main folder for ArgoCD to sync deployed apps
├──📁 apps - folder for apps manifests
├──📁 core - folder for a core apps of cluster
│   └──📁 argocd
│       └──📁 projects - folder containing manifests to initialize app-of-apps for ArgoCD
└──📁 system - app counted as extensions of cluster (certs, ingress, gpu, etc.)
```

## 🚀 Deployment

### 🔐 Setting up Age

I assume you already have generated age key pair to be used otherwise you need to generate one.
Export the `SOPS_AGE_KEY_FILE` variable in your `bashrc`, `zshrc` or `config.fish` and source it, e.g.

```sh
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
source ~/.bashrc
```

### ☁️ Global Cloudflare API Token

In order to use Terraform and `cert-manager` with the Cloudflare DNS challenge you will need to create a API Token.

1. Head over to Cloudflare and create a API Token by going [here](https://dash.cloudflare.com/profile/api-tokens).

2. Under the `API Tokens` section, create a scoped API Token.

3. Use the API Token in **provision/terraform/cloudflare** and **cluster/system/cert-manager**.

### ⚡ Preparing Talos nodes

1. Get a ISO image of the installer from latest release https://github.com/mmalyska/talos-images/releases

2. Configure nodes inside `provision/talos/talconfig.yaml`

3. Run `task talos:init` to generate talos configs for each node

4. Follow guide on https://www.talos.dev/v1.6/introduction/getting-started/ for details on Talos installation

### ☁️ Configuring Cloudflare DNS with Terraform

📍 Review the Terraform scripts under `./provision/terraform/cloudflare/` and make sure you understand what it's doing (no really review it).
If your domain already has existing DNS records be sure to export those DNS settings before you continue.
Ideally you can update the terraform script to manage DNS for all records if you so choose to.

1. Pull in the Terraform deps by running `task terraform:init:cloudflare`

2. Review the changes Terraform will make to your Cloudflare domain by running `task terraform:plan:cloudflare`

3. Finally have Terraform execute the task by running `task terraform:apply:cloudflare`

If Terraform was ran successfully you can log into Cloudflare and validate the DNS records are present.

### 🐙 GitOps with ArgoCD

📍 Here we will be installing [ArgoCD](https://argo-cd.readthedocs.io/en/stable/) after some quick bootstrap steps.

1. Verify ArgoCD can be installed

   ```sh
   argocd version
   # argocd: vX.X.X
   # ...
   ```

2. Pre-create the `argocd` namespace

   ```sh
   kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
   ```

3. Add the Age key in-order for ArgoCD to decrypt SOPS secrets

   ```sh
   cat $SOPS_AGE_KEY_FILE |
       kubectl -n argocd create secret generic sops-age \
       --from-file=age.agekey=/dev/stdin
   ```

4. **Verify** all files ending with `*.sops.yaml` or `*.sec.yaml` are **encrypted** with SOPS

5. Push you changes to git

   ```sh
   git add -A
   git commit -m "encrypting secrets"
   git push
   ```

6. Install Argo CD

   ```sh
   kubectl apply -k ./cluster/core/argocd/base
   ```

7. Verify Argo CD components are running in the cluster

   ```sh
   kubectl get pods -n argocd
   ```

   If all goes well and you have port forwarded `80` and `443` in your router to the `METALLB_TRAEFIK_ADDR` IP, in a few moments head over to your browser and you _should_ be able to access `https://hajimari.CLOUDFLARE_DOMAIN`

🎉 **Congratulations** you have a Kubernetes cluster managed by Argo CD, your Git repository is driving the state of your cluster.

## 📣 Post installation

### 👉 Cluster maintenance

This section will be about upgrading k8s and onther components on your cluster using Talos.
