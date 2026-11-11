#!/usr/bin/env bash
#
# Hunk-approval scenarios through Neovim and gitsigns.nvim. Each one builds a
# throwaway repo and presses <leader>gvh through require("git-vibecheck").
# Needs nvim and gitsigns. Set GITSIGNS_PATH if gitsigns is not in lazy's
# directory, and NVIM_BIN if nvim is not on your PATH.

set -euo pipefail

PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
CLI="$PLUGIN/bin/git-vibecheck"
NVIM_BIN=${NVIM_BIN:-nvim}
GITSIGNS=${GITSIGNS_PATH:-$HOME/.local/share/nvim/lazy/gitsigns.nvim}

if ! command -v "$NVIM_BIN" >/dev/null 2>&1; then
  echo "skipped: nvim not found"
  exit 0
fi
if [ ! -d "$GITSIGNS" ]; then
  echo "skipped: gitsigns.nvim not found; set GITSIGNS_PATH to its directory"
  exit 0
fi

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/git-vibecheck-nvim.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

failures=0
current=""

review() {
  "$CLI" "$@"
}

fail() {
  printf 'FAIL [%s] %s\n' "$current" "$1"
  failures=$((failures + 1))
}

scenario() {
  current=$1
  cd "$ROOT"
  rm -rf repo
  mkdir repo
  cd repo
  git init -q -b main
  seq 1 "${2:-5}" >f
  git add -A
  git commit -qm base
  git switch -qc feat
  review >/dev/null
}

# approve <file> <steps> <wait for gitsigns to draw the hunks first: 0|1>
approve() {
  local file=$1 steps=$2 wait_hunks=$3
  FILE=$file STEPS=$steps WAIT_HUNKS=$wait_hunks CLI="$CLI" GITSIGNS="$GITSIGNS" PLUGIN="$PLUGIN" \
    "$NVIM_BIN" --headless -u NONE -l "$PLUGIN/test/nvim.lua" >"$ROOT/nvim.out" 2>&1 ||
    fail "nvim: $(tr '\n' '|' <"$ROOT/nvim.out")"
}

expect_clean() {
  local label=$1 code=0
  review pending >"$ROOT/pending.out" 2>&1 || code=$?
  if [ "$code" -ne 0 ]; then
    fail "$label: still pending: $(tr '\n' '|' <"$ROOT/pending.out")"
  fi
}

expect_mark() {
  local label=$1 file=$2 mark=$3
  review pending 2>/dev/null >"$ROOT/pending.out" || :
  grep -qxF "[$mark] $file" "$ROOT/pending.out" || fail "$label: $(tr '\n' '|' <"$ROOT/pending.out")"
}

expect_approved_blob() {
  local label=$1 file=$2
  [ "$(git rev-parse -q --verify "refs/review/feat:$file")" = "$(git hash-object -- "$file")" ] ||
    fail "$label: approved content differs from the file"
}

scenario "the hunk under the cursor is approved on the first attempt"
printf '1\n2\nTHREE\n4\n5\n' >f
approve f 3 1
expect_clean "after approving the change"
expect_approved_blob "approved content" f

scenario "an add at the top"
printf 'TOP\n1\n2\n3\n4\n5\n' >f
approve f 1 1
expect_clean "after an add at the top"
expect_approved_blob "approved content" f

scenario "an add in the middle"
printf '1\n2\nINSERTED\n3\n4\n5\n' >f
approve f 3 1
expect_clean "after an add in the middle"
expect_approved_blob "approved content" f

scenario "a delete at the end"
printf '1\n2\n3\n4\n' >f
# gitsigns puts the sign for a deletion at the end on the last remaining line.
approve f 4 1
expect_clean "after a delete at the end"
expect_approved_blob "approved content" f

scenario "a visual range approves every hunk it touches"
{
  echo 1
  echo TWO
  seq 3 17
  echo EIGHTEEN
  seq 19 20
} >f
approve f 2,20 1
expect_clean "after approving both hunks at once"
expect_approved_blob "approved content" f

scenario "two hunks approved one after the other"
{
  echo 1
  echo TWO
  seq 3 17
  echo EIGHTEEN
  seq 19 20
} >f
approve f "2 18" 1
expect_clean "after approving both hunks"
expect_approved_blob "approved content" f

scenario "a partial approval survives, then the rest completes it"
{
  echo 1
  echo TWO
  seq 3 17
  echo EIGHTEEN
  seq 19 20
} >f
approve f 2 1
expect_mark "one of two hunks approved" f "-"
approve f 18 1
expect_clean "after the second hunk"
expect_approved_blob "approved content" f

scenario "approving a hunk in a cleared file approves the empty file"
: >f
approve f 1 1
expect_clean "after clearing the file"
expect_approved_blob "approved empty content" f
[ -s f ] && fail "the file is not empty"

scenario "an untracked file is attached and approved"
printf 'hello\nworld\n' >n
approve n 1 0
expect_clean "after approving the new file"
expect_approved_blob "approved content" n

scenario "an untracked empty file is approved empty"
: >n
approve n 1 0
expect_clean "after approving the new empty file"
expect_approved_blob "approved empty content" n
[ -s n ] && fail "the new file is not empty"

if [ "$failures" -gt 0 ]; then
  printf '\n%s failure(s)\n' "$failures"
  exit 1
fi
echo "all Neovim scenarios passed"
