#!/usr/bin/env bash
# Stage 1 of the skills layout: .agents/skills is a link to ../.claude/skills and every skill is well formed.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

check_link() { # root
  [ -L "$1/.agents/skills" ] && [ "$(readlink "$1/.agents/skills")" = "../.claude/skills" ] && [ -d "$1/.agents/skills/." ]
}
check_skills() { # root: name equals directory, description not empty
  local root="$1" bad=0 d name desc
  for d in "$root"/.agents/skills/*/; do
    d="${d%/}"
    [ -f "$d/SKILL.md" ] || { echo "no SKILL.md in ${d##*/}"; bad=1; continue; }
    name="$(yq --front-matter=extract '.name' "$d/SKILL.md")"
    desc="$(yq --front-matter=extract '.description' "$d/SKILL.md")"
    [ "$name" = "${d##*/}" ] || { echo "name [$name] differs from directory ${d##*/}"; bad=1; }
    { [ -n "$desc" ] && [ "$desc" != null ]; } || { echo "empty description in ${d##*/}"; bad=1; }
  done
  return $bad
}
check_no_plugin_refs() { ! grep -R "superpowers:" "$1/.claude/skills"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok ".agents/skills links to ../.claude/skills" check_link "$REPO_ROOT"
assert_ok "every skill has name = directory and a description" check_skills "$REPO_ROOT"
assert_ok "no skill refers to a Superpowers skill" check_no_plugin_refs "$REPO_ROOT"
assert_ok "add-app and dev-workflow are present" test -f "$REPO_ROOT/.agents/skills/add-app/SKILL.md" -a -f "$REPO_ROOT/.agents/skills/dev-workflow/SKILL.md"

echo "-- negative fixtures"
fixture "$TMP/a"; rm "$TMP/a/.agents/skills"; mkdir "$TMP/a/.agents/skills"
assert_fails "a copied directory instead of a link is detected" check_link "$TMP/a"
fixture "$TMP/b"; sed -i 's/^name: add-app$/name: other/' "$TMP/b/.claude/skills/add-app/SKILL.md"
assert_fails "mismatched skill name is detected" check_skills "$TMP/b"
fixture "$TMP/c"; printf '\nSee superpowers:brainstorming.\n' >> "$TMP/c/.claude/skills/add-app/SKILL.md"
assert_fails "Superpowers reference is detected" check_no_plugin_refs "$TMP/c"
finish
