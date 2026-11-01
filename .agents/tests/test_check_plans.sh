#!/usr/bin/env bash
# check-plans: passes on the real tree, and each rule fails on a copy of the tree with exactly that fault.
# The real .plans/ and .archive/ are only read; every fault is injected into a throw-away copy.
# shellcheck source-path=SCRIPTDIR source=lib.sh
# shellcheck disable=SC2016  # single quotes keep Markdown backticks and the bash -c body literal
source "$(dirname "$0")/lib.sh"

CP="$REPO_ROOT/.agents/bin/check-plans"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# tree <dir>: the files check-plans reads, copied from the real repository.
tree() {
  local dir="$1"
  mkdir -p "$dir/.agents" "$dir/.archive"
  cp "$REPO_ROOT/AGENTS.md" "$REPO_ROOT/CLAUDE.md" "$dir/"
  cp "$REPO_ROOT/.agents/README.md" "$dir/.agents/"
  cp -a "$REPO_ROOT/.agents/policy" "$dir/.agents/"
  cp -a "$REPO_ROOT/.plans" "$dir/"
  cp -a "$REPO_ROOT/.archive/.plans" "$dir/.archive/"
}
# expect_error <name> <dir> <message fragment>: check-plans exits 1 and prints an ERROR line with the fragment.
expect_error() {
  local out rc
  out="$("$CP" --root "$2" 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q "^ERROR .*$3"; then pass "$1"
  else fail "$1" "exit $rc, wanted an ERROR containing '$3': $(printf '%s' "$out" | head -4)"; fi
}
expect_warn() {
  local out rc
  out="$("$CP" --root "$2" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q "^WARN .*$3"; then pass "$1"
  else fail "$1" "exit $rc, wanted a WARN containing '$3': $(printf '%s' "$out" | head -4)"; fi
}
# newplan <dir> <slug>: a valid plan folder with an index row.
newplan() {
  local d="$1" s="$2"
  mkdir -p "$d/.plans/$s"
  cat >"$d/.plans/$s/plan.md" <<PLAN
---
status: draft
owner: tester
profile: P
topology: T
base_sha: abc
branch: feat/$s
worktree: .worktrees/feat/$s
pr: not-opened
started: 2026-01-01
updated: 2026-01-02
---

# $s
PLAN
  printf '# Tasks\n' >"$d/.plans/$s/tasks.md"
  printf '| [%s](%s/plan.md) | draft | tester | P / T | feat/%s | — | 2026-01-01 | 2026-01-02 | test |\n' "$s" "$s" "$s" >>"$d/.plans/list.md"
}

echo "-- real repository"
real_before="$(cd "$REPO_ROOT" && git status --porcelain=v1 -- .plans .archive | cksum)"
assert_ok "check-plans passes on the real tree" "$CP"
out1="$("$CP" 2>&1)"; out2="$("$CP" 2>&1)"
if [ "$out1" = "$out2" ]; then pass "output is deterministic"; else fail "output differs between runs"; fi
assert_ok "front matter example in .plans/README.md validates" bash -c '
  f=$(mktemp); trap "rm -f $f" EXIT
  awk "/^\`\`\`yaml/{i=1;next} /^\`\`\`/{if(i)exit} i" "$1/.plans/README.md" >"$f"
  "$1/.agents/bin/check-plans" --front-matter "$f"' _ "$REPO_ROOT"

echo "-- positive fixtures"
tree "$TMP/ok"; newplan "$TMP/ok" second-plan
assert_ok "a second valid plan is accepted" "$CP" --root "$TMP/ok"
tree "$TMP/legacy"; mkdir -p "$TMP/legacy/.plans/superpowers/plans"
printf '# old\n' >"$TMP/legacy/.plans/superpowers/plans/2026-01-01-old.md"
printf '| [old](superpowers/plans/2026-01-01-old.md) | | | | | | | | legacy |\n' >>"$TMP/legacy/.plans/list.md"
expect_warn "legacy .plans/superpowers only warns" "$TMP/legacy" "legacy"

tree "$TMP/ok2"; newplan "$TMP/ok2" opened-plan
sed -i 's/^pr: .*/pr: "#7001, https:\/\/github.com\/example\/repo\/pull\/7002"/' "$TMP/ok2/.plans/opened-plan/plan.md"
sed -i '/opened-plan\/plan.md/s/| — |/| #7001, https:\/\/github.com\/example\/repo\/pull\/7002 |/' "$TMP/ok2/.plans/list.md"
assert_ok "a plan with opened PR numbers and URLs is accepted" "$CP" --root "$TMP/ok2"

