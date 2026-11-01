#!/usr/bin/env bash
# The public page docs/src/contributing/ai-workflow.md belongs to home-ops: nine sections in order, a nav entry,
# the workflow linked at the pinned tag and never restated, the canonical adoption guide linked at its own pinned
# tag, and a PR-time docs build that cannot deploy. The "no copied definition" scan itself is test_no_workflow_copy.
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"

PAGE_REL="docs/src/contributing/ai-workflow.md"
PIN_TAG="ai-workflow-v0.1.0-preview.1"   # workflow-contract links
GUIDE_TAG="ai-workflow-v0.1.0-preview.2" # the repository-adoption guide, pinned separately
GUIDE_URL="https://github.com/mmalyska/claude-plugins/blob/$GUIDE_TAG/docs/workflow/repository-adoption-guide.md"
SECTIONS=("What this page is and is not" "Where rules live" "Onboarding" "Worktree-first" "Plans" "Validation" "Permission boundaries" "Handoff" "Troubleshooting")

check_sections() { # root: nine numbered "## n. Title" headings, in order
  local root="$1" i=1 title bad=0 got
  got="$(grep -E '^## [0-9]+\. ' "$root/$PAGE_REL" | sed -E 's/^## ([0-9]+)\. (.*)$/\1 \2/')"
  for title in "${SECTIONS[@]}"; do
    printf '%s\n' "$got" | sed -n "${i}p" | grep -qxF "$i $title" || { echo "section $i is not: $title"; bad=1; }
    i=$((i + 1))
  done
  [ "$(printf '%s\n' "$got" | wc -l)" -eq "${#SECTIONS[@]}" ] || { echo "expected ${#SECTIONS[@]} numbered sections"; bad=1; }
  return $bad
}
check_nav() { # root: the page is in the nav under "Contributing"
  local root="$1"
  [ -f "$root/$PAGE_REL" ] &&
    [ "$(yq '.nav[] | select(has("Contributing")) | .Contributing[0]["AI workflow"]' "$root/.github/mkdocs/mkdocs.yml")" = "contributing/ai-workflow.md" ]
}
check_pin() { # root: workflow-contract links use the contract tag, never a branch or another tag (the guide link is checked apart)
  local root="$1" bad=0 url
  grep -q "claude-plugins/tree/$PIN_TAG" "$root/$PAGE_REL" || { echo "no link at the pinned tag"; bad=1; }
  while IFS= read -r url; do
    case "$url" in *repository-adoption-guide*) continue ;; esac
    case "$url" in *"$PIN_TAG"*) ;; *) echo "claude-plugins link not at the pinned tag: $url"; bad=1 ;; esac
  done < <(grep -oE 'https://github.com/mmalyska/claude-plugins[^) ]*' "$root/$PAGE_REL")
  return $bad
}
check_guide_link() { # root: exactly one adoption-guide link, and it is the immutable GUIDE_URL
  local root="$1" bad=0 urls
  urls="$(grep -oE 'https?://[^) ]*repository-adoption-guide[^) ]*' "$root/$PAGE_REL")"
  [ -n "$urls" ] || { echo "no link to the repository-adoption guide"; return 1; }
  [ "$(printf '%s\n' "$urls" | wc -l)" -eq 1 ] || { echo "expected exactly one adoption-guide link"; bad=1; }
  [ "$urls" = "$GUIDE_URL" ] || { echo "adoption-guide link is not exactly the pinned URL: $urls"; bad=1; }
  return $bad
}
check_public_safe() { # root: no private address space or placeholder-breaking hostnames on the public site
  local root="$1" bad=0
  grep -nE '(^|[^0-9])(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+' "$root/$PAGE_REL" && bad=1
  grep -nE '<secret:|BWS_|bitwarden.*[0-9a-f]{8}-[0-9a-f]{4}' "$root/$PAGE_REL" && bad=1
  return $bad
}
check_docs_workflow() { # root: read-only token, strict build, pull_request only, no deploy, no secrets
  local f="$1/.github/workflows/docs-build.yaml" bad=0
  [ "$(yq '.permissions | keys | join(",")' "$f")" = "contents" ] && [ "$(yq '.permissions.contents' "$f")" = "read" ] || { echo "permissions must be contents: read only"; bad=1; }
  [ "$(yq '.on | keys | join(",")' "$f")" = "pull_request,workflow_dispatch" ] || { echo "triggers must be pull_request and workflow_dispatch"; bad=1; }
  grep -q 'mkdocs build --strict' "$f" || { echo "build is not strict"; bad=1; }
  grep -qE 'deploy-pages|upload-pages-artifact|configure-pages|\$\{\{ *secrets\.' "$f" && { echo "workflow must not deploy or use secrets"; bad=1; }
  for p in 'docs/\*\*' '\.github/mkdocs/\*\*' '\.github/workflows/docs-build\.yaml'; do
    grep -qE "\"$p\"" "$f" || { echo "missing path filter: $p"; bad=1; }
  done
  return $bad
}

