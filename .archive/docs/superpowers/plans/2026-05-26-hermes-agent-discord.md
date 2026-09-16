# Hermes Agent Discord Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Discord as a messaging channel for hermes-agent by wiring two Bitwarden secrets into the existing ExternalSecret and injecting them as env vars on the hermes-agent container.

**Architecture:** No new containers or services — Discord runs in-process inside the hermes-agent gateway. Two existing manifest files are modified: `externalsecret.yaml` gets two new Bitwarden secret refs, and `deployment.yaml` gets two new env vars that read from the resulting K8s Secret.

**Tech Stack:** Helm, Kubernetes ExternalSecret (ESO), Bitwarden Secrets Manager

---

## Prerequisites (manual steps before coding)

These are human actions, not code tasks. Complete them before starting Task 1.

- [ ] In the Discord Developer Portal, create a bot application and collect the bot token (see spec: `docs/superpowers/specs/2026-05-26-hermes-agent-discord-design.md` — "How to Create and Configure the Discord Bot").
- [ ] Enable **Server Members Intent** and **Message Content Intent** in the Bot tab.
- [ ] Collect the comma-separated Discord user IDs for `DISCORD_ALLOWED_USERS`.
- [ ] Create two secrets in Bitwarden Secrets Manager and note their UUIDs:
  - `HERMES_DISCORD_BOT_TOKEN` → the bot token string
  - `HERMES_DISCORD_ALLOWED_USERS` → comma-separated user IDs
- [ ] Invite the bot to your Discord server via the OAuth2 URL with the required permissions.

---

### Task 1: Add Discord secrets to ExternalSecret

**Files:**
- Modify: `cluster/apps/default/hermes-agent/templates/externalsecret.yaml`

- [ ] **Step 1: Add two secret entries to externalsecret.yaml**

  Open `cluster/apps/default/hermes-agent/templates/externalsecret.yaml`. After the existing `SIGNAL_HOME_CHANNEL` entry (line 29), add:

  ```yaml
      - secretKey: DISCORD_BOT_TOKEN
        remoteRef:
          key: "<BITWARDEN_UUID_BOT_TOKEN>" #gitleaks:allow #HERMES_DISCORD_BOT_TOKEN
      - secretKey: DISCORD_ALLOWED_USERS
        remoteRef:
          key: "<BITWARDEN_UUID_ALLOWED_USERS>" #gitleaks:allow #HERMES_DISCORD_ALLOWED_USERS
  ```

  Replace `<BITWARDEN_UUID_BOT_TOKEN>` and `<BITWARDEN_UUID_ALLOWED_USERS>` with the actual UUIDs from Bitwarden.

- [ ] **Step 2: Render to verify the template is valid**

  ```bash
  cd cluster/apps/default/hermes-agent
  helm template hermes-agent . -f values.yaml
  ```

  Expected: full manifest output with no errors. Verify the ExternalSecret contains both new `secretKey` entries.

- [ ] **Step 3: Commit**

  ```bash
  git add cluster/apps/default/hermes-agent/templates/externalsecret.yaml
  git commit -m "feat(hermes-agent): add Discord secrets to ExternalSecret"
  ```

---

### Task 2: Inject Discord env vars into the deployment

**Files:**
- Modify: `cluster/apps/default/hermes-agent/templates/deployment.yaml`

- [ ] **Step 1: Add env vars to the hermes-agent container**

  Open `cluster/apps/default/hermes-agent/templates/deployment.yaml`. After the `SIGNAL_HOME_CHANNEL` env var block (around line 98), add:

  ```yaml
            - name: DISCORD_BOT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: DISCORD_BOT_TOKEN
            - name: DISCORD_ALLOWED_USERS
              valueFrom:
                secretKeyRef:
                  name: hermes-agent-secrets
                  key: DISCORD_ALLOWED_USERS
  ```

  Maintain the same 12-space indentation as the surrounding env var entries.

- [ ] **Step 2: Render and inspect the deployment manifest**

  ```bash
  cd cluster/apps/default/hermes-agent
  helm template hermes-agent . -f values.yaml
  ```

  Expected: no errors. In the rendered Deployment, confirm the `hermes-agent` container env list includes both `DISCORD_BOT_TOKEN` and `DISCORD_ALLOWED_USERS` with `secretKeyRef.name: hermes-agent-secrets`.

- [ ] **Step 3: Run full lint**

  ```bash
  cd /workspaces/home-ops
  task lint:all
  ```

  Expected: all checks pass (yamllint, helmlint, prettier).

- [ ] **Step 4: Commit**

  ```bash
  git add cluster/apps/default/hermes-agent/templates/deployment.yaml
  git commit -m "feat(hermes-agent): inject Discord env vars into hermes-agent container"
  ```

---

### Task 3: Open PR

- [ ] **Step 1: Push branch and open PR**

  ```bash
  git push -u origin HEAD
  gh pr create \
    --title "feat(hermes-agent): add Discord integration" \
    --body "Adds DISCORD_BOT_TOKEN and DISCORD_ALLOWED_USERS to the hermes-agent ExternalSecret and deployment env vars. No new containers required — Discord runs in-process. Spec: docs/superpowers/specs/2026-05-26-hermes-agent-discord-design.md"
  ```

- [ ] **Step 2: After merge, verify in ArgoCD**

  Confirm ArgoCD syncs the `hermes-agent` app successfully. Check the hermes-agent pod logs for Discord gateway startup:

  ```bash
  kubectl logs -n hermes-agent deploy/hermes-agent | grep -i discord
  ```

  Expected: log lines indicating the Discord gateway connected (no auth errors).
