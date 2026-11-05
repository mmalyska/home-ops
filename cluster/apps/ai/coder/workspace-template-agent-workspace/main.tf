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

# Agent workspace on the dev-workstation image. The template for AI agents (hermes and similar); the sibling
# `workspace-template-dev-workspace` stays the owner's personal workspace and is not touched by this one.
#
# Unlike that template, this one creates everything its workspace needs in the namespace agent-workspaces: the PVCs,
# the ServiceAccount, the optional Talos credential, the secrets and the VolSync backups. The Coder provisioner has a
# Role there (cluster/apps/ai/agent-workspaces) and ValidatingAdmissionPolicies cap what it can ask for: Talos
# credentials only with the os:reader role, ExternalSecrets only for the Bitwarden secret IDs allowed in that app's
# values.yaml. Deleting a workspace deletes its PVCs; the restic backups in the bucket stay.
#
# No BWS machine token reaches the pod (it could read the whole BWS project, free tier has one shared project). Each
# secret is fetched by its own ID through External Secrets and delivered as an environment variable.
#
# Access is flexible per workspace: GitHub token always, extra secrets, signing key, Kubernetes read access and Talos
# read access are parameters. The agent that drives the workspace (hermes) logs in over SSH on port 2222.

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "github_token_ref" {
  name         = "github_token_ref"
  display_name = "GitHub token (Bitwarden secret ID)"
  description  = "Optional. Bitwarden secret ID of a GITHUB_TOKEN for this workspace (a token that works against api.github.com, for example a fine-grained personal access token). Must be listed in allowedBwsRefs in cluster/apps/ai/agent-workspaces/values.yaml. Empty means no GitHub credential."
  type         = "string"
  default      = ""
  mutable      = false
  order        = 1
}

data "coder_parameter" "extra_secrets" {
  name         = "extra_secrets"
  display_name = "Extra secrets"
  description  = "Environment variables for this workspace, one NAME=<Bitwarden secret ID> per entry. Every ID must be allowlisted. Names must be valid variable names; PATH, HOME, LD_*, CODER*, SSH_* and a few others are refused."
  type         = "list(string)"
  default      = jsonencode([])
  mutable      = false
  order        = 2
}

data "coder_parameter" "signing_key_ref" {
  name         = "signing_key_ref"
  display_name = "Commit signing key (Bitwarden secret ID)"
  description  = "Optional. Secret ID of an SSH private key that signs this agent's commits. Loaded into an in-pod ssh-agent, never written to a volume. Empty means no signing key."
  type         = "string"
  default      = ""
  mutable      = false
  order        = 3
}

data "coder_parameter" "authorized_key" {
  name         = "authorized_key"
  display_name = "SSH public key"
  description  = "Public key that may log in over SSH (port 2222, user vscode) from the namespaces allowed in the agent-workspaces app. This is how hermes reaches the workspace. Coder access (coder ssh) is separate."
  type         = "string"
  mutable      = false
  order        = 4
}

data "coder_parameter" "kubernetes_access" {
  name         = "kubernetes_access"
  display_name = "Kubernetes read access"
  description  = "Mount the pod ServiceAccount token so kubectl can read the cluster (read-only role agent-workspaces-reader: no Secrets, no exec). Off: the pod has no Kubernetes identity."
  type         = "bool"
  default      = "false"
  mutable      = false
  order        = 5
}

data "coder_parameter" "talos_access" {
  name         = "talos_access"
  display_name = "Talos read access"
  description  = "Create an os:reader Talos credential and mount it (talosctl get/logs/health). Off: no Talos credential exists for this workspace."
  type         = "bool"
  default      = "false"
  mutable      = false
  order        = 6
}

data "coder_parameter" "home_size" {
  name         = "home_size"
  display_name = "Home volume size"
  description  = "Logins, config and tools added with mise. Backed up every 6 h."
  type         = "string"
  default      = "5Gi"
  mutable      = false
  order        = 7
}

