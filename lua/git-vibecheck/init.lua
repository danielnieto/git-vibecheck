local M = {}

-- Exit code `git vibecheck` uses when the branch has not been started.
local NOT_STARTED = 3

M.config = {
  -- Prefix for the default keymaps. Set `keys = false` to map the functions yourself.
  prefix = "<leader>gv",
  keys = true,
  -- The review gutter draws its own signs, so gitsigns' keep showing your usual diff. By default
  -- every line left to review looks the same, whether it was added, changed or deleted.
  gutter = {
    signs = { add = "┃", change = "┃", delete = "┃", topdelete = "┃" },
    -- A color per kind: a highlight group to link to, or a table for nvim_set_hl (`{ fg = "#f9e2af" }`).
    -- Unset kinds link to `GitReviewSign`, which links to `DiagnosticWarn`. A deletion marks the line
    -- above it (`delete`), or the first line (`topdelete`, which shares `delete`'s color).
    colors = {},
    -- When signs share a column, the highest priority shows: gitsigns uses 6, diagnostics 10.
    priority = 7,
  },
}

-- Sent to the agent by `M.impact()`. Avoid `{...}`: sidekick treats it as a template variable.
M.impact_prompt = table.concat({
  "I'm reviewing this branch file by file with `git vibecheck`. Run `git vibecheck` to see the checklist:",
  "[x] = approved by me, [-] = partly approved by me, [~] = changed since I last approved any of it,",
  "[ ] = never reviewed.",
  "For a pending file, `git vibecheck pending-diff <path>` shows exactly the part I have not reviewed yet.",
  "",
  "Tell me which [x] files could be affected by the pending changes: changed signatures, contracts,",
  "return values, side effects, or assumptions the approved code relies on. For each one, name the",
  "pending change and explain why it matters. If nothing is affected, say so.",
  "",
  "Do not edit any file and do not run `git vibecheck approve`, `approve-patch` or `unapprove`.",
}, "\n")

local source = debug.getinfo(1, "S").source:sub(2)
local bin = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))), "bin", "git-vibecheck")

local mark_hl = { x = "DiagnosticOk", ["-"] = "DiagnosticInfo", ["~"] = "DiagnosticWarn", [" "] = "DiagnosticHint" }

local sign_hl =
  { add = "GitReviewAdd", change = "GitReviewChange", delete = "GitReviewDelete", topdelete = "GitReviewDelete" }

local ns = vim.api.nvim_create_namespace("git-vibecheck")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "git vibecheck" })
end

local function repo_root()
  local name = vim.api.nvim_buf_get_name(0)
  local root = name ~= "" and vim.fs.root(name, ".git") or nil
  return root or vim.fs.root(assert(vim.uv.cwd()), ".git")
end

---@return integer code, string stdout, string stderr
local function run(root, args, stdin)
  local cmd = { "bash", bin }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = root, text = true, stdin = stdin }):wait()
  return res.code, vim.trim(res.stdout or ""), vim.trim(res.stderr or "")
end

---@return string? stdout, untouched, or nil when git fails
local function git(root, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = root }):wait()
  return res.code == 0 and res.stdout or nil
end

-- Like `run`, but if the branch is not under review yet, offers to start it
-- and retries. Returns nil when the user declines.
local function run_started(root, args)
  local code, out, err = run(root, args)
  if code ~= NOT_STARTED then
    return code, out, err
  end
  if vim.fn.confirm("This branch is not under review yet. Start reviewing it?", "&Yes\n&No", 2) ~= 1 then
    return nil
  end
  local start_code, _, start_err = run(root, {})
  if start_code ~= 0 then
    notify(start_err, vim.log.levels.ERROR)
    return nil
  end
  return run(root, args)
end

