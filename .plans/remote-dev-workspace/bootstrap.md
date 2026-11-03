<!-- markdownlint-disable MD013 -->

# Repository bootstrap in the workspace (T6)

> **Status (2026-11-03): static analysis plus one amd64 run.** The agent session has no container runtime, so the owner ran the three lifecycle scripts in a scratch container from the pinned image on linux/amd64 (clone of branch `chore/bootstrap-rework` at `2957b0ab`, no secrets, no cluster) and pasted the output. Rows marked "Predicted" below were not run. **arm64 is NOT RUN.** See "Runtime results (amd64)" at the end.

## Decision

**Option A, with guards in `home-ops`.** The workspace bootstrap reads `onCreateCommand`, `updateContentCommand` and `postStartCommand` from the repository's `devcontainer.json` (a JSONC file: parse it with a JSONC-aware tool, not `jq`) and runs them from the repository root, passing the repository path where the file uses `${containerWorkspaceFolder}`. Reason: the local devcontainer and the workspace then run the same scripts (T17), and no second entry point has to be kept in step. Option B (a `setup` entry point per repository) is not needed for `home-ops`; revisit it for a repository whose `devcontainer.json` has no lifecycle scripts.

The scripts must tell the two consumers apart without a new variable where possible. The reliable signal is what the workspace deliberately does **not** have (D25): the `TALHELPER_*` Talos secrets and `sudo`.

## Predicted breakages and the change each needs (feeds T17)

