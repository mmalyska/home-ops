# Remove the Hermes / Honcho stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop running the Hermes agent stack (no affordable API access to feed it), archive its manifests so they can be restored with `git mv`, and trim Coder to the `devops` workspace.

**Architecture:** One PR moves the Hermes stack from `cluster/apps/ai/` to `.archive/cluster/ai/` (Renovate ignores `.archive/**`), deletes dead leftovers, and fixes docs. After merge, cluster cleanup (Applications, workspaces, namespaces, data, secrets) is done by hand, one confirmed step at a time, because `prune: false` means ArgoCD never removes anything.

**Tech Stack:** ArgoCD ApplicationSets, Helm, CNPG, Coder CLI, kubectl, Bitwarden Secrets Manager.

**Spec:** decisions below (no separate spec; the user decided in chat on 2026-10-21).

## Decisions (from the user)

- Remove `hermes-agent`, `honcho`, `llm/embeddings`, `llm/stt` (speaches). Reason: only a Claude subscription, which cannot be used with Hermes; API pricing is too high.
- **Archive, do not delete**, the Hermes stack so it can be restored when API pricing drops: `git mv` back and re-add the `llm` app-config entries.
- **Drop Honcho data** (CNPG DB `honchodb`, its S3 backups under `cnpg/honcho`). No final backup.
- **Keep** `llm/server` (llama-server on nv1; Lingarr uses it), nv1, `nvidia`, `node-feature-discovery`.
- **Keep** `coder`; remove the dotnet, node, mobile, researcher workspaces; keep `devops` running.
- Delete the disabled leftovers `ai/litellm`, `ai/open-webui`, `default/litellm`, `default/open-webui`.
- One PR.

## Global Constraints

- Branch `chore/remove-hermes-stack`, worktree `.worktrees/chore/remove-hermes-stack`; PR to `main`, never push to `main`.
- No Claude attribution in commits or the PR body.
- Never write the private domain literally in any file (use `<private-domain>`); grep before writing.
- Never commit secret values. Bitwarden ids already in `values.yaml` stay as-is when moved.
- Cluster mutations (`kubectl delete`, `coder delete`, Bitwarden deletes) need explicit user confirmation each time.
- Memory files live in `.claude/memory/` (git-tracked), not `~/.claude/`.

## Review Focus

- Archived app-configs must not be picked up by the ApplicationSet (it globs `cluster/apps/**`; `.archive` is outside it). Check the appset path glob.
- Removing the `embeddings` and `stt` entries from `llm/app-config.yaml` must leave `server` intact and valid YAML.
- Lingarr still resolves `llama-server.llm.svc.cluster.local` after the change (no rename).
- `docs/src/general/network.md` IP tables still match reality after the workspaces go (`.52`-`.55` free, `.51` kept).
- The `LlamaServer*` alert text in `llm/server/templates/prometheusrule.yaml` still renders and no longer claims Honcho or Hermes depend on it.
- Renovate `groups.json5` is still valid JSON5 after the Hermes rule is removed.

---

### Task 1: Archive the Hermes stack and delete dead leftovers

**Files:**
- Move: `cluster/apps/ai/hermes-agent` -> `.archive/cluster/ai/hermes-agent`
- Move: `cluster/apps/ai/honcho` -> `.archive/cluster/ai/honcho`
- Move: `cluster/apps/ai/llm/embeddings` -> `.archive/cluster/ai/llm-embeddings`
- Move: `cluster/apps/ai/llm/stt` -> `.archive/cluster/ai/llm-stt`
- Delete: `cluster/apps/ai/litellm`, `cluster/apps/ai/open-webui`, `cluster/apps/default/litellm`, `cluster/apps/default/open-webui`
- Modify: `cluster/apps/ai/llm/app-config.yaml` (drop the `embeddings` and `stt` entries)
- Create: `.archive/cluster/ai/README.md`
- Create: `.archive/cluster/ai/llm-embeddings/app-config.yaml`, `.archive/cluster/ai/llm-stt/app-config.yaml`

**Interfaces:**
- Produces: `.archive/cluster/ai/README.md` with the restore recipe (below); Task 3 links to it.

- [ ] **Step 1: Confirm the ApplicationSet path glob excludes `.archive`**

Run: `grep -rn "path:" cluster/appsets/*.yaml | head`
Expected: globs start at `cluster/apps/...`, nothing under `.archive`.

