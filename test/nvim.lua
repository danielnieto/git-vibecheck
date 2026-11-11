-- Drives git-vibecheck's hunk approval in a headless Neovim.
-- test/nvim.sh sets the environment and checks the result with the CLI.

local plugin = assert(os.getenv("PLUGIN"))
vim.opt.rtp:append(assert(os.getenv("GITSIGNS")))
vim.opt.rtp:append(plugin)
vim.opt.swapfile = false

local gitsigns = require("gitsigns")
gitsigns.setup({}) -- defaults, so untracked files are only attached on demand
local review = require("git-vibecheck")

vim.cmd.edit(vim.fn.getcwd() .. "/" .. assert(os.getenv("FILE")))
local buf = vim.api.nvim_get_current_buf()

-- The scenario where approving a hunk used to fail is one where gitsigns has
-- already drawn the change; wait for that before pressing the key.
if os.getenv("WAIT_HUNKS") == "1" then
  local shown = vim.wait(8000, function()
    local hunks = gitsigns.get_hunks(buf)
    return hunks ~= nil and #hunks > 0
  end)
  if not shown then
    error("gitsigns did not show the change before approving")
  end
end

for step in (os.getenv("STEPS") or ""):gmatch("%S+") do
  local first, last = step:match("^(%d+),(%d+)$")
  review.approve_hunk({ tonumber(first or step), tonumber(last or step) })
  -- approve_hunk is asynchronous: it waits for gitsigns, then runs the CLI.
  vim.wait(4000)
end

vim.cmd("qa!")
