#!/bin/bash
# Pre-run script of the weekly skill-sync job. Compares every skill seeded from git (the hermes-agent-skills ConfigMap,
# mounted at /opt/skills-git) with the profiles' live copies, which hold Hermes' own edits, and prints them as one
# patch against the chart's skills/ directory, with the sha256 each file must have after it is applied. The skill-sync
# skill turns that into a PR. No difference prints nothing, and Hermes then skips the model run.
# Only SKILL.md and references/* are compared: the seeder writes nothing else, so another file would not survive in
# git either. Such files are listed so the owner sees them.
set -u
exec /opt/hermes/.venv/bin/python - <<'PY'
import difflib
import hashlib
import os
from pathlib import Path

GIT = Path("/opt/skills-git")
REPO_DIR = "cluster/apps/ai/hermes-agent/skills"
homes = {"default": Path("/opt/data")}
profiles = Path("/opt/data/profiles")
if profiles.is_dir():
    for p in sorted(profiles.iterdir()):
        if p.is_dir():
            homes[p.name] = p

skills = sorted(f.name[:-3] for f in GIT.iterdir()
                if f.name.endswith(".md") and not f.name.startswith(("soul-", "script-", "ref-")))


def read(path):
    return path.read_text(encoding="utf-8") if path and path.is_file() else None


def patch(rel, old, new):
    a = old.splitlines(keepends=True) if old is not None else []
    b = new.splitlines(keepends=True)
    out = []
    for line in difflib.unified_diff(a, b, "a/" + rel if old is not None else "/dev/null", "b/" + rel):
        out.append(line if line.endswith("\n") else line + "\n\\ No newline at end of file\n")
    return "".join(out)


changes = {}   # repo path -> (profile, new content)
conflicts = []
other_files = []
for skill in skills:
    git_refs = {f.name[len(f"ref-{skill}--"):]: f for f in GIT.glob(f"ref-{skill}--*")}
    for profile, home in homes.items():
        sdir = home / "skills" / skill
        if not (sdir / "SKILL.md").is_file():
            continue
        pairs = [("SKILL.md", GIT / f"{skill}.md", sdir / "SKILL.md")]
        live_refs = {f.name for f in (sdir / "references").glob("*") if f.is_file()} if (sdir / "references").is_dir() else set()
        for name in sorted(set(git_refs) | live_refs):
            pairs.append((f"references/{name}", git_refs.get(name), sdir / "references" / name))
        for rel, git_file, live_file in pairs:
            live = read(live_file)
            if live is None or live == read(git_file):
                continue  # missing copies are seeded again at the next start
            key = f"{REPO_DIR}/{skill}/{rel}"
            if key in changes and changes[key][1] != live:
                conflicts.append(f"{key}: profiles {changes[key][0]} and {profile} hold different edits")
                continue
            changes.setdefault(key, (profile, live, read(git_file)))
        for f in sorted(sdir.rglob("*")):
            rel = f.relative_to(sdir).as_posix()
            if f.is_file() and rel != "SKILL.md" and not rel.startswith("references/"):
                other_files.append(f"{profile}: skills/{skill}/{rel}")

for c in conflicts:
    changes.pop(c.split(":", 1)[0], None)
if not changes and not conflicts and not other_files:
    raise SystemExit(0)

print(f"skill-sync: {len(changes)} file(s) differ from git")
if changes:
    print("=== PATCH BEGIN")
    for key in sorted(changes):
        print(patch(key, changes[key][2], changes[key][1]), end="")
    print("=== PATCH END")
    print("=== SHA256 AFTER APPLY")
    for key in sorted(changes):
        print(hashlib.sha256(changes[key][1].encode("utf-8")).hexdigest(), key, f"(profile {changes[key][0]})")
for c in conflicts:
    print("CONFLICT, not in the patch:", c)
for o in other_files:
    print("NOT SEEDED, not in the patch:", o)
PY
