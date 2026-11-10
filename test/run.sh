#!/usr/bin/env bash
#
# Scenario tests for bin/git-vibecheck. Each scenario builds a throwaway repo.
# Run with TEST_BASH=/bin/bash to check bash 3.2 compatibility on macOS.

set -euo pipefail

CLI="$(cd "$(dirname "$0")/.." && pwd)/bin/git-vibecheck"
BASH_BIN=${TEST_BASH:-bash}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-vibecheck-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

failures=0
current=""

review() {
  "$BASH_BIN" "$CLI" "$@"
}

scenario() {
  current=$1
  cd "$ROOT"
  rm -rf repo
  mkdir repo
  cd repo
  git init -q -b main
  printf '1\n2\n3\n' >a
  printf '1\n2\n3\n' >b
  printf '1\n2\n3\n' >c
  git add .
  git commit -qm base
  git switch -qc feat
}

fail() {
  printf 'FAIL [%s] %s\n' "$current" "$1"
  failures=$((failures + 1))
}

expect_eq() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" != "$actual" ]; then
    fail "$label"
    printf '  expected: %s\n  actual:   %s\n' "$(printf '%s' "$expected" | tr '\n' '|')" "$(printf '%s' "$actual" | tr '\n' '|')"
  fi
}

expect_code() {
  local label=$1 expected=$2
  shift 2
  local code=0
  "$@" >/dev/null 2>&1 || code=$?
  expect_eq "$label (exit code)" "$expected" "$code"
}

pending() {
  review pending || :
}

scenario "not started"
echo 4 >>a
expect_code "pending before start" 3 review pending
expect_code "approve before start" 3 review approve a

scenario "start lists committed, uncommitted and untracked changes"
echo 4 >>a
git commit -qam "change a"
echo 4 >>b
echo new >d
expect_eq "checklist" "feat vs main: 0/3 approved

[ ] a
[ ] b
[ ] d" "$(review)"
expect_eq "pending" "[ ] a
[ ] b
[ ] d" "$(pending)"
expect_code "pending with work left" 1 review pending

scenario "approve leaves index and commits alone"
echo 4 >>a
echo new >d
git add a
status_before=$(git status --porcelain)
head_before=$(git rev-parse HEAD)
review >/dev/null
expect_eq "approve output" "approved a
approved d" "$(review approve a d)"
expect_eq "pending" "" "$(pending)"
expect_code "pending when done" 0 review pending
expect_eq "index untouched" "$status_before" "$(git status --porcelain)"
expect_eq "HEAD untouched" "$head_before" "$(git rev-parse HEAD)"

scenario "a commit touching an approved file sends it back with only the delta"
echo 4 >>a
git commit -qam "change a"
review >/dev/null
review approve a >/dev/null
echo 5 >>a
git commit -qam "touch a again"
expect_eq "pending" "[~] a" "$(pending)"
expect_eq "delta" "+5" "$(review pending-diff a | grep '^[+-][^+-]')"
review approve a >/dev/null
expect_code "approved again" 0 review pending

scenario "a same-size edit that only a content check can see"
# The file, its index entry and the index share an mtime, so git must compare
# contents instead of trusting the timestamp. A copy of the index has to keep
# that mtime, or the edit goes unnoticed and the stale approval stands.
git config core.trustctime false
printf '1\n2\nX\n' >a
touch -t 202001010000 a
git add a
touch -t 202001010000 .git/index
review >/dev/null
review approve a >/dev/null
printf '1\n2\nY\n' >a
touch -t 202001010000 a
expect_eq "pending" "[~] a" "$(pending)"

scenario "never-reviewed diff is against the base"
echo 4 >>a
echo 4 >>b
review >/dev/null
expect_eq "diff" "+4" "$(review pending-diff a | grep '^[+-][^+-]')"
expect_eq "no paths means every pending file" "a
b" "$(review pending-diff | sed -n 's|^+++ b/||p')"

scenario "untracked files"
echo new >d
review >/dev/null
review approve d >/dev/null
expect_code "approved untracked" 0 review pending
echo more >>d
expect_eq "pending" "[~] d" "$(pending)"
expect_eq "delta" "+more" "$(review pending-diff d | grep '^[+-][^+-]')"

