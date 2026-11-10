---
name: coder-workspace-template-deploy
description: Push an updated Coder workspace Terraform template and redeploy running workspaces onto it. Use when workspace-template/main.tf changes (resources, volumes, etc.) need to reach live Coder workspaces.
user-invocable: false
origin: auto-extracted
---

# Coder Workspace Template Deploy

**Extracted:** 2026-07-07
**Context:** Editing `cluster/apps/ai/coder/workspace-template/main.tf` and needing the change (e.g. resource requests/limits) to actually reach the running workspaces.

## Problem

Committing a change to `workspace-template/main.tf` has zero effect on already-running Coder workspaces. The template must be pushed to the Coder server as a new version, and each workspace must be individually rebuilt onto that version.

## Solution

1. **Check CLI/server version match.** `coder whoami` prints a "version mismatch" warning (with the exact required version) if the local `coder` CLI is behind the server — commands still run, but reinstall to match and avoid edge-case failures:
   ```bash
   ARCH=$(dpkg --print-architecture)
   curl -sL "https://github.com/coder/coder/releases/download/<VERSION>/coder_<version-no-v>_linux_${ARCH}.tar.gz" \
     | tar -xzO ./coder | sudo tee /usr/bin/coder > /dev/null
   sudo chmod +x /usr/bin/coder
   ```
   Note the extracted path is `./coder`, not `coder` — the tarball stores it with a leading `./`.

2. **Push the new template version:**
   ```bash
   cd cluster/apps/ai/coder/workspace-template
   coder templates push sandbox --directory . -y
   ```
   The live template is named `sandbox` (the original design doc called it `sandbox-workspace` — that name was never actually used).

3. **Redeploy each running workspace** with `coder update <owner>/<workspace>` — not `coder restart`, which keeps the workspace on its old template version. `update` has **no `-y`/`--yes` flag**, and it can ask `Continue? (yes/no)` ("Updating your workspace will start the workspace on the active template version"). Without a terminal it then fails with `error: EOF` and changes nothing (seen 2026-11-10 on `agent-workspace`, CLI matching the server). Answer the prompt on stdin:

   ```bash
   echo yes | coder update <owner>/<workspace>
   ```

   Check `coder list` afterwards: `OUTDATED` must be `false`.

4. **Run updates one at a time, not looped with combined output capture.** Each `update` does a full stop → plan → apply → start cycle (roughly 30–90s). Piping several sequential `coder update` calls into one shell command easily exceeds a 2-minute tool timeout across multiple workspaces — invoke each as its own command instead.

5. **Verify:**
   ```bash
   coder list
   ```
   Confirm `STATUS` is `Started`, `HEALTHY` is `true`, and `OUTDATED` is `false` for every workspace.

## The `dev-workspace` template

A second template, `dev-workspace`, lives in the sibling directory `cluster/apps/ai/coder/workspace-template-dev-workspace/` (a sibling, so pushing `sandbox` never carries it). Same flow as above with these differences:

- Push from that directory and name the template `dev-workspace`:
  ```bash
  coder templates push dev-workspace --directory cluster/apps/ai/coder/workspace-template-dev-workspace --yes
  ```
  Pushing starts nothing. It is a RUNTIME_MUTATION, so ask first.
- The template creates one Deployment (`ws-<workspace>`) in the namespace `dev-workspace`. The PVCs (`<workspace>-home`, `<workspace>-src`), backups, RBAC, Talos credential and the BWS-token Secret are owned by GitOps (`cluster/apps/system/dev-workspace`), so a template change never touches the data and deleting a workspace keeps the volumes. A new object the pod needs is a change to that app, not to `main.tf`.
- Redeploy with `coder update <owner>/<workspace>` as above. The pod restarts, so `/cache` and `/tmp` are empty afterwards (accepted); `/home/vscode` and `/workspaces` survive.
- A new image is a digest bump in `main.tf`, then push and update. Always pin the digest, never the bare tag. Renovate tracks the digest-pinned `image` in each template's `main.tf` (custom manager in `.github/renovate/customManagers.json5`) and never auto-merges it, because a merge reaches no workspace until the template is pushed and the workspace updated. Before bumping by hand, check that the digest is a multi-arch index (`linux/amd64`, `linux/arm64`); without Docker, read it anonymously from `ghcr.io/v2/mmalyska/dev-workstation/manifests/<digest>` with a pull token from `ghcr.io/token`.
- A workspace checkout does not update itself: after a merge run `git pull --ff-only` in the workspace, and `direnv allow` if `.envrc` changed.
- Verify with `coder list` and `kubectl get pods -n dev-workspace` (read-only). `lost+found` in `/workspaces` is the ext4 root, and a ceph-csi `FailedMount` "Pod UUID already exists" at start is benign.

## The `agent-workspace` template

Third template, for AI agents, in `cluster/apps/ai/coder/workspace-template-agent-workspace/`. Push with
`coder templates push agent-workspace --directory <that dir> --yes` (RUNTIME_MUTATION, ask first). Unlike `dev-workspace`
it creates its own PVCs, ServiceAccount, Talos credential, ExternalSecrets and ReplicationSources in `agent-workspaces`,
so a workspace delete removes the volumes. A new Bitwarden reference needs a PR to `allowedBwsRefs` in
`cluster/apps/ai/agent-workspaces/values.yaml` first. `dev-workspace` and its running workspace stay untouched.

Usage guide for the workspace itself: `docs/src/k8s/remote-dev-workspace.md`.

## When to Use

After merging any change to `cluster/apps/ai/coder/workspace-template/main.tf` or `workspace-template-dev-workspace/main.tf` that should apply to already-running workspaces.