echo "-- negative fixtures"
tree "$TMP/pr1"; newplan "$TMP/pr1" p; sed -i 's/^pr: .*/pr:/' "$TMP/pr1/.plans/p/plan.md"
expect_error "empty pr" "$TMP/pr1" "field 'pr' is empty"
tree "$TMP/pr2"; newplan "$TMP/pr2" p; sed -i 's/^pr: .*/pr: none/' "$TMP/pr2/.plans/p/plan.md"
expect_error "pr with a random value" "$TMP/pr2" "'pr' must be 'not-opened'"
tree "$TMP/pr3"; newplan "$TMP/pr3" p; sed -i 's/^pr: .*/pr: "#12 pending"/' "$TMP/pr3/.plans/p/plan.md"
expect_error "pr with trailing text" "$TMP/pr3" "'pr' must be 'not-opened'"
tree "$TMP/pr4"; newplan "$TMP/pr4" p; sed -i 's/^pr: .*/pr: "#12"/' "$TMP/pr4/.plans/p/plan.md"
expect_error "index PR differs from plan.md" "$TMP/pr4" "PR is '—' but plan.md says '#12'"
tree "$TMP/pr5"; newplan "$TMP/pr5" p; sed -i '/\[p\](p\/plan.md)/s/| — |/| none |/' "$TMP/pr5/.plans/list.md"
expect_error "index shows none instead of the dash" "$TMP/pr5" "PR is 'none' but plan.md says '—'"
tree "$TMP/a"; rm "$TMP/a/.plans/hybrid-ai-workflow/tasks.md"
expect_error "missing tasks.md" "$TMP/a" "tasks.md is missing"
tree "$TMP/b"; rm "$TMP/b/.plans/hybrid-ai-workflow/plan.md"
expect_error "missing plan.md" "$TMP/b" "plan.md is missing"
tree "$TMP/c"; sed -i '/^owner:/d' "$TMP/c/.plans/hybrid-ai-workflow/plan.md"
expect_error "missing front matter field" "$TMP/c" "field 'owner' is missing"
tree "$TMP/d"; sed -i 's/^status: .*/status: finished/' "$TMP/d/.plans/hybrid-ai-workflow/plan.md"
expect_error "invalid status" "$TMP/d" "status 'finished'"
tree "$TMP/e"; sed -i 's/^started: .*/started: 1 Nov 2026/' "$TMP/e/.plans/hybrid-ai-workflow/plan.md"
expect_error "invalid date" "$TMP/e" "'started' must be YYYY-MM-DD"
tree "$TMP/f"; sed -i '1d' "$TMP/f/.plans/hybrid-ai-workflow/plan.md"
expect_error "no front matter" "$TMP/f" "no front matter"
tree "$TMP/g"; mkdir -p "$TMP/g/.plans/orphan"; printf '# x\n' >"$TMP/g/.plans/orphan/plan.md"; printf '# x\n' >"$TMP/g/.plans/orphan/tasks.md"
expect_error "folder without an index row" "$TMP/g" "no row in .plans/list.md"
tree "$TMP/h"; printf '| [ghost](ghost/plan.md) | draft | o | P / T | b | none | 2026-01-01 | 2026-01-01 | x |\n' >>"$TMP/h/.plans/list.md"
expect_error "index row without a folder" "$TMP/h" "ghost"
tree "$TMP/i"; sed -i 's/| in-progress |/| shipped |/' "$TMP/i/.plans/list.md"
expect_error "index status differs from plan.md" "$TMP/i" "Status is 'shipped'"
tree "$TMP/j"; l="$(grep '^| \[hybrid' "$TMP/j/.plans/list.md")"; printf '%s\n' "$l" >>"$TMP/j/.plans/list.md"
expect_error "duplicate index row" "$TMP/j" "duplicate row"
tree "$TMP/k"; sed -i 's/^| Plan .*/| Plan | Spec | Description | Started |/' "$TMP/k/.plans/list.md"
expect_error "old four-column header" "$TMP/k" "table header must be"
tree "$TMP/l"; printf '# stray\n' >"$TMP/l/.plans/stray-plan.md"
expect_error "loose plan file in .plans/" "$TMP/l" "outside .plans/<slug>/"
tree "$TMP/m"; mkdir -p "$TMP/m/docs/superpowers/plans"
expect_error "docs/superpowers exists" "$TMP/m" "docs/superpowers"
tree "$TMP/n"; mkdir -p "$TMP/n/.plans/Bad_Slug"; cp "$TMP/n/.plans/hybrid-ai-workflow/"*.md "$TMP/n/.plans/Bad_Slug/"
expect_error "invalid slug" "$TMP/n" "kebab-case"
tree "$TMP/o"; mkdir -p "$TMP/o/.archive/.plans/hybrid-ai-workflow"
expect_error "slug also archived" "$TMP/o" "also an archived plan"
tree "$TMP/p"; printf '\nSee [gone](missing.md).\n' >>"$TMP/p/.plans/hybrid-ai-workflow/plan.md"
expect_error "broken link in a plan" "$TMP/p" "broken link: missing.md"
tree "$TMP/q"; printf '\nSee [gone](missing.md).\n' >>"$TMP/q/.archive/.plans/list.md"
expect_error "broken link in the archive index" "$TMP/q" "broken link: missing.md"
tree "$TMP/r"; sed -i '0,/^| \[wow-modules\]([^)]*)/s//| [wow-modules](wow-modules\/missing.md)/' "$TMP/r/.archive/.plans/list.md"
expect_error "archive row to a missing file" "$TMP/r" "does not exist"
tree "$TMP/s"; mkdir -p "$TMP/s/.archive/.plans/new-plan"; printf '# x\n' >"$TMP/s/.archive/.plans/new-plan/plan.md"
expect_error "archive folder not in the index" "$TMP/s" "no row in .archive/.plans/list.md"
tree "$TMP/t"; printf '# x\n' >"$TMP/t/.archive/.plans/2026-12-01-new.md"
expect_error "new loose plan in the old archive location" "$TMP/t" "old location"
tree "$TMP/u"; printf '# x\n' >"$TMP/u/.archive/.plans/superpowers/plans/2026-12-01-new.md"
expect_error "archived superpowers plan not in the index" "$TMP/u" "no row in .archive/.plans/list.md"
tree "$TMP/v"; rm "$TMP/v/.archive/.plans/README.md"
expect_error "archive notice missing" "$TMP/v" "archive notice is missing"
tree "$TMP/w"; sed -i 's/not instructions/for reference/g' "$TMP/w/.archive/.plans/README.md"
expect_error "archive notice does not say history" "$TMP/w" "not instructions"
tree "$TMP/x"; sed -i '/Archive is not instructions/d' "$TMP/x/AGENTS.md"
expect_error "AGENTS.md lost the archive line" "$TMP/x" "Archive is not instructions"
tree "$TMP/y"; printf '@.archive/.plans/lfm3-llama-server/plan.md\n' >>"$TMP/y/CLAUDE.md"
expect_error "archive imported as an instruction" "$TMP/y" "imports a file under .archive/"
tree "$TMP/z"; printf '\n```sh\nkubectl apply -f x.yaml\n```\n' >>"$TMP/z/.plans/hybrid-ai-workflow/tasks.md"
expect_warn "unmarked mutating command warns" "$TMP/z" "consent-gated"
tree "$TMP/z2"; printf '\n```sh consent-gated\nkubectl apply -f x.yaml\n```\n' >>"$TMP/z2/.plans/hybrid-ai-workflow/tasks.md"
if "$CP" --root "$TMP/z2" | grep -q consent-gated; then fail "marked block is accepted"; else pass "marked block is accepted"; fi
tree "$TMP/z3"; printf '.archive/.plans/gone.md\n' >>"$TMP/z3/.agents/policy/plans-legacy.txt"
expect_warn "stale legacy entry warns" "$TMP/z3" "no longer exists"
tree "$TMP/z4"; : >"$TMP/z4/.agents/policy/plans-legacy.txt"
expect_error "without the legacy list the legacy files are errors" "$TMP/z4" "old location"
assert_fails "usage error on a bad option" "$CP" --bogus
assert_fails "usage error on a missing root" "$CP" --root "$TMP/does-not-exist"

echo "-- the real tree was not modified"
real_after="$(cd "$REPO_ROOT" && git status --porcelain=v1 -- .plans .archive | cksum)"
if [ "$real_before" = "$real_after" ]; then pass "git status of .plans and .archive is unchanged by the tests"; else fail "the tests changed the real tree"; fi
finish