data "coder_parameter" "src_size" {
  name         = "src_size"
  display_name = "Source volume size"
  description  = "Mounted at /workspaces. Backed up daily."
  type         = "string"
  default      = "30Gi"
  mutable      = false
  order        = 8
}

data "coder_parameter" "arch" {
  name         = "arch"
  display_name = "Architecture"
  description  = "Platform of the image to run; the pod is scheduled on a node of this architecture."
  type         = "string"
  default      = "amd64"
  mutable      = false
  order        = 9
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
  namespace = "agent-workspaces"
  # Unique per Coder workspace; names the Deployment, the PVCs, the ServiceAccount and the Talos Secret.
  ws = "${data.coder_workspace_owner.me.name}-${data.coder_workspace.me.name}"

  kubernetes_access = data.coder_parameter.kubernetes_access.value == "true"
  talos_access      = data.coder_parameter.talos_access.value == "true"
  signing           = data.coder_parameter.signing_key_ref.value != ""

  # Environment secrets: the optional GITHUB_TOKEN plus the NAME=<id> entries of the extra_secrets parameter.
  extra_entries = jsondecode(data.coder_parameter.extra_secrets.value)
  extra_valid   = [for e in local.extra_entries : can(regex("^[A-Za-z_][A-Za-z0-9_]*=[^=\\s]+$", e))]
  extra_secrets = { for e in local.extra_entries : split("=", e)[0] => split("=", e)[1] if can(regex("^[A-Za-z_][A-Za-z0-9_]*=[^=\\s]+$", e)) }
  github_token  = data.coder_parameter.github_token_ref.value != ""
  env_secrets   = merge(local.extra_secrets, local.github_token ? { GITHUB_TOKEN = data.coder_parameter.github_token_ref.value } : {})
  env_names     = sort(keys(local.env_secrets))
  has_env       = length(local.env_secrets) > 0
  reserved_env  = "^(PATH|HOME|PWD|SHELL|USER|LOGNAME|IFS|BASH_ENV|ENV|TALOSCONFIG|KUBECACHEDIR|LD_.*|CODER.*|SSH_.*|AUTHORIZED_KEY)$"

  # Variables copied for SSH sessions. sshd gives a login a fresh environment, so the startup script writes these
  # (when set) to a file that sshd reads (PermitUserEnvironment).
  ssh_env_names = concat(local.env_names, ["TALOSCONFIG", "KUBECACHEDIR", "SSH_AUTH_SOCK"])

  # Backed-up volumes: PVC suffix, size, schedule and retention. The restic repository path is agent-workspaces-<ws>-<suffix>.
  volumes = {
    home = {
      size     = data.coder_parameter.home_size.value
      schedule = "17 */6 * * *"
      retain   = { hourly = 8, daily = 7, weekly = 4, monthly = 2 }
    }
    src = {
      size     = data.coder_parameter.src_size.value
      schedule = "47 3 * * *"
      retain   = { hourly = 1, daily = 14, weekly = 4, monthly = 2 }
    }
  }

  # Pinned by digest, never by the bare tag (the 1.0.0 tag moves on every rebuild). Bump tag and digest
  # together after checking the multi-arch manifest.
  image = "ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:71335a56b4a6dd99f9105da136395963f24fd40f4832a0ce4d54e46b725e6fb5"

  labels = {
    "app.kubernetes.io/name"       = "agent-workspace"
    "app.kubernetes.io/instance"   = local.ws
    "app.kubernetes.io/managed-by" = "coder"
  }

  # Mount paths. /run/signing is a memory-backed emptyDir for the ssh-agent socket and the key copy; the key never
  # touches a disk. /run/signing-src is the Secret the key arrives in (a Secret volume is tmpfs on the node).
  signing_dir = "/run/signing"
  signing_src = "/run/signing-src"
  ssh_dir     = "/cache/sshd"
  talos_dir   = "/var/run/secrets/talos.dev"
}