- [ ] **Step 2: `git mv` the four app directories**

Use `git mv` so history follows. Create `.archive/cluster/ai/` first.

- [ ] **Step 3: Give the two `llm` sub-apps standalone `app-config.yaml` files in the archive**

Each is the removed entry from `llm/app-config.yaml` with `appSubfolder` dropped and the sub-app restored under `cluster/apps/ai/llm/<embeddings|stt>` noted in the README (the entry needs `appSubfolder` again on restore). Keep namespace `llm`, same syncPolicy and `managedNamespaceMetadata`.

- [ ] **Step 4: Remove the `embeddings` and `stt` list items from `cluster/apps/ai/llm/app-config.yaml`**

Only the `server` item remains.

- [ ] **Step 5: `git rm -r` the four disabled leftover directories**

- [ ] **Step 6: Write `.archive/cluster/ai/README.md`**

Contents: why archived (2026-10-21, API pricing), what is in it, and the restore recipe:
1. `git mv .archive/cluster/ai/hermes-agent cluster/apps/ai/hermes-agent` (same for `honcho`).
2. `git mv .archive/cluster/ai/llm-embeddings cluster/apps/ai/llm/embeddings` (same for `llm-stt` -> `stt`) and re-add each as a list item in `cluster/apps/ai/llm/app-config.yaml` with `appSubfolder: embeddings|stt`.
3. Honcho needs a new, empty `honchodb` (data was dropped); Hermes needs fresh PVCs; re-create the Bitwarden secrets listed in each `externalsecret.yaml`.
4. Re-add the Renovate rule for `nousresearch/hermes-agent` (copy from git history of `.github/renovate/groups.json5`).
5. Re-check that Hermes' 64K per-slot context floor still matches `llm/server` (see `docs/src/k8s/nv1-jetson.md`).

- [ ] **Step 7: Render check**

