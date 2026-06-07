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
    echo "${var.authorized_key}" > /home/coder/.ssh/authorized_keys
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
        storage = var.storage_size
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
          image   = var.workspace_image
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

        image_pull_secrets {
          name = "coder-harbor-pull-secret"
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
      "lbipam.cilium.io/ips" = var.lb_ip
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
