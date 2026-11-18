---
status: draft
owner: repository owner
profile: STANDARD
topology: HANDOFF
base_sha: 1888e14cbdd5feb7a847c66134522c438b0d039d
branch: feat/manifest-lint
worktree: .worktrees/feat/manifest-lint
pr: not-opened
started: 2026-11-18
updated: 2026-11-18
---

# Manifest lint: kubeconform and promtool on rendered apps

## Goal

Every PR that changes `cluster/` or `charts/` renders each enabled app the way ArgoCD does and checks the output:

- **kubeconform:** schema validation of every rendered resource, in strict mode.
- **promtool:** `check rules` on every `PrometheusRule`, and `test rules` where an app ships rule tests. The first test
  covers the LiteLLM fallback alerts (#6355).

The same check runs locally as a task, with the same tool versions from the `dev-workstation` image. It closes two
`.plans/TODO.md` items: "Working kubeconform for `cluster/`" and "Add `promtool` to the workspace image".

## Context (verified 2026-11-18)

**What exists today:**

- CI's MegaLinter kubeconform covers nothing in `cluster/`. Its filter `(kubernetes)` matches no path,
  `-ignore-missing-schemas` skips custom resources, and it reads raw files instead of the rendered output.
- There are no rule tests. `promtool` and `kubeconform` are not in the image.
- **The image:** `ghcr.io/mmalyska/dev-workstation` is built in `mmalyska/containers` from `apps/dev-workstation/mise.toml`, with `ci/goss.yaml` tests.
  Renovate bumps tool versions weekly, and this repo pins the image by digest in `.devcontainer/devcontainer.json`.
- **mise registry:** it has both tools. `kubeconform` is `aqua:yannh/kubeconform` (latest 0.8.0), and `promtool` is `aqua:prometheus/prometheus` (latest 3.16.0).
  The cluster runs Prometheus v3.16.0.

**How ArgoCD renders apps** (the CMP in `cluster/apps/core/argocd/resources/sops-replacer-plugin.yaml`):

- Helm apps:
  - `helm dependency update`, then
  - `helm template --include-crds --release-name $ARGOCD_APP_NAME --namespace $ARGOCD_APP_NAMESPACE --kube-version $KUBE_VERSION --api-versions $KUBE_API_VERSIONS .`
- Kustomize apps: `kustomize build --enable-alpha-plugins`.
- Both pipe the output through `argocd-secret-replacer` to substitute `<secret:...>` tokens.
- The app name is the folder name, or `<folder>-<appSubfolder>`; the namespace comes from `app-config.yaml`.

**Trial run in the scratchpad, against the cluster's live API list:**

- **Render:** all 73 enabled apps rendered in about 1 minute.
- **kubeconform:** 1,053 resources valid, 0 invalid, 0 errors. The 138 skipped are the `CustomResourceDefinition` objects.
- **promtool:** `check rules` passed all 44 rule groups (exit 0). The one lint warning is a duplicate recording rule in upstream
  kube-prometheus-stack (`kube-apiserver-availability.rules`).

**Findings that shaped the design:**

1. **`--api-versions` must include `group/version/Kind` entries,** not only `group/version`. Without them, bjw-s
   app-template renders `HTTPRoute` as `gateway.networking.k8s.io/v1alpha2` in 11 apps. The cluster does not serve that
   version (only `v1` and `v1beta1`), while ArgoCD renders `v1`.
2. **`<secret:...>` tokens fail schema patterns,** for example a hostname pattern. They must be replaced with placeholders
   before validation.
3. **Rendering must happen in place.** Copying an app elsewhere breaks the `file://../../../../charts/...` dependencies.
   `Chart.lock` and the downloaded `charts/*.tgz` are gitignored, so the tree stays clean.
4. **The newest Kubernetes schemas in kubeconform's default source are for v1.34.12;** the cluster runs v1.36.6. Its full
   CRD schema file is missing, so `CustomResourceDefinition` is skipped. The API server validates CRDs anyway.
5. **Not every custom resource is in the public CRDs-catalog** (for example `LiteLLMTeam` and `LiteLLMProxy`). Schemas
   generated from the CRDs in our own renders cover all of them, at the versions we actually deploy.

## Decisions

1. **Tools come from the image.** Add `kubeconform = "0.8.0"` and `promtool = "3.16.0"` to
   `apps/dev-workstation/mise.toml` in `mmalyska/containers`, with goss checks. Renovate keeps them current like every
   other tool. CI uses the same image (decision 6).
2. **One render script,** `.taskfiles/lint/resources/render-apps.sh`, mirrors the CMP:
   - It reads each `app-config.yaml` entry with `enabled: "true"` and renders that app in place into an output folder,
     one file per app.
   - It exits non-zero if any app fails to render.
3. **API versions file.** The `--api-versions` list is a committed file, `.taskfiles/lint/resources/kube-api-versions.txt`
   (from `kubectl api-versions` plus `group/version/Kind` from `kubectl api-resources`), refreshed by
   `task lint:api-versions`, which reads the cluster.
   - It is cluster state with no secret values.
   - CI cannot reach the cluster, so the file has to be committed.
   - The file's header records the Kubernetes version, which is used for `--kube-version`.
4. **kubeconform runs on the rendered output.**
   - **Placeholders:** tokens are replaced first (`<secret:private-domain>` becomes `example.com`, any other `<secret:...>`
     becomes `placeholder`).
   - **Flags:** `-strict`, `-kubernetes-version 1.34.12` (the newest schemas published), `-skip CustomResourceDefinition`.
   - **Schema locations, in this order:** the default Kubernetes schemas, then schemas generated from the CRDs in the
     renders (`.taskfiles/lint/resources/crd2schema.py`, strict like kubeconform's own `openapi2jsonschema`), then the
     datree CRDs-catalog as a fallback.
   - **No `-ignore-missing-schemas`:** a missing schema is an error. A kind that legitimately has no schema goes into an
     explicit skip list with a comment.
5. **promtool:**
   - `check rules` runs on the `.spec` of every rendered `PrometheusRule`, without `--lint-fatal`, so the upstream
     duplicate stays a warning.
   - `test rules` runs for each app with a `tests/*.promtool.yaml`. The script extracts that app's rules to
     `rules.yaml` next to a copy of the tests, and the tests reference it as `rule_files: [rules.yaml]`.
6. **CI:** a new workflow, `.github/workflows/manifest-lint.yaml`.
   - It runs on PRs that touch `cluster/**`, `charts/**`, `.taskfiles/lint/**` or the workflow itself.
   - The job runs in `ghcr.io/mmalyska/dev-workstation` pinned by digest, the same as `.devcontainer/devcontainer.json`.
   - It calls the scripts directly, so a failure fails the job.
   - `KUBERNETES_KUBECONFORM` is removed from MegaLinter, since it checks nothing.
   - **Risk:** container jobs and file ownership. If the image's `vscode` user cannot write the checkout, run the job
     with `--user root` (the tools are on PATH through `/usr/local/bin` shims). If the image is too slow to pull, fall back
     to `jdx/mise-action` with the same two pins.
7. **Local tasks:** `task lint:manifests` runs render, kubeconform and promtool, and is added to `task lint:all`. Like
   every `lint:*` task it exits 0 and is read for its output (repository convention); CI is the gate.

## Delivery

**Two PRs, in order:**

1. **`mmalyska/containers`:** the two tools in `mise.toml` plus goss checks. After it merges, the image is published.
2. **This repository, after the new image is published:**
   - render script, schema generator and API versions file,
   - tasks, the LiteLLM rule test, the CI workflow, the MegaLinter change,
   - the devcontainer digest bump (unless Renovate has already bumped it),
   - docs, and the two TODO items archived.

Until the image ships, local work uses `mise exec kubeconform@0.8.0 promtool@3.16.0 -- ...` (user-space install, no
repository change).

**Nothing here deploys.** Merging the `containers` PR publishes an image. Merging the home-ops PR changes CI and the
devcontainer only, and touches nothing ArgoCD syncs.

## Out of scope

- Fixing what the new check finds beyond what blocks it from passing on `main`. The trial found nothing, so any real
  finding during implementation is reported and fixed in its own PR.
- Server-side dry-run against the cluster.
- Rule tests for anything other than the LiteLLM fallback alerts.

## Rollback

- Revert the home-ops PR. CI and the tasks return to their previous state.
- Revert the containers PR, which removes the two tools from the next image build.

## Status

Draft, awaiting owner approval.
