local M = {}

-- Exit code `git vibecheck` uses when the branch has not been started.
local NOT_STARTED = 3

M.config = {
  -- Prefix for the default keymaps. Set `keys = false` to map the functions yourself.
  prefix = "<leader>gv",
  keys = true,
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

local gutter_on = false

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

local function refresh_gutter(root)
  local ok, gitsigns = pcall(require, "gitsigns")
  if gutter_on and ok then
    gitsigns.change_base(review_ref(root), true)
  end
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
    refresh_gutter(root)
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

---@return string[] removed, string[] added
local function hunk_parts(hunk)
  local removed, added = {}, {}
  for _, line in ipairs(hunk.lines) do
    local list = line:sub(1, 1) == "-" and removed or added
    list[#list + 1] = line:sub(2)
  end
  return removed, added
end

-- The buffer lines a hunk covers, the way gitsigns' own hunk actions pick it:
-- a deletion sits on the line above it, or on the first line.
local function hunk_range(hunk, line_count)
  local first = math.max(hunk.added.start, 1)
  local last = math.max(hunk.added.start + hunk.added.count - 1, first)
  return math.min(first, line_count), math.min(last, line_count)
end

-- The buffer with every hunk undone, which is the text gitsigns diffed it against.
local function undo_hunks(lines, hunks)
  local text = vim.list_slice(lines)
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    local removed = hunk_parts(hunk)
    local at = hunk.added.start + (hunk.added.count == 0 and 1 or 0)
    for _ = 1, hunk.added.count do
      table.remove(text, at)
    end
    for j = #removed, 1, -1 do
      table.insert(text, at, removed[j])
    end
  end
  return text
end

-- Whether git can express the hunk without changing what gitsigns shows. A
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
    local removed, added = hunk_parts(hunk)
    local start = hunk.removed.start + (hunk.type == "add" and 1 or 0)
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
  local hunks = require("gitsigns").get_hunks(buf)
  if not hunks then
    return notify("gitsigns is not tracking this file", vim.log.levels.WARN)
  end
  local approved_id = git(root, { "rev-parse", "-q", "--verify", ref .. ":" .. name })
  approved_id = approved_id and vim.trim(approved_id)
  local approved = approved_id and git(root, { "cat-file", "blob", approved_id }) or ""
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if not vim.deep_equal(undo_hunks(lines, hunks), split_lines(approved)) then
    return notify("The gutter does not match the review; try again, or approve the whole file", vim.log.levels.WARN)
  end

  local path = vim.fs.joinpath(root, name)
  local file = {
    name = name,
    approved_id = approved_id,
    worktree_id = vim.trim(git(root, { "hash-object", "--", name }) or ""),
    mode = bit.band(assert(vim.uv.fs_stat(path)).mode, tonumber("111", 8)) ~= 0 and "100755" or "100644",
    approved_count = #split_lines(approved),
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
  refresh_gutter(root)
end

-- Approves the hunk under the cursor, or every hunk that touches the lines in
-- `range` ({ first, last }), exactly as gitsigns shows them against the review.
function M.approve_hunk(range)
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return notify("Requires gitsigns.nvim", vim.log.levels.WARN)
  end
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
  gutter_on = true
  -- Re-read the base first, so the hunks are against what is approved now.
  gitsigns.change_base(ref, true, function(change_err)
    vim.schedule(function()
      if change_err then
        return notify(change_err, vim.log.levels.ERROR)
      end
      approve_hunks(root, name, buf, ref, first, last)
    end)
  end)
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

function M.toggle_gutter()
  local ok, gitsigns = pcall(require, "gitsigns")
  if not ok then
    return notify("Requires gitsigns.nvim", vim.log.levels.WARN)
  end
  if gutter_on then
    gutter_on = false
    gitsigns.change_base(nil, true)
    return notify("Gutter: back to normal")
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
  gutter_on = true
  refresh_gutter(root)
  notify("Gutter: only what is left to review")
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
  map("d", M.toggle_gutter, "Toggle gutter: pending only")
  if has_sidekick() then
    map("i", M.impact, "Ask agent what approved files are affected")
  end
  local ok, wk = pcall(require, "which-key")
  if ok then
    wk.add({ { prefix, group = "vibecheck" } })
  end
end

return M
