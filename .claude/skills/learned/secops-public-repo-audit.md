---
name: secops-public-repo-audit
description: "Security audit checklist for public GitOps/home-lab repos — verify git tracking before escalating findings"
user-invocable: false
origin: auto-extracted
---

# SecOps Audit — Public Home-Lab Repo

**Extracted:** 2026-03-24
**Context:** Auditing a public GitHub repo (home-ops / GitOps pattern) for information leaks

## Problem
Security audits of home-lab repos often flag generated config files (Talos machine configs,
Terraform state, kubeconfigs) as CRITICAL — but these files are frequently gitignored and
never actually on GitHub. Escalating without verifying wastes effort and creates false urgency.

## Solution

### Step 1 — Verify git tracking before escalating
```bash
# Is the file tracked?
git ls-files <path>

# Has it EVER been committed (even if deleted)?
git log --all --oneline -- <path>

# What's gitignored in that directory?
cat <dir>/.gitignore
```
Only escalate to CRITICAL if `git ls-files` returns the file AND it contains real secrets.

### Step 2 — Audit checklist for public GitOps repos

| Area | What to check | Common false positives |
|------|--------------|----------------------|
| Generated configs | `clusterconfig/*.yaml`, `kubeconfig`, `talosconfig` | Usually gitignored |
| Terraform state | `terraform.tfstate`, `.tfvars` | Usually gitignored |
| Secret UUIDs | Bitwarden/Vault UUIDs in `.tf` files | Useless without auth token |
| Encrypted files | `*.sec.yaml`, SOPS files | Encrypted — check the algo |
| Network topology | IPs, hostnames in docs | RFC1918 = unreachable from internet |
| Domain names | Real domain in committed files | Check if Cloudflare proxied |

### Step 3 — Assess Cloudflare Tunnel setups
If the repo uses Cloudflare Tunnel + proxying:
- DNS records resolve to Cloudflare IPs, NOT the home router IP
- Network topology docs (RFC1918 IPs) are **not exploitable** from the internet
- Check if dyndns is disabled — if so, public IP is never in DNS

## When to Use
- When asked to do a SecOps / security review of a public home-lab or GitOps repo
- Before escalating any finding involving generated config files
