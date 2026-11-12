# New repository requirements

Every non-archived repository under `mmalyska` must meet these requirements. Hermes depends on them: it merges only Renovate PRs, only where the rules below make an owner approval a GitHub rule, and it reads them with gate G5 of the
[Hermes merge policy](https://github.com/mmalyska/home-ops/blob/main/.agents/policy/hermes-merge-policy.md). Set them up when the repository is created.

## 1. CODEOWNERS

Create `.github/CODEOWNERS` with this line:

```text
* @rudi-the-brain @mmalyska
```

`agent-rosie` is not a code owner, so an approval from that account does not satisfy code-owner review.

## 2. Default-branch ruleset

Create a ruleset that targets the default branch (`~DEFAULT_BRANCH`) with these rules:

- a pull request is required, with 1 approval
- code-owner review is required
- approval of the most recent push is required
- stale approvals are dismissed when new commits are pushed
- force pushes and branch deletion are blocked
- the only bypass actor is the repository admin role (the Renovate app is not a bypass actor)

If the repository has CI checks, add them as required status checks. If a ruleset already exists, extend it instead of adding a conflicting second one.

## 3. Labels

Create the three triage labels:

| Label           | Color    | Meaning                          |
| --------------- | -------- | -------------------------------- |
| `triage/needed` | `fbca04` | Not checked, or the diff changed |
| `triage/clean`  | `0e8a16` | Passed every gate                |
| `triage/owner`  | `d93f0b` | Waiting for the owner            |

For example: `gh label create triage/needed --repo mmalyska/<repo> --color fbca04`.

## 4. Label workflow

Add `.github/workflows/triage-label.yaml`. It calls the reusable workflow, which sets `triage/needed` on every push to a PR:

```yaml
name: "PR Triage Label"

on:
  pull_request:
    types: [synchronize]

permissions:
  contents: read

jobs:
  triage:
    name: Triage label
    uses: mmalyska/github-workflows/.github/workflows/pr-triage-label.yaml@main
    permissions:
      pull-requests: write
```

## 5. Renovate, not Dependabot

Dependency updates come from Renovate, run by the Renovate app (`app/bendo-bot`). Hermes checks only PRs opened by that app, so a Dependabot PR is never checked, labelled or merged.

- Add `.github/renovate.json5` extending `github>mmalyska/renovate-config`, with `timezone`, `gitAuthor` and `reviewers` as in `homelab-portal`.
- Add `.github/workflows/scheduled-renovate.yaml`, the hourly caller of `mmalyska/github-workflows/.github/workflows/run-renovate.yaml@main`, with the repository secrets `BOT_APP_ID` and
  `BOT_APP_PRIVATE_KEY`, and install the Renovate app on the repository.
- Do not add `.github/dependabot.yml`, and turn off Dependabot security updates in the repository settings: Renovate reads the same vulnerability alerts.

## 6. Secrets the cluster reads

The cluster has one External Secrets store, `bitwarden`, and it reads only the `cluster` Bitwarden project. A secret in any other project answers 404 to External Secrets, even when `bws` in the
devcontainer can read it. Create every secret that a cluster app uses in the `cluster` project.

A private key stored in Bitwarden must end with a newline. Without it, `ssh-keygen` and `ssh-add` fail with "error in libcrypto".

## What Hermes does when something is missing

- **Gate G5.** Hermes reads `rules/branches/<default branch>`, which needs no admin access. A repository that lacks the ruleset is treated as denylisted: no PR there is auto-merged, and the daily summary says so.
- **No CI checks.** A repository with no CI checks never auto-merges, because there is nothing for gate G3 to confirm.
- **Missing labels.** A bot PR with no `triage/*` label is treated as `triage/needed`.
- **Dependabot PRs.** Hermes never sees them. Merge them yourself, or move the repository to Renovate.
