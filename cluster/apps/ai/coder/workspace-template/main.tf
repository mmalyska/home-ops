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
  default     = "2Gi"
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
    chown coder:coder /home/coder
    chmod 755 /home/coder
    mkdir -p /home/coder/.ssh
    echo "${data.coder_parameter.authorized_key.value}" > /home/coder/.ssh/authorized_keys
    chmod 700 /home/coder/.ssh
    chmod 600 /home/coder/.ssh/authorized_keys
    chown -R coder:coder /home/coder/.ssh
    /usr/sbin/sshd -D >/dev/null 2>&1 &
  EOT
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
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

resource "kubernetes_deployment_v1" "workspace" {
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

    strategy {
      type = "Recreate"
    }

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
            claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [kubernetes_persistent_volume_claim_v1.home]
}

resource "kubernetes_service_v1" "ssh" {
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

resource "kubernetes_manifest" "volsync_es" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "coder-${local.workspace_id}-restic"
      namespace = "coder"
    }
    spec = {
      secretStoreRef = {
        kind = "ClusterSecretStore"
        name = "bitwarden"
      }
      refreshInterval = "1h"
      target = {
        name           = "coder-${local.workspace_id}-restic-secret"
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            RESTIC_REPOSITORY     = "{{ .REPOSITORY_TEMPLATE }}/coder-${data.coder_workspace.me.name}"
            RESTIC_PASSWORD       = "{{ .RESTIC_PASSWORD }}"
            AWS_ACCESS_KEY_ID     = "{{ .AWS_ACCESS_KEY_ID }}"
            AWS_SECRET_ACCESS_KEY = "{{ .AWS_SECRET_ACCESS_KEY }}"
          }
        }
      }
      data = [
        {
          secretKey = "REPOSITORY_TEMPLATE"
          remoteRef = { key = "39b92426-09c4-4a74-8285-b40a00d62b4d" } #gitleaks:allow
        },
        {
          secretKey = "RESTIC_PASSWORD"
          remoteRef = { key = "07d70a7a-a6d9-4b0b-af1f-b40a00d649a9" } #gitleaks:allow
        },
        {
          secretKey = "AWS_ACCESS_KEY_ID"
          remoteRef = { key = "adb66319-d083-4379-afd5-b40a00d66963" } #gitleaks:allow
        },
        {
          secretKey = "AWS_SECRET_ACCESS_KEY"
          remoteRef = { key = "70ebd8f2-8270-46d8-8953-b40a00d6854f" } #gitleaks:allow
        },
      ]
    }
  }
}

resource "kubernetes_manifest" "volsync_rs" {
  manifest = {
    apiVersion = "volsync.backube/v1alpha1"
    kind       = "ReplicationSource"
    metadata = {
      name      = "coder-${local.workspace_id}"
      namespace = "coder"
    }
    spec = {
      sourcePVC = kubernetes_persistent_volume_claim_v1.home.metadata[0].name
      trigger = {
        schedule = "0 */6 * * *"
      }
      restic = {
        copyMethod        = "Snapshot"
        pruneIntervalDays = 14
        repository        = "coder-${local.workspace_id}-restic-secret"
        retain = {
          daily   = 6
          weekly  = 4
          monthly = 2
        }
        moverSecurityContext = {
          runAsUser  = 0
          runAsGroup = 0
          fsGroup    = 0
        }
      }
    }
  }

  depends_on = [kubernetes_manifest.volsync_es]
}
