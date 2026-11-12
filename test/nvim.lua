-- Drives git-vibecheck's hunk approval and review gutter in a headless Neovim.
-- test/nvim.sh sets the environment and checks the result with the CLI.

local plugin = assert(os.getenv("PLUGIN"))
vim.opt.rtp:append(plugin)
vim.opt.swapfile = false

local review = require("git-vibecheck")

vim.cmd.edit(vim.fn.getcwd() .. "/" .. assert(os.getenv("FILE")))
local buf = vim.api.nvim_get_current_buf()

-- Each step presses <leader>gvh on a line, or on a visual range "first,last".
local steps = os.getenv("STEPS") or ""
for step in steps:gmatch("%S+") do
  local first, last = step:match("^(%d+),(%d+)$")
  review.approve_hunk({ tonumber(first or step), tonumber(last or step) })
end
if steps == "" then
  review.toggle_gutter()
end

-- "<line>:<text>" replaces a line without saving, so the gutter has to follow the buffer.
local lnum, text = (os.getenv("SET_LINE") or ""):match("^(%d+):(.*)$")

if lnum then
end
vim.wait(200) -- the gutter redraws shortly after an edit

-- "next"/"prev" moves through the review hunks (]v/[v), recording each line landed on.
local visited = {}
for move in (os.getenv("NAV") or ""):gmatch("%S+") do
  review.nav_hunk(move)
  visited[#visited + 1] = tostring(vim.fn.line("."))
end
local cursor = assert(io.open(assert(os.getenv("CURSOR_OUT")), "w"))
cursor:write(table.concat(visited, " "))
cursor:close()

-- The review gutter's signs, one "<line> <sign>" per line.
local signs = {}
local ns = vim.api.nvim_get_namespaces()["git-vibecheck"]
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  signs[#signs + 1] = ("%d %s"):format(mark[2] + 1, vim.trim(mark[4].sign_text))
end
local out = assert(io.open(assert(os.getenv("SIGNS_OUT")), "w"))
out:write(table.concat(signs, "\n"))
out:close()

vim.cmd("qa!")