resource "coder_agent" "main" {
  arch = data.coder_parameter.arch.value
  os   = "linux"

  env = merge(
    {
      # The in-pod ssh-agent that holds the signing key.
      SSH_AUTH_SOCK = "${local.signing_dir}/agent.sock"
      # kubectl's discovery cache goes to the rebuildable /cache, not to ~/.kube on the backed-up home volume.
      KUBECACHEDIR = "/cache/kube"
    },
    # Talos: the mounted Secret holds a read-only (os:reader) talosconfig that Talos renews every few hours.
    # The config has no nodes list: pass --nodes.
    local.talos_access ? { TALOSCONFIG = "${local.talos_dir}/config" } : {},
  )

  startup_script = <<-EOT
    #!/bin/bash
    set -u
    umask 077

    # Fill an empty home volume. Existing files are left alone; nothing else is seeded.
    cp -rn /etc/skel/. "$HOME"/ 2>/dev/null || true

    # Commit signing key: copy it from the mounted Secret into the memory volume, load it into an in-pod ssh-agent and
    # delete the copy. ssh-add refuses a group-readable key, hence the copy. Never written to a volume, never printed.
    if [ -s "${local.signing_src}/SSH_SIGNING_KEY" ]; then
      sock="${local.signing_dir}/agent.sock"
      [ -S "$sock" ] || ssh-agent -a "$sock" >/dev/null
      if ! SSH_AUTH_SOCK="$sock" ssh-add -l >/dev/null 2>&1; then
        key="${local.signing_dir}/key"
        cp "${local.signing_src}/SSH_SIGNING_KEY" "$key" && chmod 600 "$key"
        if SSH_AUTH_SOCK="$sock" ssh-add "$key" >/dev/null 2>&1; then
          echo "signing key loaded into the ssh-agent"
        else
          echo "signing key found but ssh-add failed"
        fi
        rm -f "$key"
      fi
    else
      echo "no signing key configured"
    fi

    # SSH for the agent that drives this workspace (hermes): sshd as vscode on 2222, key login only, no forwarding.
    # The host key lives on the home volume so the client's known_hosts stays valid across restarts. sshd comes from
    # the image (openssh-server); a missing binary is logged and does not stop the workspace.
    d="${local.ssh_dir}"
    mkdir -p "$d" "$HOME/.ssh/sshd" && chmod 700 "$d" "$HOME/.ssh" "$HOME/.ssh/sshd"
    if [ -x /usr/sbin/sshd ]; then
      [ -s "$HOME/.ssh/sshd/host_ed25519" ] || ssh-keygen -q -t ed25519 -N "" -f "$HOME/.ssh/sshd/host_ed25519"
      printf '%s\n' "$AUTHORIZED_KEY" > "$d/authorized_keys"
      : > "$d/environment"
      chmod 600 "$d/environment"
      for n in ${join(" ", local.ssh_env_names)}; do
        if [ -n "$${!n+x}" ]; then
          v="$${!n}"
          case "$v" in *$'\n'*) continue ;; esac
          printf '%s=%s\n' "$n" "$v" >> "$d/environment"
        fi
      done
      ln -sfn "$d/environment" "$HOME/.ssh/environment"
      cat > "$d/sshd_config" <<CFG
    Port 2222
    HostKey $HOME/.ssh/sshd/host_ed25519
    PidFile $d/sshd.pid
    AuthorizedKeysFile $d/authorized_keys
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    UsePAM no
    StrictModes no
    AllowUsers vscode
    AllowTcpForwarding no
    X11Forwarding no
    PermitUserEnvironment yes
    PrintMotd no
    CFG
      /usr/sbin/sshd -f "$d/sshd_config" >/dev/null 2>&1 && echo "sshd listening on 2222" || echo "sshd failed to start"
    else
      echo "sshd is not in this image: SSH on 2222 is unavailable (the Coder agent still works)"
    fi
  EOT
}

resource "kubernetes_persistent_volume_claim_v1" "volume" {
  for_each = local.volumes

  metadata {
    name      = "${local.ws}-${each.key}"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "ceph-block"
    resources {
      requests = {
        storage = each.value.size
      }
    }
  }
  wait_until_bound = false
}