Run: `cd cluster/apps/ai/llm/server && helm template llm-server . | head -5` and `yamllint cluster/apps/ai/llm/app-config.yaml`
Expected: renders, lint clean.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore(ai): archive the Hermes stack and remove dead litellm/open-webui"
```

### Task 2: Trim Renovate, the LLM alert text, and Coder docs

**Files:**
- Modify: `.github/renovate/groups.json5` (remove the "Hermes agent" packageRule, lines ~78-86)
- Modify: `cluster/apps/ai/llm/server/templates/prometheusrule.yaml:21` (reword the line that says Honcho/Hermes depend on the server; Lingarr is the consumer)
- Modify: `cluster/apps/ai/llm/server/values.yaml` (comments at lines ~20, 26, 40 that cite Hermes; reword to Lingarr or drop)
- Modify: `cluster/apps/ai/coder/README.md` (drop the dotnet/node/mobile/researcher rows, the Hermes profile column and sections "Hermes Agent SSH Integration", lines ~118-121 and ~126-150; keep devops)

- [ ] **Step 1: Delete the Hermes packageRule object** and confirm the file still parses: `python3 -c "import json5"` is unavailable, so run `npx --yes json5 .github/renovate/groups.json5 >/dev/null` or `task lint:all`.

- [ ] **Step 2: Reword the alert annotation and the `values.yaml` comments**, keeping behaviour (flags, limits) unchanged. Do not change any value.

- [ ] **Step 3: Edit the Coder README** so it describes only the `devops` workspace at `192.168.48.51` plus how to create further workspaces from the template (keep the "Pick an unused IP" guidance).

- [ ] **Step 4: Render and lint**

Run: `cd cluster/apps/ai/llm/server && helm template llm-server . >/dev/null && cd - && task lint:all`
Expected: no errors.

- [ ] **Step 5: Commit** `chore(ai): drop Hermes references from renovate, alerts and coder docs`

### Task 3: Docs and memory

**Files:**
- Modify: `docs/src/k8s/nv1-jetson.md` (Hermes-specific lines 74, 96, 110-119: keep the Gemma 4 single-slot facts that still matter for Lingarr, drop or compress Hermes-only testing notes; link to `.archive/cluster/ai/README.md` for the restore story)
- Modify: `docs/src/k8s/media.md:118` ("same GPU slot as Hermes" -> only Lingarr uses the slot now)
- Modify: `docs/src/general/network.md:164,192` (`.52`-`.55` released; `.51` = Coder `devops`; leave the `coder-pool` range itself alone)
- Modify: `.claude/memory/`: update `reference_hermes_64k_context_floor.md` and `reference_gemma4_single_slot_swap.md` (mark Hermes archived 2026-10-21), `reference_nv1_gpu_test_pause.md` if it names Hermes; update the `MEMORY.md` hook lines to match.
- Modify: `.plans/list.md` (add this plan), `.plans/TODO.md` (no Hermes items to remove; verify with `grep -i hermes .plans/TODO.md`)

- [ ] **Step 1: Edit each file as listed.** Do not touch `docs/src/audits/*` (historical) or `.archive/.plans/**`.

- [ ] **Step 2: Add the plan entry to `.plans/list.md`**: `| [remove-hermes-stack](superpowers/plans/2026-10-21-remove-hermes-stack.md) | (decisions in plan) | Archive Hermes/Honcho/embeddings/stt, trim Coder to devops | 2026-10-21 |`

- [ ] **Step 3: Verify no stale references**

Run: `grep -rn -i -E "hermes|honcho|speaches|llm-embeddings" cluster docs/src/k8s docs/src/general .github --include=* -I | grep -v -E "docs/src/audits"`
Expected: no hits except the intentional archive pointer in `nv1-jetson.md`.

- [ ] **Step 4: `task lint:all`**, then commit `docs: record the Hermes stack removal`.

### Task 4: Open the PR

- [ ] **Step 1: Push and open the PR**

```bash
git push -u origin chore/remove-hermes-stack
gh pr create --title "chore(ai): archive the Hermes stack and trim Coder" --body "<what moved, what stays, post-merge manual steps from the plan>"
```
Body has no Claude attribution. List the manual steps from Task 5 as a checklist.

### Task 5: Post-merge cluster cleanup (manual, each step confirmed by the user)

Order matters: Applications first so nothing recreates resources, then workloads, then data, then secrets.

- [ ] **Step 1: Check what is live**: `kubectl -n argocd get applications | grep -E "hermes|honcho|llm|litellm|open-webui"`; `kubectl get pvc -A | grep -E "hermes|honcho|llm-(embed|stt)|speaches|signal"`.
- [ ] **Step 2: Delete the Coder workspaces** dotnet, node, mobile, researcher with `coder --url https://coder.<private-domain> delete mmalyska/<name> --yes` (keep `devops`). Afterwards confirm their Deployments, PVCs, ReplicationSources and the `.52`-`.55` LoadBalancer services are gone; remove stragglers and their VolSync restic repos if the user agrees.
- [ ] **Step 3: Delete the Applications** `hermes-agent`, `honcho`, the `llm` embeddings and stt ones (names per step 1), and any lingering `litellm`/`open-webui` Application, one at a time (`kubectl -n argocd delete application <name>`; see `reference_app_removal_procedure` memory).
- [ ] **Step 4: Confirm the namespaces `hermes-agent`, `honcho` are empty, then delete them.** `honcho` includes the CNPG cluster `honchodb`: this is the confirmed Honcho data drop. Hermes data (PVCs `hermes`, `signal`, restic repo `.../hermes`) is **not yet confirmed for deletion**: ask the user before deleting those PVCs and the restic repo.
- [ ] **Step 5: Delete the `llm-embeddings-models` and speaches PVCs** in namespace `llm` (model downloads, re-fetchable).
- [ ] **Step 6: S3 cleanup**: remove `s3://k8s-at-home-backup/cnpg/honcho` on the QNAP (user does this or confirms the exact command).
- [ ] **Step 7: Bitwarden**: list the secrets used by Hermes/Honcho (`externalsecret.yaml` files in the archive, including the OpenRouter key id in `honcho/values.yaml`) and the sandbox SSH keys for the removed workspaces; the user deletes or keeps each.
- [ ] **Step 8: Verify**: `kubectl get pods -A | grep -E "hermes|honcho|speaches|llm-embeddings"` is empty; `llama-server` and Lingarr still Running; `kubectl -n argocd get applications | awk '$2!="Synced" || $3!="Healthy"'` shows nothing new.
- [ ] **Step 9: Archive this plan** to `.archive/.plans/superpowers/plans/` and update both `list.md` files (as a follow-up commit/PR).
