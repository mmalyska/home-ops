terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "workspace_image" {
  name        = "workspace_image"
  display_name = "Workspace Image"
  description = "Full image reference for this workspace"
  type        = "string"
  default     = "ghcr.io/mmalyska/sandbox-devops:rolling"
  mutable     = false
  order       = 1
}

data "coder_parameter" "lb_ip" {
  name        = "lb_ip"
  display_name = "LoadBalancer IP"
  description = "Fixed IP from coder-pool (192.168.48.51-70) for direct SSH access"
  type        = "string"
  mutable     = false
  order       = 2
}

data "coder_parameter" "authorized_key" {
  name        = "authorized_key"
  display_name = "SSH Public Key"
  description = "SSH public key installed in the workspace for direct SSH access"
  type        = "string"
  mutable     = false
  order       = 3
}

data "coder_parameter" "storage_size" {
  name        = "storage_size"
  display_name = "Storage Size"
  description = "Home directory PVC size"
  type        = "string"
  default     = "20Gi"
  mutable     = false
  order       = 4
}

locals {
  workspace_id = "${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"
}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  startup_script = <<-EOT
    #!/bin/bash
    set -e
    mkdir -p /home/coder/.ssh
    echo "${data.coder_parameter.authorized_key.value}" > /home/coder/.ssh/authorized_keys
    chmod 700 /home/coder/.ssh
    chmod 600 /home/coder/.ssh/authorized_keys
    chown -R coder:coder /home/coder/.ssh
    /usr/sbin/sshd -D &
  EOT
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "coder-${local.workspace_id}-home"
    namespace = "coder"
    labels = {
      "app.kubernetes.io/managed-by" = "coder"
      "coder.workspace"              = data.coder_workspace.me.name
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-block"
    resources {
      requests = {
        storage = data.coder_parameter.storage_size.value
      }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_deployment" "workspace" {
  metadata {
    name      = "coder-${local.workspace_id}"
    namespace = "coder"
    labels = {
      "app.kubernetes.io/name"       = "coder-workspace"
      "app.kubernetes.io/instance"   = local.workspace_id
      "app.kubernetes.io/managed-by" = "coder"
    }
  }

  spec {
    replicas = data.coder_workspace.me.start_count

    selector {
      match_labels = {
        "app.kubernetes.io/instance" = local.workspace_id
      }
    }

    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"     = "coder-workspace"
          "app.kubernetes.io/instance" = local.workspace_id
        }
      }

      spec {
        security_context {
          run_as_user = 1000
          fs_group    = 1000
        }

        container {
          name    = "workspace"
          image   = data.coder_parameter.workspace_image.value
          command = ["sh", "-c", coder_agent.main.init_script]

          security_context {
            run_as_user = 0
          }

          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "1Gi"
            }
            limits = {
              cpu    = "1000m"
              memory = "2Gi"
            }
          }

          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
          }
        }

        volume {
          name = "home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim.home]
}

resource "kubernetes_service" "ssh" {
  metadata {
    name      = "coder-${local.workspace_id}-ssh"
    namespace = "coder"
    annotations = {
      "lbipam.cilium.io/ips" = data.coder_parameter.lb_ip.value
    }
  }

  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/instance" = local.workspace_id
    }
    port {
      name        = "ssh"
      port        = 22
      target_port = 22
      protocol    = "TCP"
    }
  }
}