# Identity of the pod for the Kubernetes API. The read-only ClusterRole is bound to the whole namespace group by
# the agent-workspaces app, so no binding is created here. Whether a workspace can use it is decided by mounting the
# token: without kubernetes_access the pod has no token and so no Kubernetes identity.
resource "kubernetes_service_account_v1" "workspace" {
  metadata {
    name      = local.ws
    namespace = local.namespace
    labels    = local.labels
  }
  automount_service_account_token = local.kubernetes_access
}

# Talos credential, role os:reader. Talos creates a Secret with the same name (key `config`, renewed by Talos).
# The cluster rejects any other role (ValidatingAdmissionPolicy agent-workspaces-talos-reader-only).
resource "kubernetes_manifest" "talos" {
  count = local.talos_access ? 1 : 0

  manifest = {
    apiVersion = "talos.dev/v1alpha1"
    kind       = "ServiceAccount"
    metadata = {
      name      = "${local.ws}-talos"
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      roles = ["os:reader"]
    }
  }
}

# Environment secrets, fetched one by one by Bitwarden secret ID (no BWS token in the pod). The Secret keys become the
# variable names. Every ID must be allowlisted (ValidatingAdmissionPolicy agent-workspaces-externalsecret-allowlist).
resource "kubernetes_manifest" "env" {
  # An ExternalSecret needs at least one key (the cluster policy refuses an empty one).
  count = local.has_env ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.ws}-env"
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      secretStoreRef  = { kind = "ClusterSecretStore", name = "bitwarden" }
      refreshInterval = "1h"
      target = {
        name           = "${local.ws}-env"
        creationPolicy = "Owner"
      }
      data = [for name in local.env_names : { secretKey = name, remoteRef = { key = local.env_secrets[name] } }]
    }
  }

  lifecycle {
    precondition {
      condition     = alltrue(local.extra_valid)
      error_message = "extra_secrets: every entry must look like NAME=<Bitwarden secret ID>, with NAME a valid variable name."
    }
    precondition {
      condition     = alltrue([for n in keys(local.extra_secrets) : !can(regex(local.reserved_env, n)) && n != "GITHUB_TOKEN"])
      error_message = "extra_secrets: names must not be GITHUB_TOKEN (it has its own parameter) or a reserved name (PATH, HOME, LD_*, CODER*, SSH_*, ...)."
    }
  }
}

# The commit signing key, in a Secret of its own so it never becomes an environment variable.
resource "kubernetes_manifest" "signing" {
  count = local.signing ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.ws}-signing"
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      secretStoreRef  = { kind = "ClusterSecretStore", name = "bitwarden" }
      refreshInterval = "1h"
      target = {
        name           = "${local.ws}-signing"
        creationPolicy = "Owner"
      }
      data = [{ secretKey = "SSH_SIGNING_KEY", remoteRef = { key = data.coder_parameter.signing_key_ref.value } }]
    }
  }
}

# Restic credentials, one repository per volume. The four references are the shared VolSync ones (charts/volsync) and
# are allowed in the agent-workspaces app; keep both lists equal.
resource "kubernetes_manifest" "restic" {
  for_each = local.volumes

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.ws}-${each.key}-restic"
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      secretStoreRef  = { kind = "ClusterSecretStore", name = "bitwarden" }
      refreshInterval = "1h"
      target = {
        name           = "${local.ws}-${each.key}-restic"
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            RESTIC_REPOSITORY     = "{{ .REPOSITORY_TEMPLATE }}/agent-workspaces-${local.ws}-${each.key}"
            RESTIC_PASSWORD       = "{{ .RESTIC_PASSWORD }}"
            AWS_ACCESS_KEY_ID     = "{{ .AWS_ACCESS_KEY_ID }}"
            AWS_SECRET_ACCESS_KEY = "{{ .AWS_SECRET_ACCESS_KEY }}"
          }
        }
      }
      data = [
        { secretKey = "REPOSITORY_TEMPLATE", remoteRef = { key = "39b92426-09c4-4a74-8285-b40a00d62b4d" } },   #gitleaks:allow
        { secretKey = "RESTIC_PASSWORD", remoteRef = { key = "07d70a7a-a6d9-4b0b-af1f-b40a00d649a9" } },       #gitleaks:allow
        { secretKey = "AWS_ACCESS_KEY_ID", remoteRef = { key = "adb66319-d083-4379-afd5-b40a00d66963" } },     #gitleaks:allow
        { secretKey = "AWS_SECRET_ACCESS_KEY", remoteRef = { key = "70ebd8f2-8270-46d8-8953-b40a00d6854f" } }, #gitleaks:allow
      ]
    }
  }
}

