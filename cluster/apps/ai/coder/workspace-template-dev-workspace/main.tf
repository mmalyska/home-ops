terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

# Dev workspace on the dev-workstation image (plan: .plans/remote-dev-workspace).
#
# This template only creates the Deployment. Everything else it needs is created and owned by GitOps in
# cluster/apps/system/dev-workspace and is referenced by name: the two PVCs, the Kubernetes and Talos
# ServiceAccounts, the BWS token Secret and the backups. The provisioner has no permission on any of them
# (D35), so this file creates no PVC, ExternalSecret, ReplicationSource, RBAC object or Talos ServiceAccount.

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "workspace" {
  name         = "workspace"
  display_name = "GitOps workspace"
  description  = "Name of the entry in the GitOps workspace list (cluster/apps/system/dev-workspace). Selects the PVCs <name>-home and <name>-src, the ServiceAccount <name> and the Talos Secret <name>-talos."
  type         = "string"
  default      = "dev-workspace"
  mutable      = false
  order        = 1
}

data "coder_parameter" "bws_secret" {
  name         = "bws_secret"
  display_name = "BWS token Secret"
  description  = "Name of the Kubernetes Secret with BWS_ACCESS_TOKEN and BWS_PROJECT_ID for this workspace type (D11, D31)."
  type         = "string"
  default      = "dev-workspace-bws"
  mutable      = false
  order        = 2
}

data "coder_parameter" "arch" {
  name         = "arch"
  display_name = "Architecture"
  description  = "Platform of the image to run; the pod is scheduled on a node of this architecture."
  type         = "string"
  default      = "amd64"
  mutable      = false
  order        = 3
  option {
    name  = "amd64"
    value = "amd64"
  }
  option {
    name  = "arm64"
    value = "arm64"
  }
}

locals {
  namespace = "dev-workspace"
  ws        = data.coder_parameter.workspace.value

  # Pinned by digest, never by the bare tag (the 1.0.0 tag moves on every rebuild). Bump tag and digest
  # together after checking the multi-arch manifest.
  image = "ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:76a0c4f0359029fa9ce976a39b87d7770bb332c56336e7ea673d753a0dc30f98"

  labels = {
    "app.kubernetes.io/name"       = "dev-workspace"
    "app.kubernetes.io/instance"   = local.ws
    "app.kubernetes.io/managed-by" = "coder"
  }

  # Mount paths. /run/signing is a memory-backed emptyDir: the SSH signing key never touches a disk.
  signing_dir = "/run/signing"
  talos_dir   = "/var/run/secrets/talos.dev"
}

resource "coder_agent" "main" {
  arch = data.coder_parameter.arch.value
  os   = "linux"

  # The Coder agent is the only way in (D15): no sshd, no Service, no authorized_keys.
  env = {
    # Talos: the mounted Secret holds a read-only (os:reader) talosconfig that Talos renews every few hours.
    # Never a copy, so a renewed certificate reaches the pod. The config has no nodes list: pass --nodes.
    TALOSCONFIG = "${local.talos_dir}/config"
    # The in-pod ssh-agent that holds the signing key (D32).
    SSH_AUTH_SOCK = "${local.signing_dir}/agent.sock"
    # Tells mmalyska/dotfiles it runs in a remote workspace (workspace signing key, repository clones). The
    # Coder agent also sets CODER=true; this does not depend on that.
    REMOTE_WORKSPACE = "1"
    # Argo CD sits behind the Envoy HTTP gateway, which does not pass raw gRPC: without this the CLI warns on every call.
    ARGOCD_OPTS = "--grpc-web"
    # kubectl's discovery cache goes to the rebuildable /cache, not to ~/.kube on the backed-up home volume.
    KUBECACHEDIR = "/cache/kube"
  }

  startup_script = <<-EOT
    #!/bin/bash
    set -u
    umask 077

    # Fill an empty home volume (D45). Existing files are left alone; nothing else is seeded.
    cp -rn /etc/skel/. "$HOME"/ 2>/dev/null || true

    # Load the SSH signing key from the workspace's BWS project into an in-pod ssh-agent. The key goes
    # through a memory-backed volume and is removed at once; it is never written to the home volume
    # and never printed.
    sock="${local.signing_dir}/agent.sock"
    if [ -n "$${BWS_ACCESS_TOKEN:-}" ] && [ -n "$${BWS_PROJECT_ID:-}" ]; then
      [ -S "$sock" ] || ssh-agent -a "$sock" >/dev/null
      if ! SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1; then
        key="${local.signing_dir}/key"
        if bws secret list "$BWS_PROJECT_ID" -o json 2>/dev/null \
            | jq -r '.[] | select(.key == "SSH_SIGNING_KEY") | .value' > "$key" && [ -s "$key" ]; then
          if SSH_AUTH_SOCK="$sock" ssh-add "$key" >/dev/null 2>&1; then
            echo "signing key loaded into the ssh-agent"
          else
            echo "signing key found but ssh-add failed"
          fi
        else
          echo "signing key SSH_SIGNING_KEY not found in the BWS project"
        fi
        rm -f "$key"
      fi
    else
      echo "BWS_ACCESS_TOKEN or BWS_PROJECT_ID is not set: no signing key loaded"
    fi
  EOT
}

