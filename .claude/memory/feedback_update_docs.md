---
name: Always update docs after code changes
description: After any non-trivial change, proactively update README.md, CLAUDE.md, and docs/src/ without being asked
type: feedback
---

After any non-trivial change, proactively check and update README.md, CLAUDE.md, and docs/src/ without being asked. Check for: new tasks → update Key Tasks in CLAUDE.md; new app-config.yaml fields → update schema; changed bootstrap flow → update all three bootstrap docs; new doc pages → add to mkdocs.yml nav.

**Why:** User has had to remind Claude multiple times.

**How to apply:** After finishing any feature/fix, scan CLAUDE.md and relevant docs for sections that need updating before calling the work done.
