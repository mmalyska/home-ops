---
name: feedback-no-domain-in-comments
description: Never write the literal private domain (or any hostname derived from it) into any tracked file, including comments and memory files — not just secret values
metadata:
  type: feedback
---

The private domain must never appear literally in any file that gets committed
or persisted to the repo — including YAML comments, docstrings, skill/doc files,
and this memory system itself (`.claude/memory/` is git-tracked in the main repo)
— even when it's not technically a "secret" in the gitleaks sense.

**Why:** Caught twice in one session. First, in a `values.yaml` comment
explaining an `allow_local_remote_servers` fix for OIDC discovery, I wrote the
literal provider hostname into the comment before it was committed. Then, while
writing the memory entry *about* that mistake, I wrote the literal domain again
inside the memory file's explanation text — which is itself persisted to GitHub.
The user's reaction was sharp both times: "why you did it against directions of
not leaking private domain. Enforce that it never happens again" and then "now
you leaked domain in memory!!! remember memory is persisted in github." This is
broader than the existing gitleaks-enforced "never commit secret values" rule —
it covers plain hostnames too, anywhere, including prose and meta-discussion
about the rule.

**How to apply:**
- When writing comments/docs/memory that need to reference "the OIDC provider
  host" or "the app's public hostname," describe it generically — never spell
  out the actual domain, even as an example or when explaining a past mistake.
- This applies to `.claude/memory/*.md` files exactly as much as repo source
  files, since that directory is git-tracked and pushed like anything else.
- Applies even in draft/uncommitted edits — check before writing the file at
  all, not just before staging or pushing.
- Relates to [[project_secrets_architecture]] (the `<secret:key>` token
  convention already used for domains in values.yaml `hostnames:`/
  `trustedDomains:` fields) — comments and memory should follow the same
  discipline as functional fields, even though they aren't template-substituted.
- Before finalizing any commit or memory write, grep the new content for the
  private domain string as a last check if a comment, doc, or memory file was
  touched.
