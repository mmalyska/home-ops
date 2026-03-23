# home-ops Repository Memory

## Memory Location
**Always write memory files to `/workspaces/home-ops/.claude/memory/`** — the devcontainer symlinks them to the Claude path on start. `/home/vscode/.claude/projects/...` is ephemeral and lost on rebuild.

## Standing Rules
- **Always verify rendered output after Helm/Kustomize changes** — [feedback_render_verification.md](feedback_render_verification.md)
- **Always update docs proactively after changes** — [feedback_docs_updates.md](feedback_docs_updates.md)
- **Always check for native Gateway API support before writing manual HTTPRoute templates** — [feedback_check_native_gateway_support.md](feedback_check_native_gateway_support.md)
- **Save learned skills to `/workspaces/home-ops/.claude/skills/learned/`**, not `~/.claude/` — [feedback_skill_location.md](feedback_skill_location.md)
- NEVER write secrets, tokens, passwords, or sensitive data to any repo file
- The private domain is a secret — use `<secret:private-domain>` placeholder only
- Secret values belong in Bitwarden Secrets Manager only

## Memory Files

| File | Type | Summary |
|------|------|---------|
| [project_secrets_architecture.md](project_secrets_architecture.md) | project | Bitwarden-only secrets, 3 mechanisms, ESO gotchas |
| [project_gateway_dns.md](project_gateway_dns.md) | project | Two-gateway setup, dns-controller annotation gotcha, static DNSEndpoints |
| [reference_local_access.md](reference_local_access.md) | reference | kubectl/talosctl/terraform/argocd permission rules and CLI details |
| [feedback_render_verification.md](feedback_render_verification.md) | feedback | Run helm template / kustomize build after every values change |
| [feedback_docs_updates.md](feedback_docs_updates.md) | feedback | Proactively update README/CLAUDE.md/docs after changes; memory file location |
| [feedback_check_native_gateway_support.md](feedback_check_native_gateway_support.md) | feedback | Check upstream chart for native HTTPRoute support BEFORE writing manual templates/httproute.yaml |
| [feedback_skill_location.md](feedback_skill_location.md) | feedback | Learned skills go to /workspaces/home-ops/.claude/skills/learned/, not ~/.claude/ |
