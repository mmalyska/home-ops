# Manifest lint tasks

## Execution contract

Repositories: `mmalyska/containers` (T1) and `mmalyska/home-ops` (everything else).

- **Where to work.** Work in a linked worktree on a branch from the current `origin/main` of that repository, and run that
  repository's worktree preflight (`.agents/bin/worktree-preflight` here) before the first edit.
- **What is forbidden.** Never read secret values, and never write the private domain or Bitwarden identifiers anywhere.
  No cluster mutation; `kubectl api-versions`, `kubectl api-resources` and `kubectl get crd` are READ. Never bypass
  hooks.
- **Delivery.** Workers commit on their branch and do not push or open PRs. The conductor reviews, runs the gates, and
  pushes or opens PRs only on the owner's instruction.
- **Scratch output.** Rendered manifests and generated schemas go to a temp directory, never into the repository.

## T1 - Add kubeconform and promtool to the dev-workstation image

- **Owner:** worker (mechanical). **Dependencies:** owner approval.
- **Repository:** `mmalyska/containers`. **Branch:** `feat/dev-workstation-kubeconform-promtool`.
- **Files:**
  - `apps/dev-workstation/mise.toml`: under "Cluster, GitOps and infrastructure", add `kubeconform = "0.8.0"` and
    `promtool = "3.16.0"`. Add a comment that the promtool version follows the cluster's Prometheus.
  - `apps/dev-workstation/ci/goss.yaml`: next to the other tool checks, add
    `env HOME=/tmp kubeconform -v: {exit-status: 0, timeout: 60000}` and
    `env HOME=/tmp promtool --version: {exit-status: 0, timeout: 60000}`.
  - `apps/dev-workstation/README.md`: only if it lists tools by name.
- **Checks:** `cue vet` if `metadata.json` changed (it should not). That repository's local test task (goss), if it can
  run in this environment; otherwise report NOT RUN with the reason.
- **Done when:** the diff touches only those files and the checks pass or are reported.

## H1 - HUMAN ONLY: merge the containers PR

- **Owner:** repository owner.
- **Done when:** the release workflow has published a new `dev-workstation` image. The conductor reads its digest from
  the release or the registry (READ).

## T2 - API versions file and the render script

- **Owner:** worker. **Dependencies:** none (develops with `mise exec`). **Branch:** `feat/manifest-lint`.
- **Files:** new `.taskfiles/lint/resources/kube-api-versions.txt` and `.taskfiles/lint/resources/render-apps.sh`.

**The API versions file:**

- Generate it with `kubectl api-versions` plus `group/version/Kind` lines from `kubectl api-resources --no-headers`. For
  core resources the line is `v1/Kind`.
- Sort and deduplicate the lines.
- Start the file with a `# kube-version: <server gitVersion without the v>` line and a comment that says how to
  regenerate it.
- Add the generator as a task in T4, so it is reproducible.

**`render-apps.sh <outdir>`:**

- For each `cluster/apps/*/*/app-config.yaml` entry with `enabled == "true"`:
  - The source path is the app folder, or `<folder>/<appSubfolder>`. The release name is the folder name, or
    `<folder>-<appSubfolder>`.
  - Kustomize source: `kustomize build --enable-alpha-plugins`.
  - Helm source: run `helm dependency update` in place, then
    `helm template --include-crds --release-name <rel> --namespace <ns> --kube-version <from file> --api-versions <file lines joined by commas> .`
- Write one `<rel>.yaml` per app to `<outdir>`. On a failure, print the app and its stderr, keep going, and exit 1 at the
  end.
- Write nothing in the repository other than the gitignored `Chart.lock` and `charts/*.tgz`.
- A working prototype is described in `plan.md` ("Trial run"); match its behaviour.

**Checks:**

- `shellcheck` passes.
- A run renders all enabled apps with exit 0.
- Sonarr's `HTTPRoute` renders as `gateway.networking.k8s.io/v1`.
- `git status` is clean afterwards.

## T3 - kubeconform and promtool scripts, schema generator, LiteLLM rule test

- **Owner:** worker. **Dependencies:** T2. **Branch:** `feat/manifest-lint`.
- **Files:**
  - `.taskfiles/lint/resources/crd2schema.py`
  - `.taskfiles/lint/resources/check-manifests.sh`
  - `.taskfiles/lint/resources/kubeconform-skip.txt` (may hold only comments)
  - `cluster/apps/ai/litellm/tests/fallback-alerts.promtool.yaml`
- **Check that `tests/` does not reach the chart.** Confirm that `helm template` of litellm does not pick up `tests/`.
  Helm only renders `templates/`, but a `.helmignore` entry is cheap.

**`crd2schema.py <outdir>`:**

- Reads a JSON array of CRDs on stdin and writes `<outdir>/<group>/<kind lowercase>_<version>.json` for every version
  with an `openAPIV3Schema`.
- Strict: it adds `additionalProperties: false` to objects that have `properties`, no `additionalProperties`, and no
  `x-kubernetes-preserve-unknown-fields`.
- Adds `apiVersion`, `kind` and `metadata` to the root properties.
- Standard library only. Run it with `python3 -I`.

**`check-manifests.sh`:**

