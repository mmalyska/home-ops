# Hermes Agent — Discord Integration Design

**Date:** 2026-05-26  
**Status:** Approved

## Goal

Add Discord as a second messaging channel for the hermes-agent, alongside the existing Signal integration. The bot token and allowed-users list are stored in Bitwarden and injected as env vars; all other Discord settings use hermes-agent defaults.

## Architecture

No new containers or services. Discord runs inside the existing `hermes-agent` gateway process. Two changes to existing manifests:

- `externalsecret.yaml` — two new Bitwarden secret references
- `deployment.yaml` — two new env vars on the `hermes-agent` container

## Changes

### externalsecret.yaml

Add under `spec.data`:

```yaml
- secretKey: DISCORD_BOT_TOKEN
  remoteRef:
    key: "<BITWARDEN_UUID>" #gitleaks:allow #HERMES_DISCORD_BOT_TOKEN
- secretKey: DISCORD_ALLOWED_USERS
  remoteRef:
    key: "<BITWARDEN_UUID>" #gitleaks:allow #HERMES_DISCORD_ALLOWED_USERS
```

### deployment.yaml

Add to the `hermes-agent` container `env` list:

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

## Default Behavior

With only these two env vars set, hermes-agent applies these Discord defaults:

| Setting | Default | Meaning |
|---|---|---|
| `require_mention` | `true` | Bot only responds when @mentioned in server channels |
| `auto_thread` | `true` | Creates a thread on each @mention |
| `history_backfill` | `true` | Recovers missed messages on mention |
| `allow_mentions.everyone` | `false` | Blocks @everyone/@here pings |
| `allow_mentions.users` | `true` | Allows @user pings |

DMs to the bot always work regardless of `require_mention`.

---

## How to Create and Configure the Discord Bot

### 1. Create an Application

1. Go to [Discord Developer Portal](https://discord.com/developers/applications)
2. Click **New Application**, give it a name (e.g. `hermes`)
3. Under **Bot** tab: click **Add Bot**
4. Set **Public Bot** to ON if you want others to invite it; OFF for personal use

### 2. Enable Privileged Gateway Intents

Still under the **Bot** tab, enable both:

- **Server Members Intent** — required for username resolution
- **Message Content Intent** — **critical**: without this the bot receives message events but the message text is empty

### 3. Get the Bot Token

Under **Bot** tab → **Token** → click **Reset Token**.  
Copy the token — you will store this as `DISCORD_BOT_TOKEN` in Bitwarden.

### 4. Set Required Permissions

When generating the invite URL (see step 6), grant at minimum:

- View Channels
- Send Messages
- Read Message History
- Attach Files
- Embed Links
- Send Messages in Threads
- Add Reactions

### 5. Collect Allowed User IDs

To find a user's Discord ID: in Discord, enable **Developer Mode** (User Settings → Advanced → Developer Mode), then right-click any user → **Copy User ID**.

The value for `DISCORD_ALLOWED_USERS` is a comma-separated list of these IDs, e.g. `123456789012345678,987654321098765432`.

### 6. Invite the Bot to Your Server

Go to **Installation** tab in the Developer Portal, or build the URL manually:

```
https://discord.com/api/oauth2/authorize?client_id=<YOUR_APP_ID>&permissions=<PERMISSIONS_INT>&scope=bot
```

Open the URL and select the target server.

### 7. Store Secrets in Bitwarden

Create two secrets in Bitwarden Secrets Manager:

| Secret name | Value |
|---|---|
| `HERMES_DISCORD_BOT_TOKEN` | The bot token from step 3 |
| `HERMES_DISCORD_ALLOWED_USERS` | Comma-separated user IDs from step 5 |

Note the UUIDs for each — you will substitute them into `externalsecret.yaml`.

---

## Out of Scope

- `DISCORD_HOME_CHANNEL` — not added; can be added later if proactive notifications are needed
- `DISCORD_ALLOWED_ROLES` — not added; individual user IDs are sufficient for now
- `discord:` configmap section — defaults are acceptable; add only when a setting needs changing
