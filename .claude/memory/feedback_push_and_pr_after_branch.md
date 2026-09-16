---
name: feedback_push_and_pr_after_branch
description: Always push the branch and create a GitHub PR immediately after committing work on a feature branch
metadata:
  node_type: memory
  type: feedback
  originSessionId: 871abdb7-e3e8-4f25-9f33-631b5c8c9860
---

Always push the branch to origin and create a PR via `gh pr create` immediately after finishing work on a feature branch and committing. Do not leave branches as local-only commits.

**Why:** User expects PRs to appear on GitHub as soon as work is ready — local commits are not visible and the user cannot review or merge them.

**How to apply:** After every `git commit` on a feature/chore branch, run `git push origin <branch>` then `gh pr create` before reporting the task as done.
