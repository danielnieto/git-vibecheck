#!/usr/bin/env bash
#
# Hunk approval and review gutter scenarios through Neovim. Each one builds a
# throwaway repo and drives require("git-vibecheck") in a headless nvim.
# Set NVIM_BIN if nvim is not on your PATH.

set -euo pipefail

PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
CLI="$PLUGIN/bin/git-vibecheck"
NVIM_BIN=${NVIM_BIN:-nvim}

if ! command -v "$NVIM_BIN" >/dev/null 2>&1; then
  echo "skipped: nvim not found"
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

# nvim_run <file> <steps> [<line>:<text>]: opens the file, presses <leader>gvh
# on each step (a line, or "first,last" for a visual range) or, without steps,
# turns the review gutter on, optionally replaces a line without saving, and
# leaves the gutter's signs in $ROOT/signs, one "<line> <sign>" per line. With
# $NAV set, then moves through the review hunks (see `nav`).
nvim_run() {
  FILE=$1 STEPS=$2 SET_LINE=${3:-} NAV=${NAV:-} SIGNS_OUT="$ROOT/signs" CURSOR_OUT="$ROOT/cursor" PLUGIN="$PLUGIN" \
    "$NVIM_BIN" --headless -u NONE -l "$PLUGIN/test/nvim.lua" >"$ROOT/nvim.out" 2>&1 ||
    fail "nvim: $(tr '\n' '|' <"$ROOT/nvim.out")"
}

approve() {
  nvim_run "$1" "$2"
}

# gutter <file> [<line>:<text>]
gutter() {
  nvim_run "$1" "" "${2:-}"
}

# nav <file> <moves>: from line 1, presses ]v for each "next" and [v for each
# "prev", leaving the lines landed on in $ROOT/cursor.
nav() {
  NAV=$2 nvim_run "$1" ""
}

expect_cursor() {
  local label=$1 expected=$2
  [ "$(cat "$ROOT/cursor")" = "$expected" ] || fail "$label: landed on $(cat "$ROOT/cursor")"
}

expect_signs() {
  local label=$1 expected=$2
  [ "$(cat "$ROOT/signs")" = "$expected" ] || fail "$label: signs were: $(tr '\n' '|' <"$ROOT/signs")"
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
approve f 3
expect_clean "after approving the change"
expect_approved_blob "approved content" f

scenario "an add at the top"
printf 'TOP\n1\n2\n3\n4\n5\n' >f
approve f 1
expect_clean "after an add at the top"
expect_approved_blob "approved content" f

scenario "an add in the middle"
printf '1\n2\nINSERTED\n3\n4\n5\n' >f
approve f 3
expect_clean "after an add in the middle"
expect_approved_blob "approved content" f

scenario "a delete at the end"
printf '1\n2\n3\n4\n' >f
# The gutter marks a deletion at the end on the last remaining line.
approve f 4
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
approve f 2,20
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
approve f "2 18"
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
approve f 2
expect_mark "one of two hunks approved" f "-"
approve f 18
expect_clean "after the second hunk"
expect_approved_blob "approved content" f

scenario "approving a hunk in a cleared file approves the empty file"
: >f
approve f 1
expect_clean "after clearing the file"
expect_approved_blob "approved empty content" f
[ -s f ] && fail "the file is not empty"

scenario "an untracked file is approved"
printf 'hello\nworld\n' >n
approve n 1
expect_clean "after approving the new file"
expect_approved_blob "approved content" n

scenario "an untracked empty file is approved empty"
: >n
approve n 1
expect_clean "after approving the new empty file"
expect_approved_blob "approved empty content" n
[ -s n ] && fail "the new file is not empty"

scenario "the gutter shows what is left, and approving a hunk takes it off"
printf 'ONE\n2\n3\nNEW\n4\n' >f
gutter f
expect_signs "a change, an add and a deletion at the end" "1 ~
4 +
5 _"
approve f 1
expect_signs "after approving the change" "4 +
5 _"
expect_mark "partly approved" f "-"

scenario "]v and [v move through the review hunks and wrap around"
printf 'ONE\n2\n3\nNEW\n4\n' >f
git commit -qam "change line 1"
nav f "next next next prev prev"
expect_cursor "hunks at 1, 4 and the deletion marked on 5" "4 5 1 5 4"

scenario "the gutter marks a deletion at the top on the first line"
printf '2\n3\n4\n5\n' >f
gutter f
expect_signs "a deletion at the top" "1 ‾"

scenario "the gutter compares a never approved file with the base, not with HEAD"
printf '1\nTWO\n3\n4\n5\n' >f
git commit -qam "change line 2"
gutter f
expect_signs "the committed change is still pending" "2 ~"

scenario "the gutter follows unsaved edits"
gutter f "2:TWO"
expect_signs "the edited line" "2 ~"
[ "$(sed -n 2p f)" = 2 ] || fail "the edit was saved"

scenario "the gutter shows a new file as all pending"
printf 'hello\nworld\n' >n
gutter n
expect_signs "every line added" "1 +
2 +"

scenario "the gutter leaves ignored files alone"
echo ignored >.gitignore
printf 'hello\n' >ignored
gutter ignored
expect_signs "no signs" ""

scenario "the gutter is empty once the file is approved"
printf '1\n2\nTHREE\n4\n5\n' >f
review approve f >/dev/null
gutter f
expect_signs "no signs" ""

if [ "$failures" -gt 0 ]; then
  printf '\n%s failure(s)\n' "$failures"
  exit 1
fi
echo "all Neovim scenarios passed"
