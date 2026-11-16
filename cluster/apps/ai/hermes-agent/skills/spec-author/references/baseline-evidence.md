# Baseline evidence during specification

Use this procedure when an owner wants observed failures before deciding remediation, compatibility policy or exceptions. A baseline is fact gathering within the spec phase, not permission to implement fixes.

1. Identify the default-branch revision and read the actual build inputs and commands. Record `git rev-parse HEAD`, the runtime version and whether full git history is present; history-dependent plugins can behave differently in shallow clones.
2. Use a linked worktree and an isolated environment. Keep generated output and diagnostic logs outside tracked paths. Do not alter source, install into the shared Python environment or publish artifacts merely to test the baseline.
3. Install the current declared inputs together, including packages installed separately by CI. For a Python docs baseline, a concrete pattern is:

   ```sh
   uv venv --python <python-executable> /workspaces/<baseline-venv>
   uv pip install --python /workspaces/<baseline-venv>/bin/python \
     'mkdocs[i18n]' -r .github/mkdocs/requirements.txt
   uv pip freeze --python /workspaces/<baseline-venv>/bin/python
   /workspaces/<baseline-venv>/bin/mkdocs build --strict \
     --config-file .github/mkdocs/mkdocs.yml \
     --site-dir /workspaces/<baseline-site>
   ```

   Adapt package inputs and paths to the repository. A minimal uv-created environment need not contain pip; use `uv pip` to inspect installed packages rather than assuming `python -m pip` exists.

4. Capture the build's own exit status immediately, separately from formatting, installation and log-reading commands. Inspect diagnostics: distinguish build warnings/errors from INFO messages and banners. A banner calling itself a warning does not prove the build treats it as one.
5. State the evidence boundary. Report the revision, interpreter, resolved key packages, command, exit code and relevant diagnostics. If installer or runner differs from CI, disclose that difference; current-input success is neither validation of a future lock nor proof of a hermetic build.
6. If the baseline passes, report that no existing failure currently needs an exception decision. If it fails, bring concrete diagnostics back to the owner before choosing fixes, waivers or reduced strictness. Recheck after future pins or locks are selected because they may expose different incompatibilities.
7. Put durable baseline evidence in the spec itself, not a separate plan or implementation artifact. Preserve phase gates and leave source changes to the approved implementation phase.