local function parse(out)
  local items = {}
  for line in out:gmatch("[^\n]+") do
    local mark, file = line:match("^%[(.)%] (.+)$")
    if mark then
      items[#items + 1] = { mark = mark, file = file }
    end
  end
  return items
end

local function current_file(root)
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil
  end
  return vim.fs.relpath(root, name)
end

local function review_ref(root)
  local res = vim.system({ "git", "symbolic-ref", "-q", "--short", "HEAD" }, { cwd = root, text = true }):wait()
  return res.code == 0 and "refs/review/" .. vim.trim(res.stdout) or nil
end

local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

local function ends_with_newline(text)
  return text == "" or text:sub(-1) == "\n"
end

local function read_file(path)
  local f = assert(io.open(path, "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local function empty_on_disk(path)
  local stat = vim.uv.fs_stat(path)
  return stat == nil or stat.size == 0
end

-- An empty file is still one empty line in the buffer.
local function buffer_lines(buf, path)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" and empty_on_disk(path) then
    return {}
  end
  return lines
end

local function diff_opts()
  local opts = { result_type = "indices" }
  for _, item in ipairs(vim.split(vim.o.diffopt, ",", { plain = true })) do
    local key, value = item:match("^([^:]+):(.*)$")
    if item == "indent-heuristic" then
      opts.indent_heuristic = true
    elseif key == "algorithm" then
      opts.algorithm = value
    elseif key == "linematch" then
      opts.linematch = tonumber(value)
    end
  end
  return opts
end

-- The hunks from `old` to `new` as { old_start, old_count, new_start, new_count },
-- numbered like a unified diff and cut the way 'diffopt' cuts them (with
-- linematch, one changed block can be several hunks). Whitespace options are
-- left out: a hunk the gutter hid could never be approved.
local function diff(old, new)
  local function text(lines)
    return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
  end
  return vim.diff(text(old), text(new), diff_opts())
end

-- The review gutter. Gitsigns keeps diffing against its usual base; this draws
-- separate signs for what is left to review: the buffer against the review ref.

local gutter_on = false
local gutter_group

-- buffer -> false when it is not a file in a repository, else
-- { root, name, reviewed = lines the review compares it against (nil when the
-- file is not under review), hunks = the hunks drawn }. Emptied whenever the
-- review may have changed; visible buffers are reloaded right away, the rest
-- when they are shown.
local buffers = {}
local attached = {}
local draw_queued = {}

local function file_of(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" or vim.bo[buf].buftype ~= "" or path:match("^%a[%w+.-]*://") then
    return nil
  end
  local root = vim.fs.root(path, ".git")
  local name = root and vim.fs.relpath(root, path)
  if not name then
    return nil
  end
  return root, name
end

-- What the review compares a file against: the content approved, the base for
-- a file never approved, nothing for a new one. nil when the branch is not
-- under review, or when git ignores the file.
---@return string[]?
local function reviewed_lines(root, name)
  local ref = review_ref(root)
  if not ref then
    return nil
  end
  local text = git(root, { "cat-file", "blob", ref .. ":" .. name })
  if text then
    return split_lines(text)
  end
  if not git(root, { "rev-parse", "-q", "--verify", ref }) or git(root, { "check-ignore", "-q", "--", name }) then
    return nil
  end
  return {}
end

local function draw(buf)
  local state = buffers[buf]
  if not (gutter_on and state and vim.api.nvim_buf_is_loaded(buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  state.hunks = state.reviewed and diff(state.reviewed, buffer_lines(buf, vim.fs.joinpath(state.root, state.name)))
  local signs, priority = M.config.gutter.signs, M.config.gutter.priority
  local function sign(lnum, kind)
    vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
      sign_text = signs[kind],
      sign_hl_group = sign_hl[kind],
      priority = priority,
    })
  end
  -- A deletion is marked on the line above it, or on the first line.
  for _, hunk in ipairs(state.hunks or {}) do
    local _, old_count, new_start, new_count = unpack(hunk)
    if new_count == 0 then
      sign(math.max(new_start, 1), new_start == 0 and "topdelete" or "delete")
    else
      for lnum = new_start, new_start + new_count - 1 do
        sign(lnum, old_count == 0 and "add" or "change")
      end
    end
  end
end

local function queue_draw(buf)
  if draw_queued[buf] then
    return
  end
  draw_queued[buf] = true
  vim.defer_fn(function()
    draw_queued[buf] = nil
    draw(buf)
  end, 50)
end

local function attach(buf)
  if attached[buf] then
    return
  end
  attached[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not gutter_on then
        attached[buf] = nil
        return true
      end
      queue_draw(buf)
    end,
    on_reload = function()
      queue_draw(buf)
    end,
    on_detach = function()
      attached[buf] = nil
      buffers[buf] = nil
    end,
  }) or nil
end

local function load_buffer(buf)
  local root, name = file_of(buf)
  if not root then
    buffers[buf] = false
    return
  end
  buffers[buf] = { root = root, name = name, reviewed = reviewed_lines(root, name) }
  attach(buf)
  draw(buf)
end

local function load_visible()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if buffers[buf] == nil then
      load_buffer(buf)
    end
  end
end

-- The review may have changed (an approval, a commit, a rebase): read it again.
local function reload_gutter()
  if gutter_on then
    buffers = {}
    load_visible()
  end
end

local function set_highlights()
  vim.api.nvim_set_hl(0, "GitReviewSign", { link = "DiagnosticWarn", default = true })
  local colors = M.config.gutter.colors or {}
  for kind, group in pairs(sign_hl) do
    local color = colors[kind]
    if kind ~= "topdelete" then
      if type(color) == "table" then
        vim.api.nvim_set_hl(0, group, color)
      else
        -- Without a color of its own, the kind follows `GitReviewSign` (or whatever it was set to).
        vim.api.nvim_set_hl(0, group, { link = color or "GitReviewSign", default = color == nil })
      end
    end
  end
end

local function gutter_enable()
  if gutter_on then
    return reload_gutter()
  end
  gutter_on = true
  set_highlights()
  gutter_group = vim.api.nvim_create_augroup("git-vibecheck-gutter", { clear = true })
  local function autocmd(events, fn)
    vim.api.nvim_create_autocmd(events, { group = gutter_group, callback = fn })
  end
  autocmd({ "BufEnter", "BufWinEnter", "WinEnter", "TabEnter" }, load_visible)
  -- Approving from a terminal, committing or rebasing changes the review.
  autocmd({ "FocusGained", "ShellCmdPost", "TermLeave" }, reload_gutter)
  autocmd("BufFilePost", function(ev)
    buffers[ev.buf] = nil
    load_visible()
  end)
  autocmd("ColorScheme", set_highlights)
  reload_gutter()
end

local function gutter_disable()
  gutter_on = false
  vim.api.nvim_del_augroup_by_id(gutter_group)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  buffers = {}
end

-- Approving must record what the user sees, so unsaved edits are written first.
local function write_if_modified(path)
  local real = vim.uv.fs_realpath(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].modified and vim.uv.fs_realpath(name) == real then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
  end
end

local function set_mark(root, action, files)
  local code, out, err
  if action == "approve" then
    for _, file in ipairs(files) do
      write_if_modified(vim.fs.joinpath(root, file))
    end
    code, out, err = run_started(root, vim.list_extend({ "approve" }, files))
  else
    code, out, err = run(root, vim.list_extend({ action }, files))
  end
  if code == nil then
    return
  elseif code == NOT_STARTED then
    notify("This branch is not under review", vim.log.levels.WARN)
  elseif code ~= 0 then
    notify(err ~= "" and err or out, vim.log.levels.ERROR)
  else
    notify(out)
    reload_gutter()
  end
end

local function with_current_file(action)
  local root = repo_root()
  if not root then
    return notify("Not inside a git repository", vim.log.levels.WARN)
  end
  local file = current_file(root)
  if not file then
    return notify("This buffer is not a file in the repository", vim.log.levels.WARN)
  end
  set_mark(root, action, { file })
end

function M.approve()
  with_current_file("approve")
end

function M.unapprove()
  with_current_file("unapprove")
end

-- A hunk from `diff`, with the lines it removes and adds.
local function to_hunk(index, old, new)
  local old_start, old_count, new_start, new_count = unpack(index)
  return {
    removed = {
      start = old_start,
      count = old_count,
      lines = vim.list_slice(old, old_start, old_start + old_count - 1),
    },
    added = { start = new_start, count = new_count, lines = vim.list_slice(new, new_start, new_start + new_count - 1) },
  }
end

-- The buffer lines a hunk covers, the way the gutter marks it: a deletion sits
-- on the line above it, or on the first line.
local function hunk_range(hunk, line_count)
  local first = math.max(hunk.added.start, 1)
  local last = math.max(hunk.added.start + hunk.added.count - 1, first)
  return math.min(first, line_count), math.min(last, line_count)
end

-- Whether git can express the hunk without changing what the gutter shows. A
-- file without a final newline marks its last line as such, so a hunk at the
-- end of the file only works when it replaces the last line of both versions.
local function fits_end_of_file(hunk, file)
  local ends_approved = hunk.removed.count > 0 and hunk.removed.start + hunk.removed.count - 1 == file.approved_count
  local ends_worktree = hunk.added.count > 0 and hunk.added.start + hunk.added.count - 1 == file.line_count
  if not (ends_approved or ends_worktree) or (file.approved_nl and file.worktree_nl) then
    return true
  end
  return ends_approved and ends_worktree and not file.approved_nl and not file.worktree_nl
end

-- A git-format patch of the hunks, numbered the way gitsigns numbers the
-- patches it stages: each hunk's new start includes the hunks before it.
local function hunk_patch(file, hunks)
  local name = file.name
  local out = { ("diff --git a/%s b/%s"):format(name, name) }
  if file.approved_id then
    vim.list_extend(out, { ("index %s..%s"):format(file.approved_id, file.worktree_id), "--- a/" .. name })
  else
    vim.list_extend(out, { "new file mode " .. file.mode, "index 0000000.." .. file.worktree_id, "--- /dev/null" })
  end
  out[#out + 1] = "+++ b/" .. name
  local no_newline = "\\ No newline at end of file"
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local removed, added = hunk.removed.lines, hunk.added.lines
    local start = hunk.removed.start + (#removed == 0 and 1 or 0)
    local old_start = file.approved_id and start or 0
    out[#out + 1] = ("@@ -%d,%d +%d,%d @@"):format(old_start, #removed, start + offset, #added)
    for _, line in ipairs(removed) do
      out[#out + 1] = "-" .. line
    end
    if not file.approved_nl and #removed > 0 and hunk.removed.start + #removed - 1 == file.approved_count then
      out[#out + 1] = no_newline
    end
    for _, line in ipairs(added) do
      out[#out + 1] = "+" .. line
    end
    if not file.worktree_nl and #added > 0 and hunk.added.start + #added - 1 == file.line_count then
      out[#out + 1] = no_newline
    end
    offset = offset + #added - #removed
  end
  return table.concat(out, "\n") .. "\n"
end

local function approve_hunks(root, name, buf, ref, first, last)
  local path = vim.fs.joinpath(root, name)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  -- An empty file is a single empty line in the buffer, which no hunk can
  -- express: the patch would add a newline that is not there. There is nothing
  -- to pick, so approve the empty file as a whole.
  if #lines == 1 and lines[1] == "" and empty_on_disk(path) then
    return set_mark(root, "approve", { name })
  end

  local approved_id = git(root, { "rev-parse", "-q", "--verify", ref .. ":" .. name })
  approved_id = approved_id and vim.trim(approved_id)
  local approved = approved_id and git(root, { "cat-file", "blob", approved_id }) or ""
  local old = split_lines(approved)
  local hunks = vim.tbl_map(function(index)
    return to_hunk(index, old, lines)
  end, diff(old, lines))
  local file = {
    name = name,
    approved_id = approved_id,
    worktree_id = vim.trim(git(root, { "hash-object", "--", name }) or ""),
    mode = bit.band(assert(vim.uv.fs_stat(path)).mode, tonumber("111", 8)) ~= 0 and "100755" or "100644",
    approved_count = #old,
    line_count = #lines,
    approved_nl = ends_with_newline(approved),
    worktree_nl = ends_with_newline(read_file(path)),
  }
  if #hunks == 0 then
    if file.approved_nl ~= file.worktree_nl then
      return notify("Only the newline at the end of the file is left; approve the whole file", vim.log.levels.WARN)
    end
    return notify("Nothing left to approve in this file")
  end
  local chosen = vim.tbl_filter(function(hunk)
    local hunk_first, hunk_last = hunk_range(hunk, #lines)
    return hunk_first <= last and hunk_last >= first
  end, hunks)
  if #chosen == 0 then
    return notify("No pending hunk here", vim.log.levels.WARN)
  end
  for _, hunk in ipairs(chosen) do
    if not fits_end_of_file(hunk, file) then
      return notify(
        "This hunk changes the end of a file without a final newline; approve the whole file",
        vim.log.levels.WARN
      )
    end
  end

  local code, out, err = run(root, { "approve-patch" }, hunk_patch(file, chosen))
  if code ~= 0 then
    return notify(err ~= "" and err or out, vim.log.levels.ERROR)
  end
  notify(out)
  reload_gutter()
end

-- Approves the hunk under the cursor, or every hunk that touches the lines in
-- `range` ({ first, last }), exactly as the review gutter shows them.
function M.approve_hunk(range)
  local root = repo_root()
  if not root then
    return notify("Not inside a git repository", vim.log.levels.WARN)
  end
  local name = current_file(root)
  if not name then
    return notify("This buffer is not a file in the repository", vim.log.levels.WARN)
  end
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.fn.line(".")
  local first, last = unpack(range or { cursor, cursor })
  local shown = gutter_on and buffers[buf] and buffers[buf].hunks
  write_if_modified(vim.fs.joinpath(root, name))
  local code, _, err = run_started(root, { "pending" })
  if code == nil then
    return
  elseif code == 0 then
    return notify("Nothing left to review")
  elseif code > 1 then
    return notify(err, vim.log.levels.ERROR)
  end
  local ref = review_ref(root)
  if not ref then
    return notify("HEAD is not a branch", vim.log.levels.WARN)
  end
  -- Redraw from the review as it is now. If that moved the hunks the user was
  -- looking at (a formatter on save, an approval elsewhere), let them look again.
  gutter_enable()
  if shown and buffers[buf] and not vim.deep_equal(shown, buffers[buf].hunks) then
    return notify("The pending hunks changed; check the gutter and try again", vim.log.levels.WARN)
  end
  approve_hunks(root, name, buf, ref, first, last)
end

function M.next_pending()
  local root = repo_root()
  if not root then
    return notify("Not inside a git repository", vim.log.levels.WARN)
  end
  local code, out, err = run_started(root, { "pending" })
  if code == nil then
    return
  elseif code == 0 then
    return notify("Nothing left to review")
  elseif code ~= 1 then
    return notify(err, vim.log.levels.ERROR)
  end
  local items = parse(out)
  local current = current_file(root)
  local target = items[1]
  for _, item in ipairs(items) do
    if current and item.file > current then
      target = item
      break
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(vim.fs.joinpath(root, target.file)))
end

-- Shows or hides the review gutter: signs of its own for what is left to
-- review, next to gitsigns' instead of in place of them.
function M.toggle_gutter()
  if gutter_on then
    gutter_disable()
    return notify("Review gutter: off")
  end
  local root = repo_root()
  if not root then
    return notify("Not inside a git repository", vim.log.levels.WARN)
  end
  local code, _, err = run_started(root, { "pending" })
  if code == nil then
    return
  elseif code > 1 then
    return notify(err, vim.log.levels.ERROR)
  end
  gutter_enable()
  notify("Review gutter: on")
end

-- Moves to the next or previous hunk left to review (`direction` is "next" or
-- "prev"), the way gitsigns' ]h/[h move through its own hunks. Turns the
-- review gutter on, so you see what you land on.
function M.nav_hunk(direction)
  if not gutter_on then
    M.toggle_gutter()
    if not gutter_on then
      return
    end
  end
  local buf = vim.api.nvim_get_current_buf()
  -- Draw now rather than after the short wait that follows an edit.
  if buffers[buf] == nil then
    load_buffer(buf)
  else
    draw(buf)
  end
  local state = buffers[buf]
  if not (state and state.hunks) then
    return notify("This file is not part of the review", vim.log.levels.WARN)
  end
  -- Each hunk starts where the gutter marks it; a deletion on the line above it.
  local starts = {}
  for _, hunk in ipairs(state.hunks) do
    local lnum = math.max(hunk[3], 1)
    if lnum ~= starts[#starts] then
      starts[#starts + 1] = lnum
    end
  end
  if #starts == 0 then
    return notify("Nothing left to review in this file")
  end
  local cursor, index = vim.fn.line("."), nil
  if direction == "prev" then
    for i = #starts, 1, -1 do
      if starts[i] < cursor then
        index = i
        break
      end
    end
    index = index or (vim.o.wrapscan and #starts or nil)
  else
    for i, lnum in ipairs(starts) do
      if lnum > cursor then
        index = i
        break
      end
    end
    index = index or (vim.o.wrapscan and 1 or nil)
  end
  if not index then
    return
  end
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { starts[index], 0 })
  vim.cmd("normal! zv")
  vim.api.nvim_echo({ { ("Review hunk %d of %d"):format(index, #starts) } }, false, {})
end

function M.tracker()
  if not _G.Snacks then
    return notify("Requires snacks.nvim", vim.log.levels.WARN)
  end
  local root = repo_root()
  if not root then
    return notify("Not inside a git repository", vim.log.levels.WARN)
  end
  local code, _, err = run_started(root, { "pending" })
  if code == nil then
    return
  elseif code > 1 then
    return notify(err, vim.log.levels.ERROR)
  end
  -- An empty picker says nothing: explain why there is nothing to list.
  local c, out, e = run(root, {})
  if c == 0 and #parse(out) == 0 then
    local base = out:match("^%S+ vs (%S+):") or "its base"
    return notify(
      (
        "No files differ from %s, so there is nothing to review.\n"
        .. "Committed work on the base itself never shows. To review it, pick an older base:\n"
        .. "git vibecheck --base <ref>"
      ):format(base),
      vim.log.levels.WARN
    )
  elseif c ~= 0 then
    return notify(e, vim.log.levels.ERROR)
  end

  local function act(action)
    return function(picker)
      local files = vim.tbl_map(function(item)
        return item.file
      end, picker:selected({ fallback = true }))
      if #files > 0 then
        set_mark(root, action, files)
        picker.list:set_selected()
        picker:refresh()
      end
    end
  end

  Snacks.picker.pick({
    title = "Review",
    cwd = root,
    finder = function()
      local c, out, e = run(root, {})
      if c ~= 0 then
        notify(e, vim.log.levels.ERROR)
        return {}
      end
      local items = parse(out)
      for _, item in ipairs(items) do
        item.text = item.file
        item.cwd = root
      end
      return items
    end,
    sort = { fields = { "score:desc", "idx" } },
    format = function(item)
      return { { "[" .. item.mark .. "] ", mark_hl[item.mark] }, { item.file } }
    end,
    preview = function(ctx)
      if ctx.item.mark == "x" then
        return Snacks.picker.preview.file(ctx)
      end
      if ctx.item.diff == nil then
        local _, out = run(root, { "pending-diff", ctx.item.file })
        ctx.item.diff = out
      end
      return Snacks.picker.preview.diff(ctx)
    end,
    actions = {
      review_approve = act("approve"),
      review_unapprove = act("unapprove"),
    },
    win = {
      input = {
        keys = {
          a = { "review_approve", mode = { "n" } },
          u = { "review_unapprove", mode = { "n" } },
        },
      },
      list = { keys = { a = "review_approve", u = "review_unapprove" } },
    },
  })
end

function M.impact()
  local ok, cli = pcall(require, "sidekick.cli")
  if not ok then
    return notify("Requires sidekick.nvim", vim.log.levels.WARN)
  end
  cli.send({ msg = M.impact_prompt, focus = true })
end

-- Checked without loading sidekick, which LazyVim loads lazily.
local function has_sidekick()
  if package.loaded["sidekick"] then
    return true
  end
  local ok, lazy_config = pcall(require, "lazy.core.config")
  if ok and lazy_config.plugins["sidekick.nvim"] then
    return true
  end
  return #vim.api.nvim_get_runtime_file("lua/sidekick/init.lua", false) > 0
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if not M.config.keys then
    return
  end
  local prefix = M.config.prefix
  local function map(key, fn, desc)
    vim.keymap.set("n", prefix .. key, fn, { desc = desc })
  end
  map("r", M.tracker, "Review checklist")
  map("a", M.approve, "Approve file")
  map("u", M.unapprove, "Unapprove file")
  map("h", M.approve_hunk, "Approve hunk")
  vim.keymap.set("x", prefix .. "h", function()
    local first, last = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    M.approve_hunk({ math.min(first, last), math.max(first, last) })
  end, { desc = "Approve hunks in selection" })
  map("n", M.next_pending, "Next pending file")
  map("d", M.toggle_gutter, "Toggle review gutter")
  -- ]h/[h stay gitsigns', for its hunks.
  vim.keymap.set("n", "]v", function()
    M.nav_hunk("next")
  end, { desc = "Next review hunk" })
  vim.keymap.set("n", "[v", function()
    M.nav_hunk("prev")
  end, { desc = "Prev review hunk" })
  if has_sidekick() then
    map("i", M.impact, "Ask agent what approved files are affected")
  end
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { prefix, group = "vibecheck" } })
  end
end

return M
