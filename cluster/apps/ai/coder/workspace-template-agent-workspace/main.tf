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
# Unlike that template, this one creates everything its workspace needs in the namespace agent-workspaces: the two
# PVCs, the ServiceAccount, the Talos credential, the BWS token Secret and the VolSync backups. The Coder provisioner
# has a Role there (cluster/apps/ai/agent-workspaces) and ValidatingAdmissionPolicies cap what it can ask for: Talos
# credentials only with the os:reader role, ExternalSecrets only for the Bitwarden references allowed in that app's
# values.yaml. Deleting a workspace deletes its PVCs; the restic backups in the bucket stay.

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "coder_parameter" "bws_access_token_ref" {
  name         = "bws_access_token_ref"
  display_name = "BWS access token reference"
  description  = "Bitwarden secret ID that holds this workspace's BWS machine token. It must be listed in allowedBwsRefs in cluster/apps/ai/agent-workspaces/values.yaml, or the cluster refuses the ExternalSecret."
  type         = "string"
  mutable      = false
  order        = 1
}

data "coder_parameter" "bws_project_id_ref" {
  name         = "bws_project_id_ref"
  display_name = "BWS project ID reference"
  description  = "Bitwarden secret ID that holds the ID of this workspace's BWS project. Must be listed in allowedBwsRefs as well."
  type         = "string"
  mutable      = false
  order        = 2
}

data "coder_parameter" "home_size" {
  name         = "home_size"
  display_name = "Home volume size"
  description  = "Logins, config and tools added with mise. Backed up every 6 h."
  type         = "string"
  default      = "5Gi"
  mutable      = false
  order        = 3
}

data "coder_parameter" "src_size" {
  name         = "src_size"
  display_name = "Source volume size"
  description  = "Mounted at /workspaces. Backed up daily."
  type         = "string"
  default      = "30Gi"
  mutable      = false
  order        = 4
}

data "coder_parameter" "arch" {
  name         = "arch"
  display_name = "Architecture"
  description  = "Platform of the image to run; the pod is scheduled on a node of this architecture."
  type         = "string"
  default      = "amd64"
  mutable      = false
  order        = 5
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

  bws_secret = "${local.ws}-bws"

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
  image = "ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:76a0c4f0359029fa9ce976a39b87d7770bb332c56336e7ea673d753a0dc30f98"

  labels = {
    "app.kubernetes.io/name"       = "agent-workspace"
    "app.kubernetes.io/instance"   = local.ws
    "app.kubernetes.io/managed-by" = "coder"
  }

  # Runs before the Coder agent starts, so every process in the pod (agent, terminals, ssh sessions, VS Code server,
  # Claude Code, Codex and the commands they run) inherits the workspace's BWS secrets as environment variables. Nothing
  # is written to disk. Secrets are read once per pod start: rotate one in BWS and restart the workspace to pick it up.
  # Skipped on purpose: SSH_SIGNING_KEY (it lives only in the ssh-agent), multi-line values, keys that are not valid
  # variable names, and names that would break the pod (PATH, HOME, LD_*, CODER_*, BWS_*). A failure is logged and does
  # not stop the agent. The value is never printed.
  #
  # The bws CLI caches its login state in a state directory (default ~/.config/bws/state on the home volume) and keys its
  # config file by the access token's identifier. Both go to the rebuildable /cache instead (BWS_CONFIG_FILE is set on the
  # container), so no BWS state reaches the home volume or its backup. The config is written here, before the first bws call.
  bws_dir = "/cache/bws"

  bws_env_loader = <<-EOT
    if [ -n "$${BWS_ACCESS_TOKEN:-}" ] && [ -n "$${BWS_PROJECT_ID:-}" ]; then
      mkdir -p "${local.bws_dir}" && chmod 700 "${local.bws_dir}" \
        && bws config state-dir "${local.bws_dir}/state" >/dev/null 2>&1 \
        || echo "bws state: could not move the state directory to ${local.bws_dir}; bws may write under ~/.config/bws" >&2
      if bws_json="$(timeout 30 bws secret list "$BWS_PROJECT_ID" -o json 2>/dev/null)" \
          && printf '%s' "$bws_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        while IFS= read -r -d '' bws_entry; do
          export "$${bws_entry%%=*}=$${bws_entry#*=}"
        done < <(printf '%s' "$bws_json" | jq -j '.[]
          | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
          | select(.key | test("^(SSH_SIGNING_KEY|PATH|HOME|PWD|SHELL|USER|LOGNAME|IFS|BASH_ENV|ENV|LD_.*|CODER.*|BWS_.*)$") | not)
          | select(.value | contains("\n") | not)
          | .key + "=" + .value + "\u0000"')
      else
        echo "bws env: could not read secrets from the BWS project; continuing without them" >&2
      fi
      unset bws_json bws_entry
    fi
  EOT

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
# the agent-workspaces app, so no binding is created here.
resource "kubernetes_service_account_v1" "workspace" {
  metadata {
    name      = local.ws
    namespace = local.namespace
    labels    = local.labels
  }
}

# Talos credential, role os:reader. Talos creates a Secret with the same name (key `config`, renewed by Talos).
# The cluster rejects any other role (ValidatingAdmissionPolicy agent-workspaces-talos-reader-only).
resource "kubernetes_manifest" "talos" {
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

# BWS machine token and project ID for the pod (read as environment variables). The references must be allowed in the
# agent-workspaces app (ValidatingAdmissionPolicy agent-workspaces-externalsecret-allowlist).
resource "kubernetes_manifest" "bws" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.bws_secret
      namespace = local.namespace
      labels    = local.labels
    }
    spec = {
      secretStoreRef  = { kind = "ClusterSecretStore", name = "bitwarden" }
      refreshInterval = "1h"
      target = {
        name           = local.bws_secret
        creationPolicy = "Owner"
        template = {
          engineVersion = "v2"
          data = {
            BWS_ACCESS_TOKEN = "{{ .BWS_ACCESS_TOKEN }}"
            BWS_PROJECT_ID   = "{{ .BWS_PROJECT_ID }}"
          }
        }
      }
      data = [
        { secretKey = "BWS_ACCESS_TOKEN", remoteRef = { key = data.coder_parameter.bws_access_token_ref.value } },
        { secretKey = "BWS_PROJECT_ID", remoteRef = { key = data.coder_parameter.bws_project_id_ref.value } },
      ]
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
          command = ["bash", "-c", "${local.bws_env_loader}\n${coder_agent.main.init_script}"]

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
          # bws config and state live on /cache, not on the backed-up home volume (see bws_dir). Set on the container, so the
          # loader, the agent and every session inherit it.
          env {
            name  = "BWS_CONFIG_FILE"
            value = "${local.bws_dir}/config"
          }
          # The scoped BWS machine token and its project (D31). Read from a Secret; no secret value
          # passes through Terraform variables or state.
          env {
            name = "BWS_ACCESS_TOKEN"
            value_from {
              secret_key_ref {
                name = local.bws_secret
                key  = "BWS_ACCESS_TOKEN"
              }
            }
          }
          env {
            name = "BWS_PROJECT_ID"
            value_from {
              secret_key_ref {
                name = local.bws_secret
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
        volume {
          name = "talos"
          secret {
            secret_name = "${local.ws}-talos"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim_v1.volume,
    kubernetes_service_account_v1.workspace,
    kubernetes_manifest.talos,
    kubernetes_manifest.bws,
  ]
}