| # | Script and line | Prediction in the image | Change | Status |
| - | --------------- | ----------------------- | ------ | ------ |
| 1 | `postStartCommand.sh`: `task talos:init` (unguarded) | `talos:generate` needs `TALHELPER_OSCERT` and the other `TALHELPER_*` secrets, which the workspace does not get (D25), so the precondition fails; `generate-kubeconfig` would also write `$KUBECONFIG` with an admin credential (`talosctl kubeconfig` is Admin only, `talos-access.md`). `updateContentCommand.sh` runs the same task but only when `CODESPACES` is unset. | Guard both calls: run `task talos:init` only when `TALHELPER_OSCERT` is set. In the workspace it is unset, and `TALOSCONFIG` already points at the mounted Secret. | Done in T17 (runtime NOT RUN) |
| 2 | `.envrc`: `export KUBECONFIG=$(expand_path ~/.kube/config)` and `Taskfile.yml` `env: KUBECONFIG` | In the workspace no kubeconfig exists (D26); an exported `KUBECONFIG` pointing at a missing file hides the in-cluster configuration, so `kubectl` fails. | Export `KUBECONFIG` only when the file exists (`.envrc`: `[ -f ~/.kube/config ] && export ...`) and drop the hard-coded value in `Taskfile.yml`. T7 already says to fix this in T14; confirm T14 landed it, because `.envrc` on `main` still exports it unconditionally. | Done in T17: `.envrc` and `Taskfile.yml` (runtime NOT RUN) |
| 3 | `.envrc`: `bws secret list "${BWS_PROJECT_ID:-<default>}"` | Works when the pod sets `BWS_ACCESS_TOKEN` and `BWS_PROJECT_ID` (D31). Without the token `bws` prints an error and `export` gets nothing; the shell continues. The script's default project reference is a Bitwarden identifier: it stays in `.envrc` only and must not be copied into any plan or doc. | No change needed. Consider failing loudly when the token is missing. | Predicted OK |
| 4 | `.envrc`: `HOMEBREW_GITHUB_API_TOKEN=${GITHUB_TOKEN}` | Harmless; Homebrew is not in the image. | Remove with T10. | Cosmetic |
| 5 | `onCreateCommand.sh`: `gpg --list-secret-keys` | `gnupg` is not in the image, so `gpg` is not found; the `&>/dev/null` hides it and the `if` is false. GPG signing config is skipped, which is correct (D30 uses an SSH signing key). | None. | Predicted OK |
| 6 | `onCreateCommand.sh`: `sudo apt-get install wireguard-tools` | Only under `CODESPACES`; there is no `sudo` in the image. | None for the workspace. Keep the Codespaces branch. | Predicted OK |
| 7 | `onCreateCommand.sh`: krew block | `releases/latest` tarball (unpinned), writes `~/.krew` into the home volume, and `>>` appends the `PATH` line to `.zshrc` (no zsh in the image, so it creates a stray file) and `.bashrc` on every run, which duplicates on a persistent home. `kubectl browse-pvc` is already in the image (`mise.toml`, `rename_exe`), so krew is not needed there. | Skip the krew block when `kubectl browse-pvc` already resolves; remove it for good with T10 when the Brewfile devcontainer goes. Make the `PATH` appends idempotent while it exists. | Done in T17 (runtime NOT RUN); remove with T10 |
| 8 | all three scripts: `#!/bin/bash -i` | `-i` makes `/etc/bash.bashrc` run (`mise activate`, `direnv hook`). Outside a TTY bash prints "cannot set terminal process group" and "no job control". `/usr/local/bin` also holds mise shims, so `task`, `chezmoi`, `kubectl` resolve without `-i`. | Keep `-i` for the local devcontainer. In the workspace bootstrap run them with `bash -i` and discard the job-control warnings, or run with `bash` plus `mise exec`. Decide when T5 writes the bootstrap. | Decide in T5 |
| 9 | `postStartCommand.sh`: `/workspaces/home-ops` | Fixed in `chore/bootstrap-rework` (`REPO_ROOT` from `git rev-parse`). | Done in T17. | Done |
| 10 | memory-symlink loop | Fixed in `chore/bootstrap-rework`: the project directory name is the repository path with every non-alphanumeric character replaced by `-` (`/workspaces/home-ops` gives `-workspaces-home-ops`). That matches the existing directory and generalises to any repository; verify the rule against the real directory Claude Code creates in the workspace (R6). | Done in T17; runtime check in T7. | Done, runtime NOT RUN |
| 11 | `updateContentCommand.sh`: `task init` | Rewritten in T17 to check tools on `PATH`. Possible name mismatches to verify at runtime: `egctl` (from `github:envoyproxy/gateway` with `bin_path`), `kubelogin` (the mise tool name `kubelogin` may resolve to a different project than `int128/kubelogin`; check the binary supports `--version` and OIDC), `prettier`, `mkdocs`. `ipcalc` and `envsubst` come from apt. | If a name does not resolve, fix the image (`containers`) or drop it from the `task init` list. | Verify at runtime |
| 12 | `updateContentCommand.sh`: `task precommit:init` | `pre-commit install --install-hooks` stores hook environments under `XDG_CACHE_HOME`, which the image sets to `/cache`, an empty `emptyDir` after every restart (D40). Hooks are rebuilt on first use after a restart and need network. | None; note it in T7 so a slow first commit is not mistaken for a hang. | Predicted OK |
| 13 | `updateContentCommand.sh`: `task cilium:init` | After T17 it warns and skips when `cilium` exists. Image pins `cilium-cli` 0.20.1 equal to the repository today; they diverge on the next Renovate bump. | None. | Done |
| 14 | `updateContentCommand.sh`: `task terraform:upgrade:cloudflare` | Needs `TERRAFORM_TOKEN` (delivered via BWS, D32) and network to the registry. `TF_PLUGIN_CACHE_DIR=/cache` exists because the image creates it, but `/cache` is empty after restart (accepted, D40). | None. | Predicted OK |
| 15 | `devcontainer.json`: `runArgs --env-file`, `--cap-add=NET_ADMIN`, `--device=/dev/net/tun`, `initializeCommand` | Not applicable to a pod: these are local `docker run` options. The workspace has no `NET_ADMIN` and no WireGuard (it is already in the cluster network); the `CODESPACES`-only WireGuard block in `postStartCommand.sh` stays unreachable because `CODESPACES` is unset. | The bootstrap ignores `runArgs`, `initializeCommand` and `secrets`. | Predicted OK |
| 16 | `task` targets that expect the VPN | Targets that reach the LAN directly (`talos:*` against node IPs) run through the pod network and the `talos.default` endpoint only for the read commands `os:reader` allows. | Record per target when T7 runs; do not expect `talos:apply` or `talos:upgrade` to work (denied by role, intended). | Verify in T7 |
| 17 | Empty home (D34, D45) | First start copies `/etc/skel` with `cp -rn`. Git configuration, `safe.directory` and `pull.rebase` written by `onCreateCommand.sh` then land in `~/.gitconfig` on the home volume and persist; `onCreateCommand.sh` must therefore run once per volume, not on every restart. | The bootstrap runs `onCreateCommand` only when a marker file on the home volume is absent. | Decide in T5 |

