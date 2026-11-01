---
name: feedback_push_and_pr_after_branch
description: Push and open a PR only on an explicit instruction or when plainly part of the assigned task; there is no standing authorization (owner decision D4, 2026-11-01)
metadata:
  node_type: memory
  type: feedback
  originSessionId: 871abdb7-e3e8-4f25-9f33-631b5c8c9860
---

Push a branch and run `gh pr create` only when the user says so, or when it is plainly part of the task you were assigned. Committing on the feature branch is allowed; pushing and opening the PR are not automatic. When the work is committed and neither applies, report the state and ask.

**Why:** the user does want work to reach GitHub for review, and an earlier version of this note said to push and open a PR after every commit. On 2026-11-01 the owner decided (D4 in the hybrid workflow plan) that there is no standing authorization for DELIVERY: a PR, its checks and its eventual merge are the user's call, and a merge may deploy. The rule lives in `AGENTS.md` ("Permissions and Consent") and `.agents/policy/permissions.md`.

**How to apply:** after `git commit` on a feature or chore branch, stop and report. Push and `gh pr create` on an instruction such as "push and open the PR", or when the assigned task says to deliver a PR. Never merge without fresh consent.
