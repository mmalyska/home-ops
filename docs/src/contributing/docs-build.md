# Docs build

The public site builds from pinned inputs that local tasks and both CI workflows share. Nothing
installs an unpinned package, and no command resolves a fresh dependency graph during a build.

## Inputs

| File                              | Purpose                                                           |
| --------------------------------- | ----------------------------------------------------------------- |
| `.github/mkdocs/requirements.in`  | Exact direct dependency pins (MkDocs, theme, plugins, extensions) |
| `.github/mkdocs/requirements.txt` | Generated lock with exact versions and artifact hashes            |
| `.github/mkdocs/.python-version`  | Exact Python patch version used to build the docs                 |
| `.github/mkdocs/mise.toml`        | Exact uv version used to install and compile the lock             |
| `.github/mkdocs/mkdocs.yml`       | MkDocs configuration and navigation                               |
| `.github/tests/docs-workflows.sh` | Four maintained invariants checked in PR CI                       |

Build and serve only consume the committed lock with `uv pip sync --require-hashes`. Only
`task mkdocs:lock` runs `uv pip compile`, and it writes the lock header from the pinned Python
version.

## Local prerequisites

The docs environment needs the pinned Python and uv versions from the files above. With mise:

```sh
mise install python@3.15.2 uv@0.13.7
```

Any other version manager works when it provides exactly those versions. `task mkdocs:build` and
`task mkdocs:serve` refuse to run when the Python in `.python-version` is unavailable or the `uv`
on `PATH` is not the pinned one, and the message names the version to install.

## Build and serve

```sh
task mkdocs:build   # strict build into ./site
task mkdocs:serve   # local preview on http://127.0.0.1:8000
```

Both tasks create the virtualenv at `.github/mkdocs/.venv` (git-ignored), synchronize the hashed
lock into it, and then run the environment's own `mkdocs` executable. The strict build treats a
warning as a failure, so a broken link or a page missing from the nav fails locally before CI.

## Regenerate the lock

Run this after changing `.github/mkdocs/requirements.in` or `.github/mkdocs/.python-version`:

```sh
task mkdocs:lock
```

The task reads the target Python from `.python-version` and runs:

```sh
uv pip compile --generate-hashes \
  --python-version=<version from .python-version> \
  --output-file=.github/mkdocs/requirements.txt \
  .github/mkdocs/requirements.in
```

Commit `requirements.txt` with the source change. The header keeps the exact target version, which
Renovate parses when it updates the lock.

## Updates

- Dependency bumps: Renovate's native `pip-compile` manager reads the lock header, updates
  `requirements.in`, and regenerates `requirements.txt` with `uv pip compile` in the same PR. Indirect
  lock entries are maintained through the same manager. Review the regenerated hashes with the source
  diff.
- Python bumps (`.python-version`): Renovate updates the version file only. CI then fails the
  header-equality invariant until the branch runs `task mkdocs:lock` and commits the regenerated
  lock. This is intended: the lock must be compiled for the Python that will install it.
- uv bumps (`mise.toml`): no regeneration is required. The PR passes when the locked install and the
  strict build succeed with the new uv.
- Action pins: the workflows reference full commit SHAs with readable version comments; Renovate
  updates both together.

### Repairing a red Python-bump PR

1. In the Renovate branch, run `task mkdocs:lock` with the new Python installed.
2. Commit the regenerated `.github/mkdocs/requirements.txt` to that branch.
3. Confirm `bash .github/tests/docs-workflows.sh` passes and the strict build is green.

If the new Python cannot resolve the same direct pins, report it instead of editing the expected
version in the check.

### A uv bump that needs no regeneration

`task mkdocs:build` plus the PR workflow's locked install and strict build are the whole
requirement. The lock content and its header stay unchanged; only `mise.toml` changes.

## CI

`.github/workflows/docs-build.yaml` runs the invariant script, then installs the same lock with the
pinned Python and uv and builds strictly without deploying. `.github/workflows/publish-pages.yaml`
builds the same inputs strictly on `main`, and its deploy job declares `needs: build`, so a failed
build cannot deploy.

The invariants cover full action SHAs, strict mode in both workflows, `needs: build` on deploy, and
lock-header equality with `.python-version`. The fourth check fails closed when the header or the
version file is missing or malformed.

The docs build is a red check, not an enforced merge block: required checks are unchanged, so a
failing docs build does not by itself prohibit merging. Treat a red docs build as a blocker anyway.

## Troubleshooting

- Hash mismatch during install: the lock does not match the index. Regenerate it with
  `task mkdocs:lock` rather than installing without hashes.
- Python or uv mismatch: install the versions named by the failing precondition.
- Stale environment after a pin change: the prerequisite task recreates
  `.github/mkdocs/.venv` for the pinned Python and re-synchronizes the lock.