## Generalised memory-symlink loop

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
PROJECT_KEY="$(printf '%s' "${REPO_ROOT}" | sed 's/[^A-Za-z0-9]/-/g')"
MEMORY_DIR="${HOME}/.claude/projects/${PROJECT_KEY}/memory"
mkdir -p "${MEMORY_DIR}"
for f in "${REPO_ROOT}"/.claude/memory/*.md; do
  [ -e "${f}" ] && ln -sf "${f}" "${MEMORY_DIR}/$(basename "${f}")"
done
```

The `[ -e ]` guard is new: without it a repository with no memory files links the literal glob. In a linked worktree `git rev-parse --show-toplevel` returns the worktree path, so the link goes to the key Claude Code uses for that worktree.

## Script changes for T17 (items 1 to 4 done on `chore/bootstrap-rework`, runtime NOT RUN)

1. Guard `task talos:init` in `postStartCommand.sh` and `updateContentCommand.sh` on `TALHELPER_OSCERT` (row 1).
2. `.envrc` and `Taskfile.yml`: export `KUBECONFIG` only when the file exists (row 2; coordinate with T14).
3. krew: skip when `kubectl browse-pvc` resolves, make the appends idempotent (row 7).
4. Add the `[ -e ]` guard to the memory loop.
5. Run `onCreateCommand` once per home volume (row 17, in the T5 bootstrap, not in the script).

## Files expected on the home volume after bootstrap (input to T8)

By name only, predicted: `~/.gitconfig`, `~/.config/chezmoi/` and the dotfiles chezmoi applies, `~/.krew/` (until row 7 is fixed), `~/.cache` is **not** here (it is `/cache`), `~/.claude/` and `~/.codex/` (accepted, D20), `~/.local/share/mise/` (tools added with `mise use -g`). Must not appear: `~/.kube/config` (rows 1 and 2), any Talos credential, `.git-credentials`, the `gh` hosts file, Terraform CLI credentials. T8 checks the list by file name.

## Runtime verification still to do (needs a container runtime)

Run in a scratch container from the pinned image, with a copy of the T17 worktree, no cluster and no secrets (an empty environment, so rows 1 and 3 behave as the workspace does):

```sh
# Each is LOCAL scope; replace <worktree> with the T17 worktree path. No secret is read.
docker run --rm -it -v <worktree>:/workspaces/home-ops -w /workspaces/home-ops \
  ghcr.io/mmalyska/dev-workstation:1.0.0@sha256:76a0c4f0359029fa9ce976a39b87d7770bb332c56336e7ea673d753a0dc30f98 bash
# inside: for each of onCreate, updateContent, postStart:
#   bash -i .devcontainer/scripts/<name>.sh /workspaces/home-ops ; echo exit=$?
#   task init ; command -v egctl kubelogin ipcalc envsubst prettier mkdocs
# repeat on linux/arm64 with --platform linux/arm64 if available
```

Record, per script: exit code, first failing line, and whether the failure matches a row above. The amd64 run is below; the arm64 run is still to do. Do not rely on the exit codes (note 20).

## Runtime results (amd64, 2026-11-03)

Scratch container from the pinned image, clone of the branch at `2957b0ab`, empty environment (no `BWS_ACCESS_TOKEN`, no `TALHELPER_*`, no `TERRAFORM_TOKEN`).

| Check                                                                                                                                                                                               | Result                                                                                                                       |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Image index has linux/amd64 and linux/arm64                                                                                                                                                         | PASS                                                                                                                         |
| `egctl`, `kubelogin` (v1.36.4), `ipcalc`, `envsubst`, `prettier`, `mkdocs`, `terraform`, `yq`, `jq`, `gitleaks` on `PATH`; `kubectl browse-pvc` works (row 11)                                      | PASS                                                                                                                         |
| `task init` (tool presence check)                                                                                                                                                                   | PASS                                                                                                                         |
| `onCreateCommand.sh` (chezmoi, plugin installs; krew block skipped)                                                                                                                                 | PASS, with notes 18 and 19                                                                                                   |
| `updateContentCommand.sh`: `git gc`, `task init`, `task precommit:init`, `task cilium:init` (up to date)                                                                                            | PASS                                                                                                                         |
| `updateContentCommand.sh`: `task terraform:upgrade:cloudflare`                                                                                                                                      | FAIL as expected without `TERRAFORM_TOKEN`; the script still exits 0 (note 20)                                               |
| `postStartCommand.sh`: `task talos:init` skipped without `TALHELPER_OSCERT` (row 1)                                                                                                                 | PASS                                                                                                                         |
| Memory symlinks under `~/.claude/projects/-workspaces-home-ops/memory` (row 10)                                                                                                                     | PASS                                                                                                                         |
| No `~/.kube`, no `~/.krew`, `TALHELPER_*` count 0                                                                                                                                                   | PASS                                                                                                                         |
| `.envrc` with a missing BWS token                                                                                                                                                                   | FAIL, fixed on the branch (note 21)                                                                                          |
| Same run on arm64                                                                                                                                                                                   | NOT RUN                                                                                                                      |

Notes from the run:

18. **chezmoi prompts.** `chezmoi init --apply mmalyska/dotfiles` asks eight questions (git email and name, work machine, AI profile, agent teams, Claude and Codex plugins, OpenCode). The run had a TTY. The workspace bootstrap has none, so T16 must make the dotfiles template read its answers from environment variables or chezmoi data and pass `--no-tty`, or the first start can hang or fail.
19. **The dotfiles do a lot.** The apply installs peon-ping (downloads sound packs, edits Claude hook settings), adds the Claude plugin marketplace, installs 12 plugins for Claude and Codex over the network, and prints an `ai-workflow` drift warning (marketplace commit differs from the accepted pin). All of it lands on the home volume. Decide in T16 whether the workspace wants any of it.
20. **Exit codes are not signals.** Every script ends with `echo "Done!"`, so each exits 0 even when a step failed.
21. **`.envrc` could dump the environment.** `export $(bws secret list ... | xargs)` becomes a bare `export` when `bws` fails, and a bare `export` prints every exported variable, which in the workspace includes `BWS_ACCESS_TOKEN`, `GITHUB_TOKEN` and `TERRAFORM_TOKEN`. All three lifecycle scripts run `direnv export`, so the values would reach the logs. Fixed on the branch: export only when `bws` succeeded and returned output, otherwise log one status line. Checked with a simulated failing `bws` and a canary variable (nothing printed).
22. **`no context is set`** is printed by every `task` call because the `TALOS_CONTROLLER` variable runs `talosctl config info` and the scratch container has no talosconfig. The workspace sets `TALOSCONFIG` to the mounted Secret, so it should not appear there.
23. **Home volume content after the run** (names only): `.claude`, `.claude.json`, `.codex`, `.config`, `.gitconfig`, `.local`, `.talos`, `.terraform.d`, shell dotfiles. T8 must check that no credentials file is created inside `.terraform.d` or `.talos`.