1. Render the apps into a temp directory with `render-apps.sh`.
2. Write a copy with tokens replaced: `<secret:private-domain>` becomes `example.com`, and every other `<secret:[^>]*>`
   becomes `placeholder`.
3. Turn every rendered CRD into a schema with `crd2schema.py`.
4. Run kubeconform:
   - `kubeconform -strict -summary -kubernetes-version 1.34.12 -skip CustomResourceDefinition,<kinds from kubeconform-skip.txt>`
   - Schema locations, in this order: `default`, the generated schemas, then
     `https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json`.
   - Print each invalid or error line with its app.
5. Extract the `.spec` of every `PrometheusRule` and run `promtool check rules` on all of them, without
   `--lint-fatal`.
6. For every app folder with `tests/*.promtool.yaml`:
   - Write that app's rule specs, merged into one `groups` list, to `<tmp>/<app>/rules.yaml`.
   - Copy the tests there and run `promtool test rules`.
7. Exit non-zero if any step failed, and print a summary line per step.

The private domain must never be printed: the placeholders are applied before any output.

**`fallback-alerts.promtool.yaml`:** `rule_files: [rules.yaml]`. Test cases for `LiteLLMFallbackChainExhausted`:

- **The 2026-11-16 20:24 UTC incident.** Series `litellm_deployment_failed_fallbacks_total` with
  `requested_model="or-deepseek-v4-pro", fallback_model="or-deepseek-v4.1-flash"` (plus `api_key_alias`), rising
  within 15 minutes. The alert fires, with the labels `api_key_alias` and `requested_model`.
- **A brand-new series.** Its first failure (value 1) arrives, and `litellm_deployment_failed_fallbacks_created` is
  within 900 s of the evaluation time. The alert fires through the second branch.
- **An old, unchanged series.** `_created` is more than 900 s ago and there is no increase. The alert does not fire.
- **A hop that is not the last one.** `fallback_model="or-deepseek-v4-pro"` rising. The alert does not fire.

Optional: one positive and one negative case each for `LiteLLMSubscriptionRateLimited` (>= 5 429s in 30 min, held for
10 min).

**Checks:**

- `shellcheck`.
- `check-manifests.sh` passes on the branch.
- The LiteLLM tests pass.
- Breaking the alert expression on purpose (for example removing the second branch) makes the new-series test fail;
  revert afterwards.
- Changing a sonarr HTTPRoute hostname into an invalid string makes kubeconform fail; revert afterwards.

## T4 - Tasks, CI workflow, MegaLinter, devcontainer digest

- **Owner:** worker. **Dependencies:** T3, and H1 for the digest. **Branch:** `feat/manifest-lint`.
- **Files:** `.taskfiles/lint.yml`, new `.github/workflows/manifest-lint.yaml`, `.github/workflows/lint.yaml`,
  `.devcontainer/devcontainer.json`.

**`lint.yml`:**

- `manifests`: runs `check-manifests.sh`, with `ignore_error: true` like the other lint tasks.
- `api-versions`: regenerates `kube-api-versions.txt` from the cluster.
- Add `manifests` to `all`.

**`manifest-lint.yaml`:**

- `on: pull_request` with paths `cluster/**`, `charts/**`, `.taskfiles/lint/**` and the workflow file.
- Job `container: ghcr.io/mmalyska/dev-workstation:<tag>@<digest>`, the same reference as `devcontainer.json`.
- Steps: checkout, pinned to a full SHA like the other workflows, then `.taskfiles/lint/resources/check-manifests.sh`.
- `permissions: contents: read`.
- If checkout or helm cannot write as the image user, set `options: --user root` and say why in a comment.

**`lint.yaml`:** remove `KUBERNETES_KUBECONFORM` from `ENABLE_LINTERS`, and remove its two `KUBERNETES_KUBECONFORM_*`
settings.

**`devcontainer.json`:** bump to the H1 image digest, unless Renovate already did.

**Checks:**

- actionlint, if available (MegaLinter runs it in CI).
- `task lint:manifests` locally with the new image's tools (or `mise exec`).
- The CI job runs green on the PR. That run is the real test of the container setup.

## T5 - Documentation and TODO

- **Owner:** worker (docs). **Dependencies:** T4. **Branch:** `feat/manifest-lint`.
- **Files:**
  - `.agents/policy/validation.md`: add `task lint:manifests` to L0 for Helm, Kustomize and PrometheusRule changes, and
    the CI job to L1.
  - `.agents/skills/dev-workflow/SKILL.md`: the task, how to refresh the API versions file, and why `group/version/Kind`
    entries matter. Then run `.agents/bin/sync-skills`.
  - `AGENTS.md`, "Verification": add `task lint:manifests` to the list.
  - `.plans/TODO.md`: move the kubeconform and promtool items to `.archive/TODO.md` ("Archive a TODO item" in
    `.plans/README.md`).
- **Done when:** `check-plans` passes, and the docs build passes or is reported NOT RUN with the reason.

## H2 - HUMAN ONLY: merge the home-ops PR

- **Owner:** repository owner. Merging changes CI and the devcontainer only; nothing deploys.
- **Done when:** the PR is merged. The plan is then archived ("Archive after Ship").
