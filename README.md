# git-vibecheck

A per-branch checklist of the files **a human** has reviewed.

The workflow it supports: let agents vibe-code a branch, then go file by file
cleaning it up until it is worth a PR. Mark each file as approved when you are
happy with it, whole or hunk by hunk. If anything changes that file afterwards
(you, an agent, a rebase), it drops back to pending and you only re-review the
new part. You are done when nothing is pending, whether that took 1 commit or
100.

```
$ git vibecheck
nieto/my-branch vs origin/main: 9/12 approved

[x] app/models.py
[~] app/runner.py
[ ] app/verdict.py
...
```

`[x]` approved, `[ ]` never reviewed, `[~]` partly approved, or changed since
you approved it.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "danielnieto/git-vibecheck", build = "./install.sh", opts = {} }
```

`install.sh` links `bin/git-vibecheck` into `~/.local/bin` (override with
`GIT_VIBECHECK_BIN_DIR`) so `git vibecheck` also works in a terminal. It refuses to
overwrite or shadow another `git-vibecheck`. Inside Neovim the plugin
uses its own copy, so the editor integration works even without the link.

Without Neovim, clone the repo and run `./install.sh`. The CLI only needs git
and bash (3.2 or later).

## Command line

```
git vibecheck [--base <branch>]     start reviewing this branch, or show its checklist
git vibecheck pending               list the files still waiting for approval
git vibecheck approve <path>...     approve files at their current content
git vibecheck unapprove <path>...   send approved files back to pending
```

- The checklist is every file that differs from the merge base with the base
  branch (default: `origin/HEAD`, else `main`): committed, uncommitted,
  untracked and deleted files alike. Commit as often as you like.
- `--base` is for stacked branches. It is remembered per branch.
- Paths work like git pathspecs: relative to your current directory, and
  directories approve everything inside them. `git vibecheck approve .` approves
  everything, but only because you asked for it.
- `git vibecheck pending` exits 0 only when nothing is left, so agents and scripts
  can check whether you are done.

Each branch has its own review. A new branch starts from zero.

### Plumbing

For editor and agent integrations:

```
git vibecheck pending-diff [<path>...]   what is left to review, as a unified diff
git vibecheck approve-patch < <patch>    approve the changes in a patch of what is left
```

`pending-diff` shows, for each file, the part you have not reviewed yet: the
diff from what you approved (or from the base, for files you never approved)
to your working tree.

`approve-patch` approves part of that: any subset of `pending-diff`'s hunks, or
a patch an editor builds from the hunks it shows, with or without context
lines. Each file's `index` line must name the approved version the patch was
made from, so a patch made before the review changed is refused instead of
applied to content it was not made for. For example, to approve the first
hunk of a file:

```sh
git vibecheck pending-diff app/views.py | awk '/^@@/ { h++ } h <= 1' | git vibecheck approve-patch
```

## Neovim

| Key           | Action                                                                       |
| ------------- | ---------------------------------------------------------------------------- |
| `<leader>gvr` | Checklist picker. Preview shows what is left to review; `a`/`u` (normal mode) approve or unapprove the file under the cursor, or every file selected with `Tab` |
| `<leader>gva` | Approve the current file (unsaved changes are written first)                 |
| `<leader>gvu` | Unapprove the current file                                                   |
| `<leader>gvh` | Approve the hunk under the cursor; in visual mode, every hunk the selection touches (needs gitsigns.nvim) |
| `<leader>gvn` | Open the next pending file                                                   |
| `<leader>gvd` | Toggle the gitsigns gutter between its normal base and "only what is left to review" |
| `<leader>gvi` | Ask the agent which approved files the pending changes could affect (needs sidekick.nvim) |

The picker needs [snacks.nvim](https://github.com/folke/snacks.nvim), and the
gutter toggle and hunk approval need
[gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim). Everything else
works without them. Any command run on a branch that is not under review offers
to start it.

`<leader>gvh` turns on the review gutter and approves exactly the hunks
gitsigns shows there, however your `diffopt` cuts them (with `linematch`, one
changed block can be several hunks). Before approving, it checks that those
hunks are against what is approved right now, and refuses otherwise.

Options:

```lua
opts = {
  prefix = "<leader>gv", -- keymap prefix
  keys = true,           -- false to skip the default keymaps
}
```

The functions are public if you prefer your own mappings:
`require("git-vibecheck").tracker / approve / unapprove / approve_hunk / next_pending / toggle_gutter / impact`.

## Agents

Editing a file un-approves it, so an agent can never make unreviewed code look
reviewed by touching files. The one thing it could do is approve on your
behalf (`git vibecheck approve` or `approve-patch`), so do not tell agents to.

The impact check (`<leader>gvi`) catches what content tracking cannot: an
approved file that did not change but depends on something that did. To also
pick it from sidekick's prompt list (`<leader>ap`):

```lua
{
  "folke/sidekick.nvim",
  opts = {
    cli = {
      prompts = {
        review_impact = function()
          return require("git-vibecheck").impact_prompt
        end,
      },
    },
  },
}
```

Not using sidekick? The prompt text is `require("git-vibecheck").impact_prompt`;
paste it into any agent.

## How it works

Approvals live in a local ref, `refs/review/<branch>`, that is never pushed. It
points to a commit whose parent is the branch's merge base and whose tree is
that base with every approved file overlaid at the content it had when
approved, or, for a file approved hunk by hunk, the base plus those hunks. A
file is approved while your working tree matches that overlay.

Your index, stash and commits are never touched: the working tree is
snapshotted through a throwaway copy of the index. When a rebase or merge moves
the merge base, the review tree is rebuilt on the new base and approvals carry
over.

## Known limitations

- Renaming a branch leaves its approvals under the old name.
- Hunks are approved from Neovim (with gitsigns) or through `approve-patch`;
  there is no interactive hunk mode in the terminal. Unapproving is per file.
- `<leader>gvh` refuses a hunk that adds or removes lines at the end of a file
  without a final newline, and a file whose final newline changed; approve
  those files whole.
- A rename shows up as a deletion plus a new file; approve both.

## Tests

```sh
test/run.sh                    # with the bash on your PATH
TEST_BASH=/bin/bash test/run.sh  # macOS bash 3.2
```
