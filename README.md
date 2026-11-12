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
[-] app/prompts.py
[~] app/runner.py
[ ] app/verdict.py
...
```

| Mark  | Meaning                                                           |
| ----- | ----------------------------------------------------------------- |
| `[x]` | Approved, and unchanged since                                     |
| `[-]` | Partly approved (some hunks), and unchanged since                 |
| `[~]` | Changed since you last approved any of it (you, an agent, a rebase) |
| `[ ]` | Never reviewed                                                    |

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
  directories approve everything inside them. From the repository root,
  `git vibecheck approve .` approves everything, but only because you asked for
  it.
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
| `<leader>gvh` | Approve the hunk under the cursor; in visual mode, every hunk the selection touches |
| `<leader>gvn` | Open the next pending file                                                   |
| `<leader>gvd` | Toggle the review gutter: signs for what is left to review, apart from gitsigns' |
| `]v` / `[v`   | Next / previous hunk left to review (`]h`/`[h` stay gitsigns', for git's hunks) |
| `<leader>gvi` | Ask the agent which approved files the pending changes could affect (needs sidekick.nvim) |

The picker needs [snacks.nvim](https://github.com/folke/snacks.nvim).
Everything else works without it. Any command run on a branch that is not under
review offers to start it.

The review gutter has signs of its own, so your usual diff stays in gitsigns,
which never changes base. By default every line left to review gets the same
bold bar (`┃`, as gitsigns draws) in one color (`GitReviewSign`), whether it was
added, changed or deleted: you have `git diff` for the difference. A deletion
marks the line above it, or the first line. To tell the kinds apart, set a sign
and a color per kind, see below. A line that is left to review is marked whether or not it is committed,
and never-reviewed files compare against the base branch. In LazyVim the review
signs sit left of the line numbers and gitsigns' on the right. With a plain
`signcolumn=yes`, both share one column and the higher `priority` wins; set
`signcolumn=yes:2` to see both.

`<leader>gvh` turns on the review gutter and approves exactly the hunks it
shows, however your `diffopt` cuts them (with `linematch`, one changed block can
be several hunks). New files work like any other. If the hunks moved since the
gutter was drawn (a formatter on save, an approval from a terminal), it redraws
them and asks you to look again instead of approving.

Options:

```lua
opts = {
  prefix = "<leader>gv", -- keymap prefix
  keys = true,           -- false to skip the default keymaps
  gutter = {
    signs = { add = "┃", change = "┃", delete = "┃", topdelete = "┃" },
    colors = {},         -- per kind, see below
    priority = 7,        -- gitsigns uses 6 and diagnostics 10
  },
}
```

Colors are per kind (`add`, `change`, `delete`; `topdelete` shares `delete`'s).
A color is a highlight group to link to, or a table for `nvim_set_hl`. Kinds you
leave out link to `GitReviewSign`, which links to `DiagnosticWarn`:

```lua
gutter = {
  signs = { add = "+", change = "~", delete = "_", topdelete = "‾" },
  colors = {
    add = "GitSignsAdd",                 -- link to a group
    change = { fg = "#f9e2af" },         -- or set a color
    delete = { fg = "#f38ba8", bold = true },
  },
}
```

To recolor everything at once, set `GitReviewSign` instead (it also survives
`:colorscheme` changes with `default` links, e.g.
`vim.api.nvim_set_hl(0, "GitReviewSign", { fg = "#89b4fa" })` in an autocmd on
`ColorScheme`), or the per-kind groups `GitReviewAdd`, `GitReviewChange` and
`GitReviewDelete`.

The functions are public if you prefer your own mappings:
`require("git-vibecheck").tracker / approve / unapprove / approve_hunk / next_pending / toggle_gutter / nav_hunk / impact`
(`nav_hunk("next")` or `nav_hunk("prev")`).

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
file is approved while your working tree matches that overlay. A second parent
records each file as your working tree had it the last time you approved any
of it: a file that still matches it is `[-]`, one that does not is `[~]`.

Your index, stash and commits are never touched: the working tree is
snapshotted through a throwaway copy of the index. When a rebase or merge moves
the merge base, the review tree is rebuilt on the new base and approvals carry
over.

## Known limitations

- Renaming a branch leaves its approvals under the old name.
- Hunks are approved from Neovim or through `approve-patch`;
  there is no interactive hunk mode in the terminal. Unapproving is per file.
- `<leader>gvh` refuses a hunk that adds or removes lines at the end of a file
  without a final newline, and a file whose final newline changed; approve
  those files whole.
- A rename shows up as a deletion plus a new file; approve both.

## Tests

```sh
test/run.sh                       # with the bash on your PATH
TEST_BASH=/bin/bash test/run.sh   # macOS bash 3.2
test/nvim.sh                      # hunk approval and review gutter, needs nvim
```

Set `NVIM_BIN` if nvim is not on your PATH.
