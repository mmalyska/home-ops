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

3. **Redeploy each running workspace** with `coder update <owner>/<workspace>` — not `coder restart`, which keeps the workspace on its old template version. `update` has **no `-y`/`--yes` flag** (unlike `create`), but it does not prompt interactively as long as no parameter values changed, so it completes non-interactively in that case.

4. **Run updates one at a time, not looped with combined output capture.** Each `update` does a full stop → plan → apply → start cycle (roughly 30–90s). Piping several sequential `coder update` calls into one shell command easily exceeds a 2-minute tool timeout across multiple workspaces — invoke each as its own command instead.

5. **Verify:**
   ```bash
   coder list
   ```
   Confirm `STATUS` is `Started`, `HEALTHY` is `true`, and `OUTDATED` is `false` for every workspace.

## When to Use

After merging any change to `cluster/apps/ai/coder/workspace-template/main.tf` that should apply to already-running workspaces.