scenario "deletions"
git rm -q c
review >/dev/null
expect_eq "pending" "[ ] c" "$(pending)"
review approve c >/dev/null
expect_code "deletion approved" 0 review pending
git checkout -q main -- c
expect_eq "restored file leaves the checklist" "feat vs main: 0/0 approved" "$(review)"

scenario "pending-diff of a deleted and an untracked file together"
git rm -q c
echo new >d
review >/dev/null
expect_eq "both files" "c
d" "$(review pending-diff c d | sed -n 's|^diff --git a/\([^ ]*\) .*|\1|p')"

scenario "a rename is a deletion plus a new file, also in pending-diff"
git mv a z
git commit -qm "rename a"
review >/dev/null
expect_eq "pending" "[ ] a
[ ] z" "$(pending)"
expect_eq "pending-diff" "deleted file mode 100644
new file mode 100644" "$(review pending-diff | grep -E '^(rename|deleted|new) ')"

scenario "pending-diff output does not depend on diff config"
mkdir sub
echo 4 >>a
review >/dev/null
git config diff.noprefix true
git config diff.relative true
git config diff.mnemonicPrefix true
expect_eq "root-relative paths with a/ and b/, even from a subdirectory" "--- a/a
+++ b/a" "$(cd sub && review pending-diff | grep '^[-+][-+][-+] ')"

scenario "unapprove"
echo 4 >>a
echo 4 >>b
review >/dev/null
review approve a b >/dev/null
expect_eq "unapprove output" "unapproved a" "$(review unapprove a)"
expect_eq "pending" "[ ] a" "$(pending)"
expect_eq "unapprove twice" "not approved: a" "$(review unapprove a)"
review unapprove . >/dev/null
expect_eq "unapprove everything" "[ ] a
[ ] b" "$(pending)"

scenario "approve edge cases"
echo 4 >>a
review >/dev/null
expect_code "approve without paths" 2 review approve
expect_code "approve a file outside the review" 2 review approve b
review approve a >/dev/null
expect_eq "approve twice" "already approved: a" "$(review approve a)"

scenario "directories and paths relative to the cwd"
mkdir -p app/sub
echo x >app/x
echo y >app/sub/y
echo 4 >>a
review >/dev/null
(cd app && review approve sub >/dev/null)
expect_eq "relative path" "[ ] a
[ ] app/x" "$(pending)"
review approve app >/dev/null
expect_eq "directory" "[ ] a" "$(pending)"

scenario "rebase keeps approvals and moves never-reviewed files to the new base"
printf '1\n2\n3\n4\n' >a
printf '1\n2\n3\n4\n' >b
git commit -qam "feat changes"
review >/dev/null
review approve a >/dev/null
git switch -q main
printf '0\n1\n2\n3\n' >b
echo e >e
git add .
git commit -qm "main moves"
git switch -q feat
git rebase -q main
expect_eq "checklist after rebase" "feat vs main: 1/2 approved

[x] a
[ ] b" "$(review)"
expect_eq "never-reviewed diff uses the new base" "+4" "$(review pending-diff b | grep '^[+-][^+-]')"

scenario "--base for stacked branches"
echo 4 >>a
git commit -qam "feat"
git switch -qc feat2
echo 4 >>b
git commit -qam "feat2"
expect_eq "checklist against feat" "feat2 vs feat: 0/1 approved

[ ] b" "$(review --base feat)"
expect_eq "base is remembered" "[ ] b" "$(pending)"

scenario "each branch has its own review"
echo 4 >>a
review >/dev/null
review approve a >/dev/null
git stash -q
git switch -qc other
git stash pop -q
expect_code "new branch starts unreviewed" 3 review pending

scenario "detached HEAD"
git checkout -q --detach
expect_code "refuses" 2 review

if [ "$failures" -gt 0 ]; then
  printf '\n%s failure(s)\n' "$failures"
  exit 1
fi
echo "all scenarios passed"
