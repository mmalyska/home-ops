---
name: devcontainer-env-file
description: Docker --env-file keeps a trailing "# comment" and quotes in the value, so tokens look set but are rejected; the file is read only at container creation
metadata:
  type: reference
---

`.devcontainer/devcontainer.env` is passed with `runArgs --env-file`. Docker treats only whole lines starting with `#` as comments: `NAME=value   # note` makes the value `value   # note`, and quotes stay part of the value too. The variable then looks set (`[ -n "$NAME" ]` passes) but the service rejects it. Seen 2026-11-05 on the first rebuild on `dev-workstation`: `.envrc` logged `bws returned no secrets`, Terraform init failed with `unauthorized`, and with no BWS secrets `talos:init` was skipped (no talosconfig, so `task` prints `no context is set`). The old sample put comments on the value lines; the sample now keeps them on their own lines (#6123).

**Why:** the failure looks like a broken image or an expired token, not a formatting problem.

**How to apply:**

- Each line `NAME=value`, nothing after the value, no quotes, no `export`.
- The file is read only when the container is created: after a change, "Rebuild Container". A fresh "Clone ... in Container Volume" starts from the comment-only sample, so the order is clone, fill in, rebuild.
- To check without printing values: compare names in the file, in `/proc/1/environ` (what Docker passed) and in the shell; then test a value for a space, `#` or quote with a `case` pattern.
- The lifecycle scripts have no `set -e`: `Done!` at the end proves nothing; read the log for errors.