# Bootstrap at every start (bootstrap.sh): applies the dotfiles once per home volume (they clone the repositories).
# A repository's .devcontainer scripts are not run (plan D48). It does not block login, and a failure is logged and
# skipped. The script is read from the template directory, so `coder templates push` uploads it with main.tf.
resource "coder_script" "bootstrap" {
  agent_id           = coder_agent.main.id
  display_name       = "Bootstrap"
  icon               = "/icon/code.svg"
  run_on_start       = true
  start_blocks_login = false
  timeout            = 3600
  script             = file("${path.module}/bootstrap.sh")
}

resource "kubernetes_deployment_v1" "workspace" {
  metadata {
    name      = "ws-${local.ws}"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = data.coder_workspace.me.start_count

    # One RWO volume pair: the old pod must be gone before the new one starts.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/instance" = local.ws
      }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        # Kubernetes API access (read-only RBAC owned by GitOps, D26, D27): the pod token is mounted,
        # kubectl uses the in-cluster configuration and no kubeconfig file exists.
        service_account_name = local.ws

        node_selector = {
          "kubernetes.io/arch" = data.coder_parameter.arch.value
        }

        security_context {
          run_as_user            = 1000
          run_as_group           = 1000
          run_as_non_root        = true
          fs_group               = 1000
          fs_group_change_policy = "OnRootMismatch"
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "workspace"
          image   = local.image
          command = ["bash", "-c", coder_agent.main.init_script]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          env {
            name  = "HOME"
            value = "/home/vscode"
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          # The scoped BWS machine token and its project (D31). Read from a Secret; no secret value
          # passes through Terraform variables or state.
          env {
            name = "BWS_ACCESS_TOKEN"
            value_from {
              secret_key_ref {
                name = data.coder_parameter.bws_secret.value
                key  = "BWS_ACCESS_TOKEN"
              }
            }
          }
          env {
            name = "BWS_PROJECT_ID"
            value_from {
              secret_key_ref {
                name = data.coder_parameter.bws_secret.value
                key  = "BWS_PROJECT_ID"
              }
            }
          }

          # 3 Gi request = limit. ephemeral-storage sits above the emptyDir limits below
          # (20 Gi cache + 5 Gi tmp + 64 Mi signing) plus margin, so an emptyDir over its limit evicts
          # the pod on purpose and nothing else does. CPU request is a starting point (T9).
          resources {
            requests = {
              cpu                 = "500m"
              memory              = "3Gi"
              "ephemeral-storage" = "30Gi"
            }
            limits = {
              cpu                 = "2"
              memory              = "3Gi"
              "ephemeral-storage" = "30Gi"
            }
          }

          # The only writable paths (T22): home, source, cache, tmp, and the memory volume for the key.
          volume_mount {
            name       = "home"
            mount_path = "/home/vscode"
          }
          volume_mount {
            name       = "src"
            mount_path = "/workspaces"
          }
          volume_mount {
            name       = "cache"
            mount_path = "/cache"
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }
          volume_mount {
            name       = "signing"
            mount_path = local.signing_dir
          }
          # A directory mount, not subPath, so the renewed talosconfig reaches the pod.
          volume_mount {
            name       = "talos"
            mount_path = local.talos_dir
            read_only  = true
          }
        }

        # The two claims are created and backed up by GitOps (D39, D41); the template only references them.
        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = "${local.ws}-home"
          }
        }
        volume {
          name = "src"
          persistent_volume_claim {
            claim_name = "${local.ws}-src"
          }
        }
        # Rebuildable caches and scratch: empty after every pod restart (accepted, D40).
        volume {
          name = "cache"
          empty_dir {
            size_limit = "20Gi"
          }
        }
        volume {
          name = "tmp"
          empty_dir {
            size_limit = "5Gi"
          }
        }
        volume {
          name = "signing"
          empty_dir {
            medium     = "Memory"
            size_limit = "64Mi"
          }
        }
        volume {
          name = "talos"
          secret {
            secret_name = "${local.ws}-talos"
          }
        }
      }
    }
  }
}
