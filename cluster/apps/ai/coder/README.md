# Coder OSS Sandbox Platform

Self-hosted developer workspaces running on Kubernetes, managed by [Coder OSS](https://coder.com/).
Each workspace is a long-lived pod backed by a persistent home directory, exposed via a fixed LoadBalancer IP for direct SSH access.

Coder URL: `https://coder.<private-domain>`

## Architecture

```
Coder (Helm, coder namespace)
 ├── PostgreSQL (CNPG)
 ├── workspace-template/ (Terraform)
 │    └── per-workspace: Deployment + PVC + LB Service + ExternalSecret + ReplicationSource
 └── hermes-agent profiles → SSH terminal backend → workspace IPs
```

**Provisioner**: the `coder` ServiceAccount runs Terraform inside the cluster.
It needs RBAC for every resource type it manages — see `templates/rbac-services.yaml`.

**Secrets**: OIDC credentials and VolSync restic repo settings come from Bitwarden via `ExternalSecret`.

## Workspaces

| Workspace | Profile in Hermes | Image | SSH IP | Use case |
|-----------|------------------|-------|--------|----------|
| devops | `devops` | `sandbox-devops:rolling` | 192.168.48.51 | Infrastructure, K8s, GitOps, Terraform, Ansible |
| dotnet | `dotnet-dev` | `sandbox-dotnet:rolling` | 192.168.48.52 | .NET / C# development |
| node | `node-dev` | `sandbox-node:rolling` | 192.168.48.53 | Node.js / TypeScript development |
| mobile | `mobile-dev` | `sandbox-node:rolling` | 192.168.48.54 | Mobile / React Native development |
| researcher | `researcher` | `sandbox-python:rolling` | 192.168.48.55 | Python, data science, AI research |

**Resource limits per workspace**: 500m–1000m CPU, 1–2 Gi RAM, 20 Gi home PVC (ceph-block, RWO).

**Backup**: VolSync restic ReplicationSource runs every 6 h, retains 6 daily / 4 weekly / 2 monthly snapshots.

## Workspace Images

Images live at `ghcr.io/mmalyska/sandbox-{base,devops,dotnet,node,python}:rolling`.
The `:rolling` tag is rebuilt automatically; `sandbox-base` is the common layer.

---

## Operations

### Push a new template version

After editing `workspace-template/main.tf`:

```bash
cd cluster/apps/ai/coder/workspace-template
coder --url https://coder.<private-domain> templates push sandbox --directory . --yes
```

Existing workspaces are **not** automatically rebuilt — they will show `OUTDATED: true` in `coder list`.

### Update workspaces to the latest template version

Rebuild all workspaces one by one (stops → reprovisioned → starts):

```bash
for ws in devops dotnet node mobile researcher; do
  coder --url https://coder.<private-domain> start --yes mmalyska/$ws
done
```

Or trigger a specific one from the Coder UI: workspace → **Update** → confirm.

> The deployment uses `Recreate` strategy; the RWO PVC is safely released before the new pod starts.

### Update workspaces when a new Docker image arrives

Images use `:rolling`, so the pod already pulls the latest on next start.
To force all workspaces to pick up a new image immediately:

```bash
for ws in devops dotnet node mobile researcher; do
  coder --url https://coder.<private-domain> restart --yes mmalyska/$ws
done
```

To update a single workspace:
```bash
coder --url https://coder.<private-domain> restart --yes mmalyska/devops
```

### Check workspace status

```bash
coder --url https://coder.<private-domain> list
```

### Open a shell in a workspace

Via Coder agent (no SSH key needed):
```bash
coder --url https://coder.<private-domain> ssh mmalyska/devops
```

Via direct SSH (from any host with the private key):
```bash
ssh -i <sandbox-devops-private-key> coder@192.168.48.51
```

### Create a new workspace

```bash
coder --url https://coder.<private-domain> create <name> \
  --template sandbox \
  --parameter workspace_image=ghcr.io/mmalyska/sandbox-devops:rolling \
  --parameter lb_ip=192.168.48.XX \
  --parameter authorized_key="ssh-ed25519 AAAA..." \
  --parameter storage_size=20Gi
```

Pick an unused IP from the `coder-pool` range: **192.168.48.51–70**.

After creating, add the corresponding Hermes profile SSH config:
```bash
kubectl exec deploy/hermes-agent -n hermes-agent -c hermes-agent -- \
  python3 /tmp/configure_hermes_ssh.py   # re-run after updating the script with the new profile
```

---

## Hermes Agent SSH Integration

Each Hermes profile's `terminal.backend` is set to `ssh` so the AI agent executes commands directly in the workspace over SSH.

Config per profile (`/opt/data/profiles/<name>/config.yaml`):
```yaml
terminal:
  backend: ssh
  ssh_host: 192.168.48.5X
  ssh_user: coder
  ssh_port: 22
  ssh_key: /opt/data/profiles/<name>/.ssh/id_sandbox
```

Private keys are seeded from `SANDBOX_*_SSH_KEY` env vars (loaded from Bitwarden via `ExternalSecret` in `values.yaml`) and written to `/opt/data/profiles/<name>/.ssh/id_sandbox` on the PVC — they survive pod restarts.

If a key needs to be re-seeded (e.g. after PVC recreation):
```bash
kubectl exec deploy/hermes-agent -n hermes-agent -c hermes-agent -- \
  python3 -c "
import os
profiles = {
  'devops':     ('192.168.48.51', 'SANDBOX_DEVOPS_SSH_KEY'),
  'dotnet-dev': ('192.168.48.52', 'SANDBOX_DOTNET_DEV_SSH_KEY'),
  'node-dev':   ('192.168.48.53', 'SANDBOX_NODE_DEV_SSH_KEY'),
  'mobile-dev': ('192.168.48.54', 'SANDBOX_MOBILE_DEV_SSH_KEY'),
  'researcher': ('192.168.48.55', 'SANDBOX_RESEARCHER_SSH_KEY'),
}
for name, (ip, env) in profiles.items():
    key = os.environ.get(env, '').strip()
    if not key: continue
    ssh_dir = f'/opt/data/profiles/{name}/.ssh'
    os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
    path = f'{ssh_dir}/id_sandbox'
    open(path, 'w').write(key + '\n')
    os.chmod(path, 0o600)
    print(f'seeded {name}')
"
```

---

## Troubleshooting

**Workspace stuck in `Starting`**: check agent connectivity.
```bash
kubectl logs -n coder -l app.kubernetes.io/instance=mmalyska-<name> -c workspace
```

**SSH `Permission denied (publickey)`**: the most common cause is group-writable `/home/coder`
(PVC mounted with `fs_group=1000` sets root:1000 ownership). Fix live:
```bash
kubectl exec -n coder deploy/coder-mmalyska-<name> -- bash -c \
  'chown coder:coder /home/coder && chmod 755 /home/coder'
```
The workspace template startup script already does this for new workspaces.

**`pipes_left_open` exit 255 in startup script**: sshd must be redirected to `/dev/null`:
```bash
/usr/sbin/sshd -D >/dev/null 2>&1 &
```
This is already in the current template.

**MultiAttach PVC error on update**: the deployment uses `Recreate` strategy, so this should not occur.
If it does, the old pod is stuck — delete it manually:
```bash
kubectl delete pod -n coder <old-pod-name>
```

**VolSync backup failing**: check the ExternalSecret is synced and the restic secret exists:
```bash
kubectl get externalsecrets,replicationsources -n coder
kubectl describe replicationsource coder-mmalyska-<name> -n coder
```