check_pinned_actions() { # root: every third-party "uses:" is a full 40-hex SHA; no @v*, @main or @master
  local f="$1/.github/workflows/docs-build.yaml" bad=0 line ref
  while IFS= read -r line; do
    ref="${line##*@}"; ref="${ref%% *}"
    printf '%s' "$ref" | grep -qE '^[0-9a-f]{40}$' || { echo "action not pinned to a full SHA: $line"; bad=1; }
  done < <(grep -E '^[[:space:]]*(-[[:space:]]+)?uses:' "$f")
  grep -qE '@(v[0-9]|main|master)' "$f" && { echo "mutable action reference in workflow"; bad=1; }
  [ "$(grep -cE '^[[:space:]]*(-[[:space:]]+)?uses:' "$f")" -ge 1 ] || { echo "no uses: found, check is vacuous"; bad=1; }
  return $bad
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "-- real repository"
assert_ok "docs-build actions are pinned to full SHAs" check_pinned_actions "$REPO_ROOT"
assert_ok "nine sections in order" check_sections "$REPO_ROOT"
assert_ok "nav entry Contributing / AI workflow resolves to the page" check_nav "$REPO_ROOT"
assert_ok "workflow links use the pinned tag" check_pin "$REPO_ROOT"
assert_ok "adoption guide linked once, at its own immutable tag" check_guide_link "$REPO_ROOT"
assert_ok "no private address or identifier on the public page" check_public_safe "$REPO_ROOT"
assert_ok "docs-build workflow is read-only, strict and does not deploy" check_docs_workflow "$REPO_ROOT"

echo "-- negative fixtures"
fixture "$TMP/a"; sed -i 's/^## 4\. Worktree-first$/## 4. Something else/' "$TMP/a/$PAGE_REL"
assert_fails "renamed section is detected" check_sections "$TMP/a"
fixture "$TMP/b"; sed -i '/AI workflow/d' "$TMP/b/.github/mkdocs/mkdocs.yml"
assert_fails "missing nav entry is detected" check_nav "$TMP/b"
fixture "$TMP/c"; printf '\nSee [lifecycle](https://github.com/mmalyska/claude-plugins/tree/main/workflow).\n' >> "$TMP/c/$PAGE_REL"
assert_fails "unpinned claude-plugins link is detected" check_pin "$TMP/c"
fixture "$TMP/d"; sed -i "s|$GUIDE_TAG|main|" "$TMP/d/$PAGE_REL"
assert_fails "guide link on main is detected" check_guide_link "$TMP/d"
fixture "$TMP/d2"; sed -i "s|$GUIDE_TAG|master|" "$TMP/d2/$PAGE_REL"
assert_fails "guide link on master is detected" check_guide_link "$TMP/d2"
fixture "$TMP/d3"; sed -i "s|blob/$GUIDE_TAG/|blob/$PIN_TAG/|" "$TMP/d3/$PAGE_REL"
assert_fails "guide link at another tag (preview.1) is detected" check_guide_link "$TMP/d3"
fixture "$TMP/d4"; sed -i "s|blob/$GUIDE_TAG/|blob/|" "$TMP/d4/$PAGE_REL"
assert_fails "unpinned guide URL is detected" check_guide_link "$TMP/d4"
fixture "$TMP/d5"; sed -i "s|(https://github.com/mmalyska/claude-plugins/blob/$GUIDE_TAG/docs/workflow/repository-adoption-guide.md)|(guide.md)|" "$TMP/d5/$PAGE_REL"
assert_fails "missing guide link is detected" check_guide_link "$TMP/d5"
fixture "$TMP/d6"; printf '\nAlso [guide](%s).\n' "$GUIDE_URL" >> "$TMP/d6/$PAGE_REL"
assert_fails "a second guide link is detected" check_guide_link "$TMP/d6"
fixture "$TMP/d7"; sed -i "s|claude-plugins/tree/$PIN_TAG|claude-plugins/tree/$GUIDE_TAG|" "$TMP/d7/$PAGE_REL"
assert_fails "contract link moved to preview.2 is still rejected" check_pin "$TMP/d7"
fixture "$TMP/e"; printf '\nNode at 192.168.48.2.\n' >> "$TMP/e/$PAGE_REL"
assert_fails "private address on the public page is detected" check_public_safe "$TMP/e"
fixture "$TMP/f"; sed -i 's/--strict/--site-dir x/' "$TMP/f/.github/workflows/docs-build.yaml"
assert_fails "non-strict build is detected" check_docs_workflow "$TMP/f"
fixture "$TMP/g"; sed -i 's/contents: read/contents: write/' "$TMP/g/.github/workflows/docs-build.yaml"
assert_fails "write permission is detected" check_docs_workflow "$TMP/g"
fixture "$TMP/h"; printf '      - uses: actions/deploy-pages@v5\n' >> "$TMP/h/.github/workflows/docs-build.yaml"
assert_fails "deploy step is detected" check_docs_workflow "$TMP/h"
fixture "$TMP/i"; sed -i 's|setup-python@[0-9a-f]\{40\}|setup-python@v7|' "$TMP/i/.github/workflows/docs-build.yaml"
assert_fails "action pinned to a version tag is detected" check_pinned_actions "$TMP/i"
fixture "$TMP/j"; sed -i 's|checkout@[0-9a-f]\{40\}|checkout@main|' "$TMP/j/.github/workflows/docs-build.yaml"
assert_fails "action pinned to main is detected" check_pinned_actions "$TMP/j"
fixture "$TMP/k"; sed -i 's|checkout@[0-9a-f]\{40\}|checkout@master|' "$TMP/k/.github/workflows/docs-build.yaml"
assert_fails "action pinned to master is detected" check_pinned_actions "$TMP/k"
fixture "$TMP/l"; sed -i 's|checkout@[0-9a-f]\{40\}|checkout@3d3c42e|' "$TMP/l/.github/workflows/docs-build.yaml"
assert_fails "abbreviated SHA is detected" check_pinned_actions "$TMP/l"
finish