resource "kubernetes_manifest" "backup" {
  for_each = local.volumes

  manifest = {
    apiVersion = "volsync.backube/v1alpha1"
    kind       = "ReplicationSource"
    metadata = {
      name      = "${local.ws}-${each.key}"
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      sourcePVC = kubernetes_persistent_volume_claim_v1.volume[each.key].metadata[0].name
      trigger   = { schedule = each.value.schedule }
      restic = {
        accessModes             = ["ReadWriteOnce"]
        capacity                = each.value.size
        storageClassName        = "ceph-block"
        cacheCapacity           = each.value.size
        volumeSnapshotClassName = "csi-ceph-blockpool"
        copyMethod              = "Snapshot"
        pruneIntervalDays       = 14
        repository              = kubernetes_manifest.restic[each.key].manifest.spec.target.name
        retain                  = each.value.retain
        moverSecurityContext    = { runAsUser = 1000, runAsGroup = 1000, fsGroup = 1000 }
      }
    }
  }
}

# SSH entry for the agent that drives the workspace. ClusterIP only; the NetworkPolicy of the agent-workspaces app lets
# the configured client namespaces reach port 2222.
resource "kubernetes_service_v1" "ssh" {
  metadata {
    name      = "${local.ws}-ssh"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/instance" = local.ws
    }
    port {
      name        = "ssh"
      port        = 22
      target_port = 2222
      protocol    = "TCP"
    }
  }
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
        service_account_name            = local.ws
        automount_service_account_token = local.kubernetes_access

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
          # The public key allowed to log in over SSH; the startup script writes it to authorized_keys.
          env {
            name  = "AUTHORIZED_KEY"
            value = data.coder_parameter.authorized_key.value
          }
          # The optional GITHUB_TOKEN and the extra secrets, from the Secret that External Secrets fills (no value passes through
          # Terraform variables or state).
          dynamic "env_from" {
            for_each = local.has_env ? [1] : []
            content {
              secret_ref {
                name = "${local.ws}-env"
              }
            }
          }
          port {
            name           = "ssh"
            container_port = 2222
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
          dynamic "volume_mount" {
            for_each = local.talos_access ? [1] : []
            content {
              name       = "talos"
              mount_path = local.talos_dir
              read_only  = true
            }
          }
          dynamic "volume_mount" {
            for_each = local.signing ? [1] : []
            content {
              name       = "signing-src"
              mount_path = local.signing_src
              read_only  = true
            }
          }
        }

        # The two claims are created by this template and backed up by VolSync (see the ReplicationSources above).
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
        dynamic "volume" {
          for_each = local.talos_access ? [1] : []
          content {
            name = "talos"
            secret {
              secret_name = "${local.ws}-talos"
            }
          }
        }
        dynamic "volume" {
          for_each = local.signing ? [1] : []
          content {
            name = "signing-src"
            secret {
              secret_name  = "${local.ws}-signing"
              default_mode = "0440"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim_v1.volume,
    kubernetes_service_account_v1.workspace,
    kubernetes_manifest.talos,
    kubernetes_manifest.env,
    kubernetes_manifest.signing,
    kubernetes_service_v1.ssh,
  ]
}
