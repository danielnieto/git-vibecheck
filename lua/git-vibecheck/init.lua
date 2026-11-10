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
  "[x] = approved by me, [ ] = never reviewed, [~] = changed since I approved it.",
  "For a pending file, `git vibecheck pending-diff <path>` shows exactly the part I have not reviewed yet.",
  "",
  "Tell me which [x] files could be affected by the pending changes: changed signatures, contracts,",
  "return values, side effects, or assumptions the approved code relies on. For each one, name the",
  "pending change and explain why it matters. If nothing is affected, say so.",
  "",
  "Do not edit any file and do not run `git vibecheck approve` or `git vibecheck unapprove`.",
}, "\n")

local source = debug.getinfo(1, "S").source:sub(2)
local bin = vim.fs.joinpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))), "bin", "git-vibecheck")

local mark_hl = { x = "DiagnosticOk", ["~"] = "DiagnosticWarn", [" "] = "DiagnosticHint" }

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
local function run(root, args)
  local cmd = { "bash", bin }
  vim.list_extend(cmd, args)
  local res = vim.system(cmd, { cwd = root, text = true }):wait()
  return res.code, vim.trim(res.stdout or ""), vim.trim(res.stderr or "")
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
